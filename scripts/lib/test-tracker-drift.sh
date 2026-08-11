#!/bin/bash
# Tests for tracker-drift.sh.
# Run: ./scripts/lib/test-tracker-drift.sh
#
# The lib is a standalone set of pure functions (no top-level side effects), so
# sourcing it runs nothing. ground_truth_done reads globals this test sets
# directly; classify_drift is pure; print_tracker_drift is exercised against
# crafted get_release_summary JSON blobs. No cluster/network needed.
# shellcheck disable=SC2034  # ground-truth globals are read by the sourced lib
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/tracker-drift.sh"

PASS=0 FAIL=0
assert_eq() {
  if [ "$2" = "$3" ]; then echo "  ✓ $1"; PASS=$((PASS + 1))
  else echo "  ✗ $1 (got: '$2', want: '$3')"; FAIL=$((FAIL + 1)); fi
}

# Reset all ground-truth globals to a neutral baseline before each case.
reset_globals() {
  IS_ZSTREAM=false; BRANCH_CHECK=""; MISSING_TEKTON=0
  WRONG_COUNT=0; FETCH_FAILED=0; TAG_EXISTS=""
  BRANCH_FETCH_FAILED=0; TEKTON_FETCH_FAILED=0; TAG_FETCH_FAILED=0
}

echo "=== ground_truth_done Tests ==="

# createBranches: Y-stream signal from BRANCH_CHECK; unknown on Z-stream.
reset_globals; BRANCH_CHECK="all"
assert_eq "createBranches: all branches -> done"   "$(ground_truth_done createBranches)" "done"
reset_globals; BRANCH_CHECK=""
assert_eq "createBranches: missing -> not-done"    "$(ground_truth_done createBranches)" "not-done"
reset_globals; IS_ZSTREAM=true; BRANCH_CHECK="all"
assert_eq "createBranches: Z-stream -> unknown"    "$(ground_truth_done createBranches)" "unknown"

# tektonComponents: Y-stream signal from MISSING_TEKTON; unknown on Z-stream.
reset_globals; MISSING_TEKTON=0
assert_eq "tektonComponents: none missing -> done" "$(ground_truth_done tektonComponents)" "done"
reset_globals; MISSING_TEKTON=2
assert_eq "tektonComponents: missing -> not-done"  "$(ground_truth_done tektonComponents)" "not-done"
reset_globals; IS_ZSTREAM=true
assert_eq "tektonComponents: Z-stream -> unknown"  "$(ground_truth_done tektonComponents)" "unknown"

# versionLabels: Z-stream only; FETCH_FAILED makes it inconclusive (unknown).
reset_globals; IS_ZSTREAM=true; WRONG_COUNT=0; FETCH_FAILED=0
assert_eq "versionLabels: all correct -> done"     "$(ground_truth_done versionLabels)" "done"
reset_globals; IS_ZSTREAM=true; WRONG_COUNT=3
assert_eq "versionLabels: wrong -> not-done"       "$(ground_truth_done versionLabels)" "not-done"
reset_globals; IS_ZSTREAM=true; FETCH_FAILED=1
assert_eq "versionLabels: fetch failed -> unknown" "$(ground_truth_done versionLabels)" "unknown"
reset_globals; IS_ZSTREAM=false; WRONG_COUNT=0
assert_eq "versionLabels: Y-stream -> unknown"     "$(ground_truth_done versionLabels)" "unknown"
# WRONG_COUNT takes priority over FETCH_FAILED: proven-incomplete beats inconclusive.
reset_globals; IS_ZSTREAM=true; WRONG_COUNT=3; FETCH_FAILED=2
assert_eq "versionLabels: wrong + fetch-failed -> not-done" \
  "$(ground_truth_done versionLabels)" "not-done"

# upstreamRelease: both streams, from TAG_EXISTS.
reset_globals; TAG_EXISTS="v0.23.1"
assert_eq "upstreamRelease: tag exists -> done"    "$(ground_truth_done upstreamRelease)" "done"
reset_globals; TAG_EXISTS=""
assert_eq "upstreamRelease: no tag -> not-done"    "$(ground_truth_done upstreamRelease)" "not-done"

# Probe-failure guards: an unreachable GitHub must read as "unknown", NOT
# "not-done" (otherwise a completed+tracked step would draw a false drift warning).
reset_globals; BRANCH_FETCH_FAILED=1; BRANCH_CHECK=""
assert_eq "createBranches: fetch failed -> unknown" "$(ground_truth_done createBranches)" "unknown"
reset_globals; TEKTON_FETCH_FAILED=1; MISSING_TEKTON=5
assert_eq "tektonComponents: fetch failed -> unknown" "$(ground_truth_done tektonComponents)" "unknown"
reset_globals; TAG_FETCH_FAILED=1; TAG_EXISTS=""
assert_eq "upstreamRelease: fetch failed -> unknown"  "$(ground_truth_done upstreamRelease)" "unknown"

# Unknown / uncovered key.
assert_eq "uncovered key -> unknown"               "$(ground_truth_done componentProd)" "unknown"

echo ""
echo "=== classify_drift Tests ==="
assert_eq "complete + not-done -> tracker-ahead"   "$(classify_drift true not-done)"    "tracker-ahead"
assert_eq "complete + done -> ok"                  "$(classify_drift true "done")"      "ok"
assert_eq "incomplete + done -> reality-ahead"     "$(classify_drift false "done")"     "reality-ahead"
assert_eq "incomplete + not-done -> ok"            "$(classify_drift false not-done)"   "ok"
assert_eq "complete + unknown -> skip"             "$(classify_drift true unknown)"   "skip"
assert_eq "incomplete + unknown -> skip"           "$(classify_drift false unknown)"  "skip"

echo ""
echo "=== print_tracker_drift Tests ==="

# Helper: build a summary JSON with one step key at a given jiraStatus/title.
summary_with() {
  local key="$1" status="$2"
  jq -cn --arg k "$key" --arg s "$status" \
    '{steps: {($k): {title: $k, jiraStatus: $s}}}'
}

# Helper: build a summary JSON with two step keys.
summary_with2() {
  local k1="$1" s1="$2" k2="$3" s2="$4"
  jq -cn --arg k1 "$k1" --arg s1 "$s1" --arg k2 "$k2" --arg s2 "$s2" \
    '{steps: {($k1): {title: $k1, jiraStatus: $s1}, ($k2): {title: $k2, jiraStatus: $s2}}}'
}

# Tracker-ahead: tracker Resolved but ground truth says the tag is gone.
reset_globals; TAG_EXISTS=""
out=$(print_tracker_drift "$(summary_with upstreamRelease Resolved)") && rc=0 || rc=$?
assert_eq "tracker-ahead: returns 0 (drift found)" "$rc" "0"
assert_eq "tracker-ahead: warns marked-complete" \
  "$(echo "$out" | grep -c 'marked complete but ground truth')" "1"

# Reality-ahead: tag exists but tracker not marked complete.
reset_globals; TAG_EXISTS="v0.23.1"
out=$(print_tracker_drift "$(summary_with upstreamRelease 'In Progress')") && rc=0 || rc=$?
assert_eq "reality-ahead: returns 0 (drift found)" "$rc" "0"
assert_eq "reality-ahead: notes not-marked-complete" \
  "$(echo "$out" | grep -c 'done on ground truth but not marked')" "1"

# Agreement: tag exists and tracker Resolved -> no drift, returns 1, no output.
reset_globals; TAG_EXISTS="v0.23.1"
out=$(print_tracker_drift "$(summary_with upstreamRelease Resolved)") && rc=0 || rc=$?
assert_eq "agreement: returns 1 (no drift)"        "$rc" "1"
assert_eq "agreement: prints nothing"              "$out" ""

# Unknown ground truth (Z-stream createBranches) -> skipped, no drift claimed.
reset_globals; IS_ZSTREAM=true
out=$(print_tracker_drift "$(summary_with createBranches Resolved)") && rc=0 || rc=$?
assert_eq "unknown gt: returns 1 (skipped)"        "$rc" "1"

# Regression guard: tracker Resolved + probe UNREACHABLE (not proven absent) must
# NOT warn. Before the *_FETCH_FAILED guards this printed a false "tracker-ahead".
reset_globals; TAG_FETCH_FAILED=1; TAG_EXISTS=""
out=$(print_tracker_drift "$(summary_with upstreamRelease Resolved)") && rc=0 || rc=$?
assert_eq "probe unreachable: returns 1 (no false warning)" "$rc" "1"
assert_eq "probe unreachable: prints nothing"      "$out" ""

# Multi-step tracker-ahead: both Resolved but ground truth says neither done.
# Exercises the ahead+= append; a mutation to = (overwrite) would drop one entry.
reset_globals; IS_ZSTREAM=true; WRONG_COUNT=3; TAG_EXISTS=""
out=$(print_tracker_drift "$(summary_with2 upstreamRelease Resolved versionLabels Resolved)") && rc=0 || rc=$?
assert_eq "multi tracker-ahead: returns 0"             "$rc" "0"
assert_eq "multi tracker-ahead: lists upstreamRelease" \
  "$(echo "$out" | grep -c 'upstreamRelease')" "1"
assert_eq "multi tracker-ahead: lists versionLabels" \
  "$(echo "$out" | grep -c 'versionLabels')" "1"

# Multi-step reality-ahead: both done on ground truth but not in tracker.
# Exercises the behind+= append symmetrically.
reset_globals; IS_ZSTREAM=true; WRONG_COUNT=0; TAG_EXISTS="v0.23.1"
out=$(print_tracker_drift "$(summary_with2 upstreamRelease 'In Progress' versionLabels 'In Progress')") && rc=0 || rc=$?
assert_eq "multi reality-ahead: returns 0"             "$rc" "0"
assert_eq "multi reality-ahead: lists upstreamRelease" \
  "$(echo "$out" | grep -c 'upstreamRelease')" "1"
assert_eq "multi reality-ahead: lists versionLabels" \
  "$(echo "$out" | grep -c 'versionLabels')" "1"

# Empty / absent summary -> returns 1, no output.
out=$(print_tracker_drift "{}") && rc=0 || rc=$?
assert_eq "empty summary: returns 1"               "$rc" "1"
out=$(print_tracker_drift "") && rc=0 || rc=$?
assert_eq "blank summary: returns 1"               "$rc" "1"

# Step not tracked for this release (absent key) -> skipped.
reset_globals; TAG_EXISTS=""
out=$(print_tracker_drift "$(summary_with someOtherStep Resolved)") && rc=0 || rc=$?
assert_eq "untracked step: returns 1 (no drift)"   "$rc" "1"

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
