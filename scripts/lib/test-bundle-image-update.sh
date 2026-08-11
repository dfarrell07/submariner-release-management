#!/bin/bash
# Tests for bundle-image-update.sh.
# Run: ./scripts/lib/test-bundle-image-update.sh
#
# Sources the real script (main is guarded by BASH_SOURCE != $0, so sourcing runs
# no update). Covers the pure branch-misroute guard assert_expected_branch, which
# is the cross-step safety net keeping the SHA-bump commit off a stray fix branch.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../bundle-image-update.sh"

PASS=0 FAIL=0
# Assert assert_expected_branch(branch, 0.25, 0-25) returns the expected rc.
assert_branch() {  # <desc> <branch> <want-rc>
  local rc=0
  assert_expected_branch "$2" "0.25" "0-25" || rc=$?
  if [ "$rc" = "$3" ]; then echo "  ✓ $1"; PASS=$((PASS + 1))
  else echo "  ✗ $1 (branch '$2' got rc $rc, want $3)"; FAIL=$((FAIL + 1)); fi
}

echo "=== assert_expected_branch Tests ==="

# Intended branches for the version → accepted (rc 0)
assert_branch "release branch accepted"      "release-0.25"                    0
assert_branch "konflux bundle bot branch accepted" "konflux-submariner-bundle-0-25" 0

# Stray / wrong branches → refused (rc 1) — these are the misroute cases
assert_branch "cveFixes fix branch refused"  "fix-0.25-cves-20260819"          1
assert_branch "tekton fix branch refused"    "fix-tekton-tasks-0.25"           1
assert_branch "rpm-lockfile branch refused"  "update-rpm-lockfiles-0.25"       1
assert_branch "detached HEAD refused"        "HEAD"                            1
assert_branch "wrong-version release refused" "release-0.24"                   1
assert_branch "wrong-version bot branch refused" "konflux-submariner-bundle-0-24" 1
assert_branch "empty branch refused"         ""                                1
# Substring-of-a-good-name must not sneak through (exact match only)
assert_branch "release prefix substring refused" "release-0.250"              1

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
