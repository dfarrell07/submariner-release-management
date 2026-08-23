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
source "$SCRIPT_DIR/../tekton-task-refs-update.sh"

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
_fbc_default_result=$(
  env FBC_REPO_DEFAULT=/tmp/alt-fbc-$$ bash -c "
    unset _JIRA_TRACKER_SOURCED
    source '$SCRIPT_DIR/../tekton-task-refs-update.sh' 2>/dev/null || true
    repo_path fbc
  " 2>/dev/null
)
assert_eq "fbc path from FBC_REPO_DEFAULT env" "$_fbc_default_result" "/tmp/alt-fbc-$$"

_fbc_override_result=$(
  env FBC_REPO=/tmp/custom-fbc-$$ bash -c "
    source '$SCRIPT_DIR/../tekton-task-refs-update.sh' 2>/dev/null || true
    repo_path fbc
  " 2>/dev/null
)
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
    git checkout -q -b work   # HEAD on 'work' (== original ref)
  )
}

# Point the path/base helpers at the throwaway repo; MAJOR_MINOR names the branch.
repo_path()        { echo "$TEST_REPO"; }
repo_base_branch() { echo "release-0.99"; }
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
assert_eq "happy: recorded UPDATED" "${REPOS_UPDATED[0]:-}" "testcomp#fix-tekton-tasks-0.99#release-0.99"
assert_eq "happy: no failures"      "${#REPOS_FAILED[@]}" "0"
assert_eq "happy: restored to original ref" "$(cd "$TEST_REPO" && git rev-parse --abbrev-ref HEAD)" "work"
assert_eq "happy: fix branch kept (holds commit)" \
  "$(cd "$TEST_REPO" && git show-ref --verify --quiet refs/heads/fix-tekton-tasks-0.99 && echo yes || echo no)" "yes"
assert_eq "happy: commit landed on fix branch" \
  "$(cd "$TEST_REPO" && git show fix-tekton-tasks-0.99:.tekton/pipe.yaml)" "task: v2"

# 2: Patcher is a no-op → skipped, fix branch deleted, original ref restored.
setup_repo noop
PATCHER_SCRIPT='true'
run_update
assert_eq "noop: recorded SKIPPED"  "${REPOS_SKIPPED[0]:-}" "testcomp:no-changes"
assert_eq "noop: no updates"        "${#REPOS_UPDATED[@]}" "0"
assert_eq "noop: fix branch removed" \
  "$(cd "$TEST_REPO" && git show-ref --verify --quiet refs/heads/fix-tekton-tasks-0.99 && echo yes || echo no)" "no"
assert_eq "noop: restored to original ref" "$(cd "$TEST_REPO" && git rev-parse --abbrev-ref HEAD)" "work"

# 3: Dirty working tree → refused, no branch created, left untouched.
setup_repo dirty
printf 'dirty\n' >> "$TMPROOT/repo-dirty/.tekton/pipe.yaml"
PATCHER_SCRIPT='printf "task: v2\n" > .tekton/pipe.yaml'
run_update
assert_eq "dirty: recorded FAILED"  "${REPOS_FAILED[0]:-}" "testcomp:dirty-tree"
assert_eq "dirty: still on original ref" "$(cd "$TEST_REPO" && git rev-parse --abbrev-ref HEAD)" "work"
assert_eq "dirty: no fix branch created" \
  "$(cd "$TEST_REPO" && git show-ref --verify --quiet refs/heads/fix-tekton-tasks-0.99 && echo yes || echo no)" "no"

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
assert_eq "detached: recorded UPDATED" "${REPOS_UPDATED[0]:-}" "testcomp#fix-tekton-tasks-0.99#release-0.99"
assert_eq "detached: restored to original commit (not fix tip)" \
  "$(cd "$TEST_REPO" && git rev-parse HEAD)" "$DETACHED_SHA"
assert_eq "detached: fix branch kept (holds commit)" \
  "$(cd "$TEST_REPO" && git show-ref --verify --quiet refs/heads/fix-tekton-tasks-0.99 && echo yes || echo no)" "yes"

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
  "$(cd "$TEST_REPO" && git show-ref --verify --quiet refs/heads/fix-tekton-tasks-0.99 && echo yes || echo no)" "no"
assert_eq "patcher-fail: partial edit discarded (tree clean)" \
  "$(cd "$TEST_REPO" && git status --porcelain)" ""

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
