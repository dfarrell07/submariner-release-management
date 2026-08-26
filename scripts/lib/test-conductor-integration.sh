#!/bin/bash
# Integration tests for run_conductor main loop
# Exercises the real dispatch loop with stubbed scripts and Jira calls.
# Run: ./scripts/lib/test-conductor-integration.sh
# shellcheck disable=SC2034  # globals set here are read by run_conductor across subshell boundary
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Must be true BEFORE sourcing so the main block in autorelease.sh is skipped.
export _AUTORELEASE_TESTING=true

# Source jira-tracker.sh for step-metadata constants
unset _JIRA_TRACKER_SOURCED
source "$SCRIPT_DIR/jira-tracker.sh" 2>/dev/null || true

# Stub external calls before sourcing autorelease.sh
query_jira() { echo "[]"; }
acli() { echo "[]"; }
# shellcheck disable=SC2034  # ACM_VERSION read by conductor library via subshell boundary
calculate_acm_version() { ACM_VERSION="ACM 2.17.0"; }

source "$SCRIPT_DIR/../autorelease.sh"

PASS=0 FAIL=0
assert_eq() {
  if [ "$2" = "$3" ]; then echo "  ✓ $1"; PASS=$((PASS + 1))
  else echo "  ✗ $1 (got: '$2', want: '$3')"; FAIL=$((FAIL + 1)); fi
}
assert_contains() {
  if printf '%s' "$2" | grep -qF -- "$3"; then echo "  ✓ $1"; PASS=$((PASS + 1))
  else echo "  ✗ $1 (expected '$3' in output)"; FAIL=$((FAIL + 1)); fi
}
assert_not_contains() {
  if ! printf '%s' "$2" | grep -qF -- "$3"; then echo "  ✓ $1"; PASS=$((PASS + 1))
  else echo "  ✗ $1 (unexpected '$3' in output)"; FAIL=$((FAIL + 1)); fi
}

# Helper: build acli-compatible comment JSON from "step:status" pairs.
# Produces a flat JSON array of {body: "...STEP_DATA..."} objects matching the
# format that _fetch_tracker_comments normalises before find_next_step parses it.
_build_it_comments() {
  local objs=() pair s st
  for pair in "$@"; do
    s="${pair%%:*}"; st="${pair#*:}"
    objs+=("$(jq -cn --arg s "$s" --arg st "$st" \
      '{body: ("---\n```STEP_DATA\n" + ({_t:"STEP_DATA",step:$s,status:$st,data:{}} | tojson) + "\n```")}')")
  done
  [ ${#objs[@]} -eq 0 ] && echo "[]" && return
  printf '%s\n' "${objs[@]}" | jq -s '.'
}

# Set up a tmpdir for stub scripts.  GIT_ROOT will point here so run_conductor
# resolves STEP_SCRIPT paths relative to this directory.
_IT_TMPDIR=$(mktemp -d)
# shellcheck disable=SC2064  # Intentional: expand _IT_TMPDIR now, not at trap time
trap "rm -rf '$_IT_TMPDIR'" EXIT
mkdir -p "$_IT_TMPDIR/scripts"

# Create a stub script that simply exits 0.
# Args: $1=relative path under _IT_TMPDIR (e.g. "scripts/foo.sh")
_make_exit0_stub() {
  local rel="$1"
  local full="$_IT_TMPDIR/$rel"
  mkdir -p "$(dirname "$full")"
  printf '#!/bin/bash\nexport _AUTORELEASE_TESTING=true\nexit 0\n' > "$full"
  chmod +x "$full"
}

# Create a stub script that appends its step name to $_IT_LOG then exits 0.
# Args: $1=relative path  $2=step name to log
_make_logging_stub() {
  local rel="$1" step="$2"
  local full="$_IT_TMPDIR/$rel"
  mkdir -p "$(dirname "$full")"
  # $_IT_LOG is exported so the subprocess can write to it.
  printf '#!/bin/bash\nexport _AUTORELEASE_TESTING=true\necho "%s" >> "$_IT_LOG"\nexit 0\n' \
    "$step" > "$full"
  chmod +x "$full"
}

# Create exit-0 stubs for every z-stream step that has a STEP_SCRIPT.
_make_all_zstream_stubs() {
  local step
  for step in "${STEP_ORDER[@]}"; do
    local p="${STEP_SCRIPT[$step]:-}"
    if [ -n "$p" ]; then _make_exit0_stub "$p"; fi
  done
}
_make_all_zstream_stubs

echo ""
echo "=== Conductor Integration Tests ==="

# ─────────────────────────────────────────────────────────────────────────────
# IT-1: review stop
# Setup: all z-stream steps complete up to bundleShas; componentStage not_started.
# Expect: conductor runs componentStage script (level=review), prints REVIEW, exits 0.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "IT-1: Review break (componentStage)"

_IT1_CMT=$(_build_it_comments \
  "rpmLockfiles:complete" "versionLabels:complete" "tektonTasks:complete" \
  "cveFixes:complete" "ecFixes:complete" \
  "upstreamRelease:complete" "bundleShas:complete")

_it1_rc=0
_it1_out=$(
  unset _AUTORELEASE_TESTING
  acli() { printf '%s' "$_IT1_CMT"; }
  tracker_is_open() { return 1; }
  try_auto_close() { return 1; }
  try_auto_verify() { return 1; }
  update_step() { :; }
  # shellcheck disable=SC2034  # read by run_conductor as globals; shellcheck can't trace subshell boundary
  VERSION="0.99.1" RELEASE_TYPE="z-stream" TRACKER="FAKE-123"
  GIT_ROOT="$_IT_TMPDIR"
  AUTORELEASE_PUSH_LOG=$(mktemp)
  export AUTORELEASE_PUSH_LOG
  ran_pr_step="" ran_release_yaml_step="" ran_direct_push_step=""
  declare -A step_statuses=() verified_steps=()
  _AUTORELEASE_QUIET=""
  run_conductor 2>&1
  rm -f "$AUTORELEASE_PUSH_LOG"
) || _it1_rc=$?

assert_contains "IT-1: output contains REVIEW" "$_it1_out" "REVIEW"
assert_not_contains "IT-1: no unknown-dispatch error" "$_it1_out" "Unknown dispatch"
assert_eq "IT-1: conductor exits 0 at review stop" "$_it1_rc" "0"

# ─────────────────────────────────────────────────────────────────────────────
# IT-2: review stop on first ready step
# Setup: all statuses empty (acli returns []); rpmLockfiles is the first z-stream
# step and is review level → conductor runs its script, prints REVIEW, and breaks.
# Note: the same-step guard can't fire for review steps — they always break
# immediately after running rather than looping (so there's no second iteration
# to compare NEXT_STEP against prev_step). The guard is exercised only for auto
# steps that exit 0 without self-marking complete (not currently in the test suite).
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "IT-2: Review stop on first ready step (rpmLockfiles)"

_it2_rc=0
_it2_out=$(
  unset _AUTORELEASE_TESTING
  acli() { echo "[]"; }
  tracker_is_open() { return 1; }
  try_auto_close() { return 1; }
  try_auto_verify() { return 1; }
  update_step() { :; }
  # shellcheck disable=SC2034  # read by run_conductor as globals; shellcheck can't trace subshell boundary
  VERSION="0.99.1" RELEASE_TYPE="z-stream" TRACKER="FAKE-123"
  GIT_ROOT="$_IT_TMPDIR"
  AUTORELEASE_PUSH_LOG=$(mktemp)
  export AUTORELEASE_PUSH_LOG
  ran_pr_step="" ran_release_yaml_step="" ran_direct_push_step=""
  declare -A step_statuses=() verified_steps=()
  _AUTORELEASE_QUIET=""
  run_conductor 2>&1
  rm -f "$AUTORELEASE_PUSH_LOG"
) || _it2_rc=$?

assert_contains "IT-2: review stop message" "$_it2_out" "REVIEW"
assert_contains "IT-2: suggests re-run" "$_it2_out" "/autorelease"
assert_eq "IT-2: conductor exits 0 on review stop" "$_it2_rc" "0"

# ─────────────────────────────────────────────────────────────────────────────
# IT-3: gate stop
# Setup: all Build Readiness steps complete; upstreamRelease not_started.
# upstreamRelease is gate; try_auto_verify returns 1 (not verified).
# Expect: output contains "GATE", conductor exits 0.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "IT-3: Gate stop (upstreamRelease)"

_IT3_CMT=$(_build_it_comments \
  "rpmLockfiles:complete" "versionLabels:complete" "tektonTasks:complete" \
  "cveFixes:complete" "ecFixes:complete")

_it3_rc=0
_it3_out=$(
  unset _AUTORELEASE_TESTING
  acli() { printf '%s' "$_IT3_CMT"; }
  tracker_is_open() { return 1; }
  try_auto_close() { return 1; }
  try_auto_verify() { return 1; }
  update_step() { :; }
  # shellcheck disable=SC2034  # read by run_conductor as globals; shellcheck can't trace subshell boundary
  VERSION="0.99.1" RELEASE_TYPE="z-stream" TRACKER="FAKE-123"
  GIT_ROOT="$_IT_TMPDIR"
  AUTORELEASE_PUSH_LOG=$(mktemp)
  export AUTORELEASE_PUSH_LOG
  ran_pr_step="" ran_release_yaml_step="" ran_direct_push_step=""
  declare -A step_statuses=() verified_steps=()
  _AUTORELEASE_QUIET=""
  run_conductor 2>&1
  rm -f "$AUTORELEASE_PUSH_LOG"
) || _it3_rc=$?

assert_contains "IT-3: output contains GATE" "$_it3_out" "GATE"
assert_contains "IT-3: output names the gated step" "$_it3_out" "upstreamRelease"
assert_eq "IT-3: conductor exits 0 on gate" "$_it3_rc" "0"

# ─────────────────────────────────────────────────────────────────────────────
# IT-4: review step runs and breaks — subsequent steps not reached in same run
# Setup: cveFixes, tektonTasks, ecFixes already complete; rpmLockfiles not_started.
# rpmLockfiles is review level → conductor runs it, prints REVIEW, breaks.
# versionLabels is NOT reached in the same conductor invocation.
# Note: rpmLockfiles and versionLabels are both review steps (not auto), so
# there is no multi-step auto-chain between them — each requires a fresh run.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "IT-4: Review step runs, subsequent review step not reached (rpmLockfiles)"

_IT_LOG=$(mktemp); export _IT_LOG
_make_logging_stub "scripts/rpm-lockfile-update.sh" "rpmLockfiles"
_make_logging_stub "scripts/update-version-labels.sh" "versionLabels"

_it4_rc=0
_it4_out=$(
  unset _AUTORELEASE_TESTING
  acli() {
    local pairs=("cveFixes:complete" "tektonTasks:complete" "ecFixes:complete")
    local step
    while IFS= read -r step; do
      [ -n "$step" ] && pairs+=("${step}:complete")
    done < "$_IT_LOG"
    _build_it_comments "${pairs[@]}"
  }
  tracker_is_open() { return 1; }
  try_auto_close() { return 1; }
  try_auto_verify() { return 1; }
  update_step() { :; }
  # shellcheck disable=SC2034  # read by run_conductor as globals; shellcheck can't trace subshell boundary
  VERSION="0.99.1" RELEASE_TYPE="z-stream" TRACKER="FAKE-123"
  GIT_ROOT="$_IT_TMPDIR"
  AUTORELEASE_PUSH_LOG=$(mktemp)
  export AUTORELEASE_PUSH_LOG
  ran_pr_step="" ran_release_yaml_step="" ran_direct_push_step=""
  declare -A step_statuses=() verified_steps=()
  _AUTORELEASE_QUIET=""
  run_conductor 2>&1
  rm -f "$AUTORELEASE_PUSH_LOG"
) || _it4_rc=$?

_it4_ran=$(cat "$_IT_LOG" 2>/dev/null || echo "")
rm -f "$_IT_LOG"

assert_contains "IT-4: rpmLockfiles ran" "$_it4_ran" "rpmLockfiles"
assert_not_contains "IT-4: versionLabels not reached (review break)" "$_it4_ran" "versionLabels"
assert_eq "IT-4: conductor exits 0 after review stop" "$_it4_rc" "0"

# ─────────────────────────────────────────────────────────────────────────────
# IT-5: gate step without verifier shows --complete instruction
# Setup: all steps complete through fbcStageReleases; qeValidation not_started.
# qeValidation is gate but has no STEP_VERIFIER entry → conductor falls to the
# no-verifier branch which tells the operator: /autorelease VERSION --complete STEP.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "IT-5: Gate without verifier shows --complete (qeValidation)"

_IT5_CMT=$(_build_it_comments \
  "rpmLockfiles:complete" "versionLabels:complete" "tektonTasks:complete" \
  "cveFixes:complete" "ecFixes:complete" \
  "upstreamRelease:complete" "bundleShas:complete" \
  "componentStage:complete" "releaseNotes:complete" \
  "fbcCatalogUpdate:complete" "fbcStageReleases:complete")

_it5_rc=0
_it5_out=$(
  unset _AUTORELEASE_TESTING
  acli() { printf '%s' "$_IT5_CMT"; }
  tracker_is_open() { return 1; }
  try_auto_close() { return 1; }
  try_auto_verify() { return 1; }
  update_step() { :; }
  # shellcheck disable=SC2034  # read by run_conductor as globals; shellcheck can't trace subshell boundary
  VERSION="0.99.1" RELEASE_TYPE="z-stream" TRACKER="FAKE-123"
  GIT_ROOT="$_IT_TMPDIR"
  AUTORELEASE_PUSH_LOG=$(mktemp)
  export AUTORELEASE_PUSH_LOG
  ran_pr_step="" ran_release_yaml_step="" ran_direct_push_step=""
  declare -A step_statuses=() verified_steps=()
  _AUTORELEASE_QUIET=""
  run_conductor 2>&1
  rm -f "$AUTORELEASE_PUSH_LOG"
) || _it5_rc=$?

assert_contains "IT-5: --complete in output" "$_it5_out" "--complete"
assert_contains "IT-5: qeValidation step named" "$_it5_out" "qeValidation"
assert_eq "IT-5: conductor exits 0 at gate without verifier" "$_it5_rc" "0"

# ─────────────────────────────────────────────────────────────────────────────
# IT-6: --complete with unknown step key is rejected
# The STEP_ORDER validation in the main block cannot be tested with
# _AUTORELEASE_TESTING=true (it lives inside the guard), but handle_step_override
# has its own STEP_TITLES membership check which rejects unknown keys. Test that
# directly — it is the same safety gate the main-block validation exposes.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "IT-6: --complete unknown step rejected by handle_step_override"

_it6_rc=0
_it6_err=""
_orig_update_step_it6=$(declare -f update_step)
update_step() { :; }
_it6_err=$(handle_step_override "0.99.1" "unknownStep" "complete" "FAKE-123" 2>&1) || _it6_rc=$?
eval "$_orig_update_step_it6"

assert_eq "IT-6: unknown step rejected (exit 1)" "$_it6_rc" "1"
assert_contains "IT-6: error message mentions step" "$_it6_err" "unknownStep"

# NOTE: The STEP_ORDER guard at autorelease.sh ~lines 1453-1469 (fast-fail for
# unknown --complete/--refresh keys) runs AFTER _resolve_version, which requires
# Jira. It cannot be tested via subprocess without real Jira auth. IT-6 covers
# handle_step_override (same rejection, same exit code) via the unit-test path.
# The guard is correct; this gap is accepted as a known limitation.

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ "$FAIL" -eq 0 ]; then echo "All $PASS tests passed"
else echo "$FAIL FAILED, $PASS passed"; fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
[ "$FAIL" -eq 0 ] || exit 1
