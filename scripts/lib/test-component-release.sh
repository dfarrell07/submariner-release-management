#!/bin/bash
# Tests for create-component-release.sh's bundle-freshness gate.
# Run: ./scripts/lib/test-component-release.sh
#
# Sources the REAL assert_bundle_rebuilt / _bundle_digest (main is guarded by
# BASH_SOURCE != $0, so sourcing runs no release flow). oc, get_step, and
# update_step are stubbed; spy files survive command-substitution subshells so
# read-only / short-circuit claims are checkable.
# shellcheck disable=SC2034  # VERSION/RELEASE_TYPE/TRACKER/SNAPSHOT_NAME are read by the sourced gate
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../create-component-release.sh"

PASS=0 FAIL=0
assert_eq() {
  if [ "$2" = "$3" ]; then echo "  ✓ $1"; PASS=$((PASS + 1))
  else echo "  ✗ $1 (got: '$2', want: '$3')"; FAIL=$((FAIL + 1)); fi
}
assert_contains() {
  if printf '%s' "$2" | grep -qF -- "$3"; then echo "  ✓ $1"; PASS=$((PASS + 1))
  else echo "  ✗ $1 (missing: '$3')"; FAIL=$((FAIL + 1)); fi
}

# --- Spies (files, so subshell writes survive) + stubs ---
CLUSTER_SPY=$(mktemp); TRACKER_SPY=$(mktemp); WRITE_SPY=$(mktemp)
trap 'rm -f "$CLUSTER_SPY" "$TRACKER_SPY" "$WRITE_SPY"' EXIT
_GS_OUT='{}'; _GS_RC=0

# oc get snapshot <snap> -n ... -o jsonpath=... → a submariner-bundle image whose
# digest is keyed by snapshot name. snap-unrelated shares snap-stale's digest to
# model an intervening non-bundle push (new snapshot, bundle NOT rebuilt).
oc() {
  echo x >>"$CLUSTER_SPY"
  case "$3" in
    snap-rebuilt)   echo "quay.io/rh/submariner-bundle-0-99@sha256:aaaa1111" ;;
    snap-stale)     echo "quay.io/rh/submariner-bundle-0-99@sha256:bbbb2222" ;;
    snap-unrelated) echo "quay.io/rh/submariner-bundle-0-99@sha256:bbbb2222" ;;
    *) echo "" ;;   # unknown / garbage-collected snapshot → no image
  esac
}
get_step() { echo x >>"$TRACKER_SPY"; printf '%s' "$_GS_OUT"; return "$_GS_RC"; }
update_step() { echo x >>"$WRITE_SPY"; }   # the gate must NEVER call this

# Run the gate, capturing merged output (GATE_OUT) and exit code (GATE_RC). The
# gate's `exit 1` fires inside the command-substitution subshell; the `||` on the
# assignment catches its non-zero rc so the parent (under set -e) survives.
GATE_RC=0; GATE_OUT=""
run_gate() {
  : >"$CLUSTER_SPY"; : >"$TRACKER_SPY"
  GATE_RC=0
  GATE_OUT=$(assert_bundle_rebuilt 2>&1) || GATE_RC=$?
}

# Per-test defaults
VERSION="0.99.1"; RELEASE_TYPE="stage"; TRACKER="ACM-1"; SNAPSHOT_NAME="snap-rebuilt"

echo "=== _bundle_digest Tests ==="

assert_eq "digest extracted from image" "$(_bundle_digest snap-rebuilt submariner-bundle-0-99)" "sha256:aaaa1111"
assert_eq "digest empty for unknown snapshot" "$(_bundle_digest snap-gone submariner-bundle-0-99)" ""

echo ""
echo "=== assert_bundle_rebuilt Tests ==="

# 1: Rebuilt (chosen digest ≠ recorded) → pass.
_GS_OUT='{"data":{"snapshot":"snap-stale"}}'; _GS_RC=0
SNAPSHOT_NAME="snap-rebuilt"
run_gate
assert_eq       "rebuilt bundle → rc 0" "$GATE_RC" "0"
assert_contains "rebuilt bundle → freshness line" "$GATE_OUT" "Bundle freshness: submariner-bundle rebuilt"

# 2: Stale, same snapshot chosen and recorded → STOP.
_GS_OUT='{"data":{"snapshot":"snap-stale"}}'; _GS_RC=0
SNAPSHOT_NAME="snap-stale"
run_gate
assert_eq       "stale (same snapshot) → rc 1" "$GATE_RC" "1"
assert_contains "stale (same snapshot) → error" "$GATE_OUT" "Stale bundle"

# 3: Robustness — intervening UNRELATED snapshot (different name, same bundle
# digest, i.e. bundle NOT rebuilt) must still be caught, not false-pass.
_GS_OUT='{"data":{"snapshot":"snap-stale"}}'; _GS_RC=0
SNAPSHOT_NAME="snap-unrelated"
run_gate
assert_eq       "stale (unrelated newer snapshot) → rc 1" "$GATE_RC" "1"
assert_contains "stale (unrelated newer snapshot) → error" "$GATE_OUT" "Stale bundle"

# 4: Prod short-circuits BEFORE any cluster/tracker read (reuses stage snapshot).
_GS_OUT='{"data":{"snapshot":"snap-stale"}}'; _GS_RC=0
RELEASE_TYPE="prod"; SNAPSHOT_NAME="snap-stale"
run_gate
assert_eq "prod → rc 0"               "$GATE_RC" "0"
assert_eq "prod → no cluster read"    "$(wc -c <"$CLUSTER_SPY")" "0"
assert_eq "prod → no tracker read"    "$(wc -c <"$TRACKER_SPY")" "0"
RELEASE_TYPE="stage"

# 5: No tracker → fail open, no tracker read.
TRACKER=""; SNAPSHOT_NAME="snap-stale"
run_gate
assert_eq "no tracker → rc 0"            "$GATE_RC" "0"
assert_eq "no tracker → no tracker read" "$(wc -c <"$TRACKER_SPY")" "0"
TRACKER="ACM-1"

# 6: bundleShas recorded no snapshot (data {}) → fail open with skip notice.
_GS_OUT='{"data":{}}'; _GS_RC=0
SNAPSHOT_NAME="snap-rebuilt"
run_gate
assert_eq       "no recorded snapshot → rc 0" "$GATE_RC" "0"
assert_contains "no recorded snapshot → skip notice" "$GATE_OUT" "no bundleShas snapshot recorded"

# 7: Tracker READ failure (get_step non-zero) → fail open (never conflate a Jira
# blip with staleness).
_GS_OUT=''; _GS_RC=1
run_gate
assert_eq       "tracker read failure → rc 0 (fail open)" "$GATE_RC" "0"
assert_contains "tracker read failure → skip notice" "$GATE_OUT" "no bundleShas snapshot recorded"

# 8: Chosen snapshot's bundle digest unreadable (e.g. GC'd) → fail open.
_GS_OUT='{"data":{"snapshot":"snap-stale"}}'; _GS_RC=0
SNAPSHOT_NAME="snap-gone"
run_gate
assert_eq       "unreadable digest → rc 0 (fail open)" "$GATE_RC" "0"
assert_contains "unreadable digest → skip notice" "$GATE_OUT" "could not read submariner-bundle digest"

# 9: Read-only across every case above — the write sentinel stayed clean.
assert_eq "gate is strictly read-only (no update_step)" "$(wc -c <"$WRITE_SPY")" "0"

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
