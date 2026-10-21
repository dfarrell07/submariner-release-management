#!/bin/bash
# Tests for tekton-task-refs-update.sh.
# Run: ./scripts/lib/test-tekton-task-refs.sh
#
# Sources the real script (main is guarded by BASH_SOURCE != $0, so sourcing
# runs no release flow). Pure helpers (repo_path/repo_base_branch/parse_arguments)
# are tested directly; update_repo is exercised end-to-end against throwaway git
# repos with a fake PATCHER_SCRIPT, so the branch/restore/commit behavior is
# checked for real rather than stubbed.
# shellcheck disable=SC2034  # VERSION/MAJOR_MINOR/PATCHER_SCRIPT are read by sourced funcs
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_TEST_SCRIPT_DIR="$SCRIPT_DIR"  # save before source overwrites SCRIPT_DIR
source "$SCRIPT_DIR/../tekton-task-refs-update.sh"
SCRIPT_DIR="$_TEST_SCRIPT_DIR"  # restore for test-local path construction

PASS=0 FAIL=0
assert_eq() {
  if [ "$2" = "$3" ]; then echo "  ✓ $1"; PASS=$((PASS + 1))
  else echo "  ✗ $1 (got: '$2', want: '$3')"; FAIL=$((FAIL + 1)); fi
}
assert_contains() {
  if printf '%s' "$2" | grep -qF -- "$3"; then echo "  ✓ $1"; PASS=$((PASS + 1))
  else echo "  ✗ $1 (missing: '$3')"; FAIL=$((FAIL + 1)); fi
}

echo "=== repo_path / repo_base_branch Tests ==="

MAJOR_MINOR="0.23"
assert_eq "component path"      "$(repo_path submariner-operator)" "$HOME/go/src/submariner-io/submariner-operator"
assert_eq "fbc path (elsewhere)" "$(repo_path fbc)"                "$HOME/konflux/submariner-operator-fbc"
assert_eq "component base = release-MM" "$(repo_base_branch submariner)" "release-0.23"
assert_eq "fbc base = main"             "$(repo_base_branch fbc)"        "main"

# FBC_REPO_DEFAULT propagation: jira-tracker.sh defines FBC_REPO_DEFAULT once;
# tekton-task-refs-update.sh sources it before the readonly FBC_REPO_PATH
# assignment so that a pre-set env var is respected. Test via subshell because
# FBC_REPO_PATH is readonly in the current shell and cannot be re-assigned.
_TEKTON_SCRIPT="$SCRIPT_DIR/../tekton-task-refs-update.sh"
_fbc_default_result=$(
  env FBC_REPO_DEFAULT=/tmp/alt-fbc-$$ _TEKTON_SCRIPT="$_TEKTON_SCRIPT" bash -c '
    unset _JIRA_TRACKER_SOURCED
    source "$_TEKTON_SCRIPT"
    repo_path fbc
  ' 2>/dev/null
) || true
assert_eq "fbc path from FBC_REPO_DEFAULT env" "$_fbc_default_result" "/tmp/alt-fbc-$$"

_fbc_override_result=$(
  env FBC_REPO=/tmp/custom-fbc-$$ _TEKTON_SCRIPT="$_TEKTON_SCRIPT" bash -c '
    source "$_TEKTON_SCRIPT"
    repo_path fbc
  ' 2>/dev/null
) || true
assert_eq "fbc path from FBC_REPO env override (beats FBC_REPO_DEFAULT)" \
  "$_fbc_override_result" "/tmp/custom-fbc-$$"

echo ""
echo "=== parse_arguments Tests ==="

# Valid X.Y.Z sets globals (run in current shell to read them back)
VERSION=""; MAJOR_MINOR=""; REPO_FILTER=""
parse_arguments "0.23.1" >/dev/null 2>&1
assert_eq "valid version accepted"  "$VERSION" "0.23.1"
assert_eq "major.minor derived"     "$MAJOR_MINOR" "0.23"
assert_eq "no filter by default"    "$REPO_FILTER" ""

VERSION=""; REPO_FILTER=""
parse_arguments "0.23.1" "fbc" >/dev/null 2>&1
assert_eq "valid repo filter accepted" "$REPO_FILTER" "fbc"

# Invalid inputs exit non-zero (subshell so the test survives)
rc=0; ( parse_arguments "0.23" )       >/dev/null 2>&1 || rc=$?
assert_eq "2-segment version rejected"  "$rc" "1"
rc=0; ( parse_arguments "" )           >/dev/null 2>&1 || rc=$?
assert_eq "empty version rejected"      "$rc" "1"
rc=0; ( parse_arguments "0.23.1" "nope" ) >/dev/null 2>&1 || rc=$?
assert_eq "unknown repo rejected"       "$rc" "1"
rc=0; ( parse_arguments "0.23.1" "fbc" "extra" ) >/dev/null 2>&1 || rc=$?
assert_eq "too many args rejected"      "$rc" "1"

echo ""
echo "=== update_repo Tests (real git) ==="

# Throwaway git repo: base branch 'release-0.99' carries .tekton/pipe.yaml; HEAD
# is left on 'work' so we can assert the original ref is restored.
TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT
# Lifecycle cases isolate repair selection; the real selector is tested below.
declare -f repair_moved_task_refs > "$TMPROOT/real-repair.sh"
repair_moved_task_refs() { printf '%s' "$PATCHER_SCRIPT" | bash -s; }
deny_rules_scan() { :; }
DENY_RULES_CHECKED=1
TEST_REPO=""
setup_repo() {
  TEST_REPO="$TMPROOT/repo-$1"
  rm -rf "$TEST_REPO"; mkdir -p "$TEST_REPO"
  (
    cd "$TEST_REPO"
    git init -q
    git config user.email t@t; git config user.name t
    git checkout -q -b release-0.99
    mkdir .tekton; printf 'task: v1\n' > .tekton/pipe.yaml
    git add -A; git commit -qm base
    git init -q --bare "$TEST_REPO-origin.git"
    git remote add origin "$TEST_REPO-origin.git"
    git push -q origin release-0.99
    git checkout -q -b work   # HEAD on 'work' (== original ref)
  )
}

# Point the path/base helpers at the throwaway repo; MAJOR_MINOR names the branch.
repo_path()        { echo "$TEST_REPO"; }
repo_base_branch() { echo "release-0.99"; }
VERSION="0.99.1"
MAJOR_MINOR="0.99"
ORIG_DIR=$(pwd)

run_update() {  # reset per-case state, then run against a fresh repo
  REPOS_UPDATED=(); REPOS_SKIPPED=(); REPOS_FAILED=()
  update_repo testcomp >/dev/null 2>&1 || true
  cd "$ORIG_DIR"
}

# 1: Patcher changes files → commit on fix branch, original ref restored.
setup_repo happy
PATCHER_SCRIPT='printf "task: v2\n" > .tekton/pipe.yaml'
run_update
assert_eq "happy: recorded UPDATED" "${REPOS_UPDATED[0]:-}" "testcomp#fix-tekton-tasks-0.99.1#release-0.99"
assert_eq "happy: no failures"      "${#REPOS_FAILED[@]}" "0"
assert_eq "happy: restored to original ref" "$(cd "$TEST_REPO" && git rev-parse --abbrev-ref HEAD)" "work"
assert_eq "happy: fix branch kept (holds commit)" \
  "$(cd "$TEST_REPO" && git show-ref --verify --quiet refs/heads/fix-tekton-tasks-0.99.1 && echo yes || echo no)" "yes"
assert_eq "happy: commit landed on fix branch" \
  "$(cd "$TEST_REPO" && git show fix-tekton-tasks-0.99.1:.tekton/pipe.yaml)" "task: v2"

# Fresh upstream source must be included even when the local tracking ref is old.
setup_repo stale
(cd "$TEST_REPO"
  git checkout -q release-0.99
  printf 'new upstream source\n' > upstream-only
  git add upstream-only; git commit -qm 'Upstream source'
  git push -q origin release-0.99
  git update-ref refs/remotes/origin/release-0.99 work
  git checkout -q work)
PATCHER_SCRIPT='printf "task: v2\n" > .tekton/pipe.yaml'
run_update
stale_branch="${REPOS_UPDATED[0]#*#}"; stale_branch="${stale_branch%%#*}"
assert_eq "stale: update includes fresh upstream source" \
  "$(git -C "$TEST_REPO" show "$stale_branch:upstream-only" 2>/dev/null || true)" "new upstream source"

# A failed fetch must leave original refs/work intact and create no fix branch.
setup_repo fetchfail
(cd "$TEST_REPO"; git remote set-url origin "$TMPROOT/missing-origin")
run_update
assert_eq "fetch failure recorded" "${REPOS_FAILED[0]:-}" "testcomp:fetch-failed"
assert_eq "fetch failure preserves original branch" "$(git -C "$TEST_REPO" branch --show-current)" work
assert_eq "fetch failure creates no fix branch" \
  "$(git -C "$TEST_REPO" branch --list fix-tekton-tasks-0.99.1)" ""

# 2: Patcher is a no-op → skipped, fix branch deleted, original ref restored.
setup_repo noop
PATCHER_SCRIPT='true'
run_update
assert_eq "noop: recorded SKIPPED"  "${REPOS_SKIPPED[0]:-}" "testcomp:no-changes"
assert_eq "noop: no updates"        "${#REPOS_UPDATED[@]}" "0"
assert_eq "noop: fix branch removed" \
  "$(cd "$TEST_REPO" && git show-ref --verify --quiet refs/heads/fix-tekton-tasks-0.99.1 && echo yes || echo no)" "no"
assert_eq "noop: restored to original ref" "$(cd "$TEST_REPO" && git rev-parse --abbrev-ref HEAD)" "work"

# 3: Dirty working tree → auto-stashed, updated successfully, stash restored after.
setup_repo dirty
printf 'dirty\n' >> "$TMPROOT/repo-dirty/.tekton/pipe.yaml"
PATCHER_SCRIPT='printf "task: v2\n" > .tekton/pipe.yaml'
run_update
assert_eq "dirty: succeeded (not failed)" "${#REPOS_FAILED[@]}" "0"
assert_eq "dirty: recorded UPDATED" "${REPOS_UPDATED[0]:-}" "testcomp#fix-tekton-tasks-0.99.1#release-0.99"
assert_eq "dirty: restored to original ref" "$(cd "$TEST_REPO" && git rev-parse --abbrev-ref HEAD)" "work"
# The unstaged dirty change was stashed before the branch switch; stash popped after restore.
assert_eq "dirty: stash popped (unstaged change back)" \
  "$(cd "$TEST_REPO" && git diff --name-only)" ".tekton/pipe.yaml"

# 4: Base branch missing → failure (needs a fetch), not a silent skip.
setup_repo nobranch
repo_base_branch() { echo "release-9.99"; }
PATCHER_SCRIPT='true'
run_update
assert_eq "missing base: recorded FAILED" "${REPOS_FAILED[0]:-}" "testcomp:branch-not-found"
repo_base_branch() { echo "release-0.99"; }   # restore for any later cases

# 5: Detached HEAD → restore must land back on the original commit, not the fix
# branch tip. `--abbrev-ref` prints "HEAD" here, so this guards the SHA fallback.
setup_repo detached
DETACHED_SHA=$(cd "$TEST_REPO" && git rev-parse release-0.99)   # base commit
(cd "$TEST_REPO" && git checkout -q "$DETACHED_SHA")            # detach HEAD
PATCHER_SCRIPT='printf "task: v2\n" > .tekton/pipe.yaml'
run_update
assert_eq "detached: recorded UPDATED" "${REPOS_UPDATED[0]:-}" "testcomp#fix-tekton-tasks-0.99.1#release-0.99"
assert_eq "detached: restored to original commit (not fix tip)" \
  "$(cd "$TEST_REPO" && git rev-parse HEAD)" "$DETACHED_SHA"
assert_eq "detached: fix branch kept (holds commit)" \
  "$(cd "$TEST_REPO" && git show-ref --verify --quiet refs/heads/fix-tekton-tasks-0.99.1 && echo yes || echo no)" "yes"

# 6: Patcher edits .tekton/ then fails → restore must discard the dirty partial edit
# and land back on the original ref with no fix branch. A plain (non-forced) checkout
# would refuse over the dirty tree and strand the repo on the fix branch, so this
# guards the forced-restore in _restore_repo.
setup_repo patcherfail
PATCHER_SCRIPT='printf "task: v2\n" > .tekton/pipe.yaml; exit 1'
run_update
assert_eq "patcher-fail: recorded FAILED" "${REPOS_FAILED[0]:-}" "testcomp:patcher-failed"
assert_eq "patcher-fail: restored to original ref" "$(cd "$TEST_REPO" && git rev-parse --abbrev-ref HEAD)" "work"
assert_eq "patcher-fail: fix branch removed" \
  "$(cd "$TEST_REPO" && git show-ref --verify --quiet refs/heads/fix-tekton-tasks-0.99.1 && echo yes || echo no)" "no"
assert_eq "patcher-fail: partial edit discarded (tree clean)" \
  "$(cd "$TEST_REPO" && git status --porcelain)" ""

# ── EC deny-rule handling (update_repo end-to-end) ─────────────────────────────
echo ""
echo "=== update_repo: EC deny rules ==="

POLICY="$TMPROOT/policy.json"
cat > "$POLICY" <<'EOF'
{"rule_data":{"trusted_task_rules":{"deny":{
  "konflux-defaults":[
    {"pattern":"oci://quay.io/konflux-ci/tekton-catalog/task-buildah","versions":["<0.9"]},
    {"effective_on":"2099-01-01T00:00:00Z","pattern":"oci://quay.io/konflux-ci/tekton-catalog/task-soonbad","versions":["<2.0"]}
  ],
  "konflux-defaults-deprecated":[
    {"effective_on":"2026-09-24T00:00:00Z","message":"Tasks under konflux-vanguard are no longer trusted. Use the equivalent from quay.io/konflux-ci/tekton-catalog instead.\n","pattern":"oci://quay.io/konflux-ci/konflux-vanguard/*"}
  ]
}}}}
EOF
export DENY_RULES_NOW="2026-09-28T00:00:00Z"
# Source the library directly (rather than relying on the script under test to have
# done so), so a script that lacks the deny handling fails the assertions below
# instead of crashing on a missing function.
# shellcheck source=deny-rules.sh
source "$SCRIPT_DIR/deny-rules.sh"
source "$TMPROOT/real-repair.sh"
REPOS_DENIED=()
DENY_RULES_CHECKED=0
DENY_RULES_FILE="$POLICY" deny_rules_load 2>/dev/null

DG="sha256:$(printf 'b%.0s' $(seq 64))"
setup_repo_with_ref() {  # $1=name $2="repo:tag" — a real bundle-resolver pipeline
  setup_repo "$1"
  (
    cd "$TEST_REPO"
    git checkout -q release-0.99
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
    git add -A; git commit -qm "with ref"
    git push -q origin release-0.99
    git checkout -q work; git merge -q release-0.99 --ff-only 2>/dev/null || git checkout -q -B work release-0.99
  )
}
run_update_deny() {
  REPOS_UPDATED=(); REPOS_SKIPPED=(); REPOS_FAILED=(); REPOS_DENIED=()
  DENY_RULES_CHECKED=1
  update_repo testcomp >/dev/null 2>&1 || true
  DENY_RULES_CHECKED=0
  cd "$ORIG_DIR"
}
has_branch() { (cd "$TEST_REPO" && git show-ref --verify --quiet refs/heads/fix-tekton-tasks-0.99.1 && echo yes || echo no); }

# 7: patcher is a no-op but a minimum-version denial remains → NOT "already
# current": recorded DENIED, no fix branch left behind, repo restored and clean.
setup_repo_with_ref denied1 "quay.io/konflux-ci/tekton-catalog/task-buildah:0.8"
PATCHER_SCRIPT='true'
run_update_deny
assert_eq "denied+noop: recorded DENIED"        "${REPOS_DENIED[0]:-}" "testcomp:1"
assert_eq "denied+noop: NOT reported as current" "${#REPOS_SKIPPED[@]}" "0"
assert_eq "denied+noop: no updates"             "${#REPOS_UPDATED[@]}" "0"
assert_eq "denied+noop: fix branch removed"     "$(has_branch)" "no"
assert_eq "denied+noop: restored to original ref" "$(cd "$TEST_REPO" && git rev-parse --abbrev-ref HEAD)" "work"
assert_eq "denied+noop: tree clean"             "$(cd "$TEST_REPO" && git status --porcelain)" ""

# 8: A minimum-version denial needs manual review. Unrelated refs stay intact,
# and the patcher must not be invoked simply because it offers newer digests.
setup_repo_with_ref denied2 "quay.io/konflux-ci/tekton-catalog/task-buildah:0.8"
PATCHER_SCRIPT='sed -i "s/^spec:/spec:\n  refreshed: true/" .tekton/pipe.yaml'
run_update_deny
assert_eq "denied+refresh: no unrelated commit" "${#REPOS_UPDATED[@]}" "0"
assert_eq "denied+refresh: also flagged DENIED" "${REPOS_DENIED[0]:-}" "testcomp:1"
assert_eq "denied+refresh: no fix branch" "$(has_branch)" "no"

# 9: a denial whose message names a replacement catalog is rewritten BEFORE the
# patcher runs. The fake patcher aborts if it still sees the retired catalog —
# what the real pipeline-patcher does — so success proves the ordering.
setup_repo_with_ref moved "quay.io/konflux-ci/konflux-vanguard/task-rpms-signature-scan:0.2"
PATCHER_SCRIPT='[ "$1" = task-ref ] || exit 99; if grep -q konflux-vanguard .tekton/pipe.yaml; then exit 98; fi; printf "%s@sha256:%064d\n" "${2%@*}" 1'
run_update_deny
assert_eq "moved: patcher saw rewritten ref (no failure)" "${#REPOS_FAILED[@]}" "0"
assert_eq "moved: committed"                    "${REPOS_UPDATED[0]:-}" "testcomp#fix-tekton-tasks-0.99.1#release-0.99"
assert_eq "moved: nothing left denied"          "${#REPOS_DENIED[@]}" "0"
assert_eq "moved: commit carries tekton-catalog ref" \
  "$(cd "$TEST_REPO" && git show fix-tekton-tasks-0.99.1:.tekton/pipe.yaml | grep -c 'tekton-catalog/task-rpms-signature-scan:0.2@')" "1"
MOVED_MSG=$(cd "$TEST_REPO" && git log -1 --format=%B fix-tekton-tasks-0.99.1 2>/dev/null || true)
assert_contains "moved: commit message explains the replacement" "$MOVED_MSG" "Replaces task refs that EC denies"
assert_contains "moved: commit message lists the old ref" "$MOVED_MSG" "- konflux-vanguard/task-rpms-signature-scan"
assert_contains "moved: commit message lists the new ref"  "$MOVED_MSG" "  -> tekton-catalog/task-rpms-signature-scan:0.2"
assert_eq "moved: no commit message line exceeds 80 characters (gitlint)" \
  "$(printf '%s\n' "$MOVED_MSG" | awk 'length > 80' | wc -l | tr -d ' ')" "0"
assert_eq "moved: commit has no vanguard ref"   \
  "$(cd "$TEST_REPO" && git show fix-tekton-tasks-0.99.1:.tekton/pipe.yaml | grep -c konflux-vanguard || true)" "0"

# An accepted older pin alongside the moved task must remain byte-for-byte intact.
setup_repo_with_ref preserve "quay.io/konflux-ci/konflux-vanguard/task-rpms-signature-scan:0.2"
(
  cd "$TEST_REPO"
  git checkout -q release-0.99
  cp .tekton/pipe.yaml .tekton/accepted.yml
  printf 'apiVersion: config.openshift.io/v1\nkind: ImageDigestMirrorSet\nspec: {}\n' > .tekton/images-mirror-set.yaml
  sed -i 's#konflux-vanguard/task-rpms-signature-scan:0.2#tekton-catalog/task-clamav-scan:0.3#' .tekton/accepted.yml
  git add .tekton/accepted.yml .tekton/images-mirror-set.yaml; git commit -qm accepted
  git push -q origin release-0.99; git checkout -q work
)
PATCHER_SCRIPT='[ "$1" = task-ref ] && [[ "$2" == *task-rpms-signature-scan:* ]] || exit 99; printf "%s@sha256:%064d\n" "${2%@*}" 1'
run_update_deny
assert_eq "preserve: no repair failure" "${#REPOS_FAILED[@]}" 0
assert_eq "preserve: unrelated accepted digest unchanged" \
  "$(git -C "$TEST_REPO" diff origin/release-0.99 fix-tekton-tasks-0.99.1 -- .tekton/accepted.yml)" ""
assert_eq "preserve: unrelated Tekton mirror config unchanged" \
  "$(git -C "$TEST_REPO" diff origin/release-0.99 fix-tekton-tasks-0.99.1 -- .tekton/images-mirror-set.yaml)" ""
assert_contains "moved: replacement digest repinned" \
  "$(git -C "$TEST_REPO" show fix-tekton-tasks-0.99.1:.tekton/pipe.yaml)" "@sha256:$(printf '%064d' 1)"

# Collapsing a moved ref into an existing exact target must not skip its re-pin.
setup_repo_with_ref collision "quay.io/konflux-ci/konflux-vanguard/task-rpms-signature-scan:0.2"
(
  cd "$TEST_REPO"; git checkout -q release-0.99
  sed 's#konflux-vanguard/#tekton-catalog/#' .tekton/pipe.yaml > .tekton/existing.yml
  git add .tekton/existing.yml; git commit -qm collision
  git push -q origin release-0.99; git checkout -q work
)
PATCHER_SCRIPT='exit 99'
run_update_deny
assert_eq "collision: fails instead of bypassing re-pin" "${REPOS_FAILED[0]:-}" "testcomp:patcher-failed"
assert_eq "collision: no repair commit" "${#REPOS_UPDATED[@]}" 0
assert_eq "collision: no fix branch" "$(has_branch)" no
assert_eq "collision: original branch restored" "$(git -C "$TEST_REPO" branch --show-current)" work
assert_eq "collision: worktree clean" "$(git -C "$TEST_REPO" status --porcelain)" ""

# Invalid replacement output or unavailable trusted data must discard partial edits.
for failure_case in invalid unavailable; do
  setup_repo_with_ref "replacement-$failure_case" "quay.io/konflux-ci/konflux-vanguard/task-rpms-signature-scan:0.2"
  if [ "$failure_case" = invalid ]; then PATCHER_SCRIPT='echo quay.io/other/task:0.2@sha256:bad'
  else PATCHER_SCRIPT='exit 1'; fi
  run_update_deny
  assert_eq "$failure_case: repair failed" "${REPOS_FAILED[0]:-}" "testcomp:patcher-failed"
  assert_eq "$failure_case: no fix branch" "$(has_branch)" no
  assert_eq "$failure_case: original worktree restored" "$(git -C "$TEST_REPO" status --porcelain)" ""
done

for yaml_case in malformed missing-ref duplicate-ref; do
  setup_repo_with_ref "$yaml_case" "quay.io/konflux-ci/tekton-catalog/task-clamav-scan:0.3"
  (
    cd "$TEST_REPO"; git checkout -q release-0.99
    case "$yaml_case" in
      malformed) printf 'spec: [\n' > .tekton/extra.yml ;;
      missing-ref) printf 'taskRef:\n  resolver: bundles\n  params: []\n' > .tekton/extra.yml ;;
      duplicate-ref)
        printf 'taskRef:\n  resolver: bundles\n  params:\n' > .tekton/extra.yml
        for i in 1 2; do
          printf '    - name: bundle\n      value: quay.io/konflux-ci/tekton-catalog/task-clamav-scan:0.3@%s\n' "$DG" >> .tekton/extra.yml
        done ;;
    esac
    git add .tekton/extra.yml; git commit -qm "$yaml_case"
    git push -q origin release-0.99; git checkout -q work
  )
  PATCHER_SCRIPT='exit 99'
  run_update_deny
  assert_eq "$yaml_case: not mistaken for clean no-op" "${REPOS_FAILED[0]:-}" "testcomp:patcher-failed"
done

# 10: a future-dated denial only warns — no DENIED, still "already current".
setup_repo_with_ref future "quay.io/konflux-ci/tekton-catalog/task-soonbad:1.0"
PATCHER_SCRIPT='true'
run_update_deny
assert_eq "future: not DENIED"                  "${#REPOS_DENIED[@]}" "0"
assert_eq "future: recorded SKIPPED (no changes)" "${REPOS_SKIPPED[0]:-}" "testcomp:no-changes"

# 11: patcher failure on a missing trusted-list entry prints the deny-rule hint.
setup_repo_with_ref hint "quay.io/konflux-ci/konflux-vanguard/task-rpms-signature-scan:0.2"
PATCHER_SCRIPT='echo "Can'"'"'t find oci://x in the trusted task list. Aborting."; exit 1'
REPOS_UPDATED=(); REPOS_SKIPPED=(); REPOS_FAILED=(); REPOS_DENIED=(); DENY_RULES_CHECKED=1
HINT_OUT=$(update_repo testcomp 2>&1 || true); DENY_RULES_CHECKED=0; cd "$ORIG_DIR"
assert_contains "hint: patcher failure names the likely cause" "$HINT_OUT" "denied or"

# 12: Missing deny data fails closed instead of recording a clean no-op.
setup_repo_with_ref unchecked "quay.io/konflux-ci/tekton-catalog/task-buildah:0.8"
PATCHER_SCRIPT='true'
REPOS_UPDATED=(); REPOS_SKIPPED=(); REPOS_FAILED=(); REPOS_DENIED=(); DENY_RULES_CHECKED=0
update_repo testcomp >/dev/null 2>&1 || true; cd "$ORIG_DIR"
assert_eq "unchecked: no clean no-op" "${#REPOS_SKIPPED[@]}" "0"
assert_eq "unchecked: failure recorded" "${REPOS_FAILED[0]:-}" "testcomp:deny-rules-unchecked"
SUMMARY=$(print_summary 2>&1 || true)
assert_contains "unchecked: summary warns deny rules were not checked" "$SUMMARY" "were NOT checked"

# 13: summary lists denied repos and fails (exit status feeds the conductor).
REPOS_UPDATED=(); REPOS_SKIPPED=(); REPOS_FAILED=(); REPOS_DENIED=("testcomp:2"); DENY_RULES_CHECKED=1
RC=0; SUMMARY=$(print_summary 2>&1) || RC=$?
DENY_RULES_CHECKED=0
assert_contains "summary: denied section shown"  "$SUMMARY" "EC deny rules need a manual fix (1)"
assert_contains "summary: repo and count shown"  "$SUMMARY" "testcomp (2 active denial(s))"
assert_eq "summary: non-zero status when a denial needs a manual fix" "$([ "$RC" -ne 0 ] && echo nonzero || echo zero)" "nonzero"

# Full no-op runs complete after checking every repo; partial/failed/pending work
# must stay incomplete. External patcher/policy/Jira calls are local stubs.
for tracker_case in current updated failed denied partial missing-result ec-step description-failed; do
  tracker_result=$(
    _LIB_DIR="$TMPROOT/tracker-$tracker_case"
    mkdir -p "$_LIB_DIR"
    printf 'download_and_verify_patcher() { echo true; }\n' > "$_LIB_DIR/pipeline-patcher.sh"
    printf 'find_release_tracker() { echo TEST-1; }\nupdate_step() { echo "$3" >> "$transitions"; }\n' > "$_LIB_DIR/jira-tracker.sh"
    update_subtask_description() {
      [ "$tracker_case" != description-failed ] || return 1
      [[ "$3" == *'No catalog repair or new PR is needed.'* &&
         "$3" == *'Enterprise Contract validation remains a separate release gate.'* ]] || return 1
      echo description >> "$transitions"
    }
    transitions="$_LIB_DIR/transitions"
    TRACKER_LIB="$_LIB_DIR/jira-tracker.sh"
    check_prerequisites() { :; }
    deny_rules_load() { return 0; }
    REPOS_UPDATED=(); REPOS_FAILED=(); REPOS_SKIPPED=(); REPOS_DENIED=(); REPO_FILTER=""
    update_all() {
      for repo in $REPO_ORDER; do REPOS_SKIPPED+=("$repo:no-changes"); done
      case "$tracker_case" in
        updated) REPOS_SKIPPED=(); REPOS_UPDATED=(testcomp#fix-tekton-tasks-0.99.1#release-0.99) ;;
        failed) REPOS_FAILED=(testcomp:fetch-failed) ;;
        denied) REPOS_DENIED=(testcomp:1) ;;
        missing-result) REPOS_SKIPPED=() ;;
      esac
    }
    get_gh_user() { :; }
    fork_remote() { echo fork; }
    AUTORELEASE_TRACKER_STEP=tektonTasks
    [ "$tracker_case" != ec-step ] || AUTORELEASE_TRACKER_STEP=ecFixes
    rc=0
    if [ "$tracker_case" = partial ]; then main 0.99.1 fbc >/dev/null || rc=$?
    else main 0.99.1 >/dev/null || rc=$?; fi
    [ ! -f "$transitions" ] || cat "$transitions"
    printf 'rc=%s' "$rc"
  )
  expected=$'in_progress\nrc=0'
  case "$tracker_case" in
    current) expected=$'in_progress\ndescription\ncomplete\nrc=0' ;;
    partial) expected=rc=0 ;;
    ec-step) expected=$'in_progress\nrc=2' ;;
    failed|denied|description-failed) expected=$'in_progress\nrc=1' ;;
  esac
  assert_eq "tracker: $tracker_case" "$tracker_result" "$expected"
done

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "All $PASS tests passed"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  exit 0
else
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "$FAIL of $((PASS + FAIL)) tests FAILED"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  exit 1
fi
