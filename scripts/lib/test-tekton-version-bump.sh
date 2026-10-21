#!/bin/bash
# Tests for tekton-task-version-bump.sh: the EC deny-rule handling in update_repo,
# the summary, and the EC-log diagnosis text.
# Run: ./scripts/lib/test-tekton-version-bump.sh
#
# Sources the real script (main is guarded by BASH_SOURCE != $0). update_repo runs
# against throwaway git repos with a fake PATCHER_SCRIPT and a stubbed
# latest_task_version, so no network, oras or cluster is touched. The policy data
# is a fixture (DENY_RULES_FILE) and the clock is frozen (DENY_RULES_NOW).
# shellcheck disable=SC2034,SC1090  # globals read by the sourced script's functions
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_TEST_SCRIPT_DIR="$SCRIPT_DIR"
for tool in jq yq flock; do
  command -v "$tool" >/dev/null || { echo "SKIP: $tool not installed"; exit 0; }
done

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT
# HOME is read at source time (SUBMARINER_BASE, ~/Downloads); point it at the
# sandbox so the diagnosis test finds only the fixture log.
REAL_HOME="$HOME"
export HOME="$TMPROOT/home"; mkdir -p "$HOME/Downloads"

source "$_TEST_SCRIPT_DIR/../tekton-task-version-bump.sh"
SCRIPT_DIR="$_TEST_SCRIPT_DIR"
# Source the library and declare the state directly (instead of relying on the
# script under test), so a script lacking the deny handling fails the assertions
# below rather than crashing on a missing function.
source "$_TEST_SCRIPT_DIR/deny-rules.sh"
declare -a REPOS_DENIED=() DENY_REPORTS=()
DENY_RULES_CHECKED=0

PASS=0 FAIL=0
assert_eq() {
  if [ "$2" = "$3" ]; then echo "  ✓ $1"; PASS=$((PASS + 1))
  else echo "  ✗ $1 (got: '$2', want: '$3')"; FAIL=$((FAIL + 1)); fi
}
assert_contains() {
  if grep -qF -- "$3" <<< "$2"; then echo "  ✓ $1"; PASS=$((PASS + 1))
  else echo "  ✗ $1 (missing: '$3')"; FAIL=$((FAIL + 1)); fi
}
assert_not_contains() {
  if ! grep -qF -- "$3" <<< "$2"; then echo "  ✓ $1"; PASS=$((PASS + 1))
  else echo "  ✗ $1 (unexpectedly found: '$3')"; FAIL=$((FAIL + 1)); fi
}

# ── Fixtures ───────────────────────────────────────────────────────────────────
POLICY="$TMPROOT/policy.json"
cat > "$POLICY" <<'EOF'
{"rule_data":{"trusted_task_rules":{"deny":{
  "konflux-defaults":[
    {"pattern":"oci://quay.io/konflux-ci/tekton-catalog/task-buildah","versions":["<0.9"]},
    {"pattern":"oci://quay.io/konflux-ci/tekton-catalog/task-alwaysbad"}
  ],
  "konflux-defaults-deprecated":[
    {"effective_on":"2026-09-24T00:00:00Z","message":"Tasks under konflux-vanguard are no longer trusted. Use the equivalent from quay.io/konflux-ci/tekton-catalog instead.\n","pattern":"oci://quay.io/konflux-ci/konflux-vanguard/*"}
  ]
}}}}
EOF
export DENY_RULES_NOW="2026-09-28T00:00:00Z"
DENY_RULES_FILE="$POLICY" deny_rules_load 2>/dev/null

# Stub the network lookup: newest acceptable versions per task.
latest_task_version() {
  case "$1" in
    buildah)              echo "0.12" ;;
    rpms-signature-scan)  echo "0.2.2" ;;
    *)                    echo "" ;;
  esac
}

DG="sha256:$(printf 'c%.0s' $(seq 64))"
TEST_REPO=""
setup_repo_with_ref() {  # $1=name $2="repo:tag"
  TEST_REPO="$TMPROOT/repo-$1"
  rm -rf "$TEST_REPO"; mkdir -p "$TEST_REPO"
  (
    cd "$TEST_REPO"
    git init -q
    git config user.email t@t; git config user.name t
    git checkout -q -b release-0.99
    mkdir .tekton
    cat > .tekton/pipe.yaml <<EOF
spec:
  pipelineSpec:
    tasks:
      - name: t1
        taskRef:
          resolver: bundles
          params:
            - name: bundle
              value: $2@$DG
EOF
    git add -A; git commit -qm base
    git checkout -q -b work
  )
}
repo_path()        { echo "$TEST_REPO"; }
repo_base_branch() { echo "release-0.99"; }
MAJOR_MINOR="0.99"
ORIG_DIR=$(pwd)

run_update() {
  REPOS_UPDATED=(); REPOS_SKIPPED=(); REPOS_FAILED=(); REPOS_DENIED=(); DENY_REPORTS=()
  DENY_RULES_CHECKED="${1:-1}"
  update_repo testcomp >"$TMPROOT/out.txt" 2>&1 || true
  DENY_RULES_CHECKED=0
  cd "$ORIG_DIR"
}
has_branch() { (cd "$TEST_REPO" && git show-ref --verify --quiet refs/heads/fix-tekton-tasks-0.99 && echo yes || echo no); }
fix_file() { (cd "$TEST_REPO" && git show fix-tekton-tasks-0.99:.tekton/pipe.yaml); }

echo "=== update_repo: catalog moved (deny message names replacement) ==="
# The fake patcher fails on the retired catalog like the real one, and re-pins the
# digest like it does for a known ref — so this exercises rewrite → bump → patch.
setup_repo_with_ref moved "quay.io/konflux-ci/konflux-vanguard/task-rpms-signature-scan:0.2"
PATCHER_SCRIPT='if grep -q konflux-vanguard .tekton/pipe.yaml; then echo "Can'"'"'t find vanguard ref. Aborting."; exit 1; fi
sed -i "s|@sha256:c*|@sha256:'"$(printf 'd%.0s' $(seq 64))"'|" .tekton/pipe.yaml'
run_update
assert_eq "no failure (patcher never saw the retired catalog)" "${#REPOS_FAILED[@]}" "0"
assert_eq "committed on the fix branch" "${REPOS_UPDATED[0]:-}" "testcomp#fix-tekton-tasks-0.99#release-0.99"
assert_eq "nothing left denied"         "${#REPOS_DENIED[@]}" "0"
assert_contains "catalog swapped, version bumped, digest re-pinned" "$(fix_file)" \
  "quay.io/konflux-ci/tekton-catalog/task-rpms-signature-scan:0.2.2@sha256:$(printf 'd%.0s' $(seq 64))"
assert_not_contains "no vanguard ref remains" "$(fix_file)" "konflux-vanguard"
assert_contains "operator told about the move" "$(cat "$TMPROOT/out.txt")" "↻"
MSG=$(cd "$TEST_REPO" && git log -1 --format=%B fix-tekton-tasks-0.99)
assert_contains "commit message explains the replacement" "$MSG" "Replaces task refs that EC denies"
assert_contains "commit message lists the old ref" "$MSG" "- konflux-vanguard/task-rpms-signature-scan"
assert_contains "commit message lists the new ref"  "$MSG" "  -> tekton-catalog/task-rpms-signature-scan:0.2"
# The component repos run gitlint in CI (body lines <= 80). A one-line
# "old -> new" was 128 chars and failed it on the first real PR.
assert_eq "no commit message line exceeds 80 characters" \
  "$(printf '%s\n' "$MSG" | awk 'length > 80' | wc -l | tr -d ' ')" "0"
assert_not_contains "commit message has no leftover marker/parenthetical" "$MSG" "↻"

echo ""
echo "=== update_repo: denial cleared by the version bump ==="
setup_repo_with_ref verdeny "quay.io/konflux-ci/tekton-catalog/task-buildah:0.8"
PATCHER_SCRIPT='true'
run_update
assert_eq "buildah 0.8 → 0.12 committed" "${REPOS_UPDATED[0]:-}" "testcomp#fix-tekton-tasks-0.99#release-0.99"
assert_contains "bumped to the newest version"  "$(fix_file)" "task-buildah:0.12@"
assert_not_contains "no replacement text when nothing moved" \
  "$(cd "$TEST_REPO" && git log -1 --format=%B fix-tekton-tasks-0.99)" "Replaces task refs"
assert_eq "denial cleared, not flagged"   "${#REPOS_DENIED[@]}" "0"

echo ""
echo "=== update_repo: denial with no automatic fix ==="
setup_repo_with_ref stuck "quay.io/konflux-ci/tekton-catalog/task-alwaysbad:1.0"
PATCHER_SCRIPT='true'
run_update
assert_eq "recorded DENIED"                  "${REPOS_DENIED[0]:-}" "testcomp:1"
assert_eq "NOT reported as already current"  "${#REPOS_SKIPPED[@]}" "0"
assert_eq "fix branch removed (no commit)"   "$(has_branch)" "no"
assert_eq "restored to original ref"         "$(cd "$TEST_REPO" && git rev-parse --abbrev-ref HEAD)" "work"
assert_contains "operator sees the denial"   "$(cat "$TMPROOT/out.txt")" "DENIED by EC"
assert_eq "report captured for the summary"  "${#DENY_REPORTS[@]}" "1"

echo ""
echo "=== update_repo: nothing denied, nothing to do ==="
setup_repo_with_ref clean "quay.io/konflux-ci/tekton-catalog/task-clamav-scan:0.3"
PATCHER_SCRIPT='true'
run_update
assert_eq "recorded SKIPPED"   "${REPOS_SKIPPED[0]:-}" "testcomp:no-changes"
assert_eq "not flagged DENIED" "${#REPOS_DENIED[@]}" "0"

echo ""
echo "=== update_repo: deny rules unavailable ==="
setup_repo_with_ref unchecked "quay.io/konflux-ci/tekton-catalog/task-alwaysbad:1.0"
PATCHER_SCRIPT='true'
run_update 0
assert_eq "behaves as before (SKIPPED)" "${REPOS_SKIPPED[0]:-}" "testcomp:no-changes"
REPOS_UPDATED=(); REPOS_FAILED=(); REPOS_DENIED=(); DENY_RULES_CHECKED=0
SUMMARY=$(print_summary 2>&1 || true)
assert_contains "summary says the check did not run" "$SUMMARY" "were NOT checked"

echo ""
echo "=== summary ==="
REPOS_UPDATED=("submariner#fix-tekton-tasks-0.99#release-0.99"); REPOS_SKIPPED=(); REPOS_FAILED=()
REPOS_DENIED=("submariner:1" "lighthouse:2"); DENY_RULES_CHECKED=1
SUMMARY=$(print_summary 2>&1 || true); DENY_RULES_CHECKED=0
assert_contains "denied section with count"     "$SUMMARY" "EC deny rules need a manual fix (2)"
assert_contains "each repo listed"              "$SUMMARY" "lighthouse (2 active denial(s))"
assert_contains "updated-but-denied is marked"  "$SUMMARY" "still denied by EC"

# PR command: component repos need the ready-to-test label so Konflux builds the
# PR; the FBC repo has no such label. (The sibling script already did this.)
REPOS_UPDATED=("submariner#fix-tekton-tasks-0.99#release-0.99" "fbc#fix-tekton-tasks-0.99#main")
REPOS_DENIED=(); REPOS_SKIPPED=(); REPOS_FAILED=(); DENY_RULES_CHECKED=1
SUMMARY=$(print_summary 2>&1 || true); DENY_RULES_CHECKED=0
assert_contains "component PR command carries ready-to-test" "$SUMMARY" "--assignee @me --label ready-to-test"
assert_eq "exactly one labeled command (FBC has none)" "$(printf '%s\n' "$SUMMARY" | grep -c 'label ready-to-test')" "1"

echo ""
echo "=== ec_log_diagnosis: deny rule is not blamed on a stale log ==="
DENY_MSG='Untrusted version of PipelineTask \"rpms-signature-scan\" (Task \"rpms-signature-scan\") was included in build chain comprised of: rpms-signature-scan. The denial reason is: deny_rule\n  - oci://quay.io/konflux-ci/konflux-vanguard/*\nMessages:\n  - Tasks under konflux-vanguard are no longer trusted. Use the equivalent from quay.io/konflux-ci/tekton-catalog instead.\n'
cat > "$HOME/Downloads/submariner-enterprise-fixture-verify.log" <<EOF
STEP-REPORT-JSON
{"success": false, "components": [{"name": "widget-0-99", "containerImage": "quay.io/example/widget@sha256:abc", "source": {"git": {"revision": "1111111111111111111111111111111111111111"}}, "success": false, "violations": [{"msg": "$DENY_MSG", "metadata": {"code": "trusted_task.trusted", "term": "rpms-signature-scan"}}]}]}
STEP-SUMMARY
{"successes": 1, "failures": 1, "warnings": 0, "result": "FAILURE"}
EOF
# Stub the cluster: one failing push snapshot whose EC test names a pipeline run.
oc() {
  case "$*" in
    whoami*) echo tester ;;
    "get snapshots"*) echo '{"items":[{"metadata":{"name":"submariner-0-99-abc","labels":{"pac.test.appstudio.openshift.io/event-type":"push"}}}]}' ;;
    "get snapshot submariner-0-99-abc"*) echo '[{"scenario":"submariner-enterprise-contract-registry-standard-0-99","status":"TestFail","testPipelineRunName":"plr-1"}]' ;;
    *) return 1 ;;
  esac
}
DIAG=$(ec_log_diagnosis 0.99.1 2>&1 || true)
unset -f oc
assert_contains "diagnosis shows the deny reason"    "$DIAG" "DENY_REASONS:"
assert_contains "reason text reaches the operator"   "$DIAG" "no longer trusted"
assert_contains "says a refresh cannot fix it"       "$DIAG" "a refresh cannot fix these"
assert_not_contains "no misleading stale-log advice" "$DIAG" "may be stale"

export HOME="$REAL_HOME"
echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "All $PASS tests passed"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
else
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "$FAIL of $((PASS + FAIL)) tests FAILED"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  exit 1
fi
