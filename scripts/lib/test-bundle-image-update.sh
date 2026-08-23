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
echo "=== find_snapshot Stale-Snapshot Warning Tests ==="

# Set up globals required by find_snapshot (sourced from bundle-image-update.sh).
# shellcheck disable=SC2034  # consumed by find_snapshot in the sourced script
SNAPSHOT_ARG=""
# shellcheck disable=SC2034  # consumed by find_snapshot in the sourced script
VERSION_DASH="0-25"
# shellcheck disable=SC2034  # consumed by find_snapshot in the sourced script
VERSION_DOT="0.25.0"
TARGET_VERSION="0.25.0"

# Snap built BEFORE the tag → warning must fire.
# Snap time: 2026-01-01T00:00:00Z  Tag time: 2026-01-01T01:30:00Z (~90 min later)
_snap_name="submariner-0-25-abc123"
_snap_ts="2026-01-01T00:00:00+00:00"
_tag_ts="2026-01-01T01:30:00+00:00"

oc() {
  local args="$*"
  if [[ "$args" == *"-o name"* ]]; then
    echo "snapshot.appstudio.redhat.com/$_snap_name"
  elif [[ "$args" == *"AppStudioTestSucceeded"* ]]; then
    echo "True"
  elif [[ "$args" == *"creationTimestamp"* ]]; then
    echo "$_snap_ts"
  fi
}
# _get_tag_creation_time makes TWO gh api calls:
#   1. "repos/.../git/refs/tags/vX.Y.Z" → JSON with .object.type / .object.url
#   2. The resolved URL (--jq extracts the date) → returns the timestamp string.
# Mock dispatches on whether "git/refs/tags" appears in the arguments.
gh() {
  if [[ "$*" == *"git/refs/tags"* ]]; then
    printf '{"object":{"type":"commit","url":"https://fake-api/commits/abc"}}\n'
  else
    echo "$_tag_ts"
  fi
}

stale_warn=$(find_snapshot 2>&1 >/dev/null) || true
if printf '%s' "$stale_warn" | grep -qF "WARNING: snapshot predates release tag"; then
  echo "  ✓ stale-snapshot: warning fires when snap predates tag"; PASS=$((PASS + 1))
else
  echo "  ✗ stale-snapshot: warning fires when snap predates tag (got: '$stale_warn')"; FAIL=$((FAIL + 1))
fi
if printf '%s' "$stale_warn" | grep -qF "v$TARGET_VERSION"; then
  echo "  ✓ stale-snapshot: warning names the release tag"; PASS=$((PASS + 1))
else
  echo "  ✗ stale-snapshot: warning names the release tag (got: '$stale_warn')"; FAIL=$((FAIL + 1))
fi

# Snap built AFTER the tag → no warning.
_snap_ts="2026-01-01T03:00:00+00:00"  # newer than tag
stale_warn2=$(find_snapshot 2>&1 >/dev/null) || true
if printf '%s' "$stale_warn2" | grep -qF "WARNING: snapshot predates release tag"; then
  echo "  ✗ stale-snapshot: no warning when snap is newer than tag (got: '$stale_warn2')"; FAIL=$((FAIL + 1))
else
  echo "  ✓ stale-snapshot: no warning when snap is newer than tag"; PASS=$((PASS + 1))
fi

# gh unavailable (not authenticated / not installed) → no warning, no crash.
_snap_ts="2026-01-01T00:00:00+00:00"
gh() { return 1; }  # simulates gh auth failure or absent
stale_warn3=$(find_snapshot 2>&1 >/dev/null) || true
if printf '%s' "$stale_warn3" | grep -qF "WARNING: snapshot predates release tag"; then
  echo "  ✗ stale-snapshot: no warning when gh unavailable (got: '$stale_warn3')"; FAIL=$((FAIL + 1))
else
  echo "  ✓ stale-snapshot: no warning when gh unavailable (warn-only guard)"; PASS=$((PASS + 1))
fi

# Restore stubs
unset -f oc gh

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
