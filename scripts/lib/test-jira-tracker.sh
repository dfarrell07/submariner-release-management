#!/bin/bash
# Tests for scripts/lib/jira-tracker.sh
# Run: make test-tracker
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source library (once — readonly arrays crash on re-source)
unset _JIRA_TRACKER_SOURCED
source "$SCRIPT_DIR/jira-tracker.sh"

# Stub external calls
query_jira() { echo "[]"; }
acli() { :; }
# shellcheck disable=SC2034  # ACM_VERSION used by library after mock returns
calculate_acm_version() { ACM_VERSION="ACM 2.17.0"; }

# Assertion helpers
PASS=0 FAIL=0
assert_eq() {
  if [ "$2" = "$3" ]; then echo "  ✓ $1"; PASS=$((PASS + 1))
  else echo "  ✗ $1 (got: '$2', want: '$3')"; FAIL=$((FAIL + 1)); fi
}
# ============================================================================
echo "=== 1. Input Validation ==="
# ============================================================================

# _normalize_version
assert_eq "normalize 2-seg" "$(_normalize_version "0.24")" "0.24.0"
assert_eq "normalize 3-seg unchanged" "$(_normalize_version "0.24.1")" "0.24.1"
assert_eq "normalize empty" "$(_normalize_version "")" ""

# Valid versions
_validate_version "0.24.0" 2>/dev/null && rc=0 || rc=$?
assert_eq "0.24.0 valid" "$rc" "0"

_validate_version "0.0.0" 2>/dev/null && rc=0 || rc=$?
assert_eq "0.0.0 valid" "$rc" "0"

# Invalid versions
_validate_version "0.24" 2>/dev/null && rc=0 || rc=$?
assert_eq "0.24 rejected (2-segment)" "$rc" "1"

_validate_version "" 2>/dev/null && rc=0 || rc=$?
assert_eq "empty rejected" "$rc" "1"

_validate_version "v0.24.0" 2>/dev/null && rc=0 || rc=$?
assert_eq "v-prefix rejected" "$rc" "1"

_validate_version "0.24.0-rc1" 2>/dev/null && rc=0 || rc=$?
assert_eq "suffix rejected" "$rc" "1"

_validate_version "0.24.0.1" 2>/dev/null && rc=0 || rc=$?
assert_eq "4-segment rejected" "$rc" "1"

# ============================================================================
echo ""
echo "=== 2. Constants ==="
# ============================================================================

assert_eq "STEP_ORDER has 19 entries" "${#STEP_ORDER[@]}" "19"
assert_eq "YSTREAM_STEPS has 4 entries" "${#YSTREAM_STEPS[@]}" "4"

# Every STEP_ORDER key in STEP_TITLES and STEP_PHASE
missing_titles=0 missing_phases=0
for key in "${STEP_ORDER[@]}"; do
  [ -z "${STEP_TITLES[$key]:-}" ] && missing_titles=$((missing_titles + 1))
  [ -z "${STEP_PHASE[$key]:-}" ] && missing_phases=$((missing_phases + 1))
done
assert_eq "all STEP_ORDER keys in STEP_TITLES" "$missing_titles" "0"
assert_eq "all STEP_ORDER keys in STEP_PHASE" "$missing_phases" "0"

# YSTREAM_STEPS subset of STEP_ORDER
ys_missing=0
for ys in "${YSTREAM_STEPS[@]}"; do
  found=false
  for key in "${STEP_ORDER[@]}"; do [ "$key" = "$ys" ] && found=true && break; done
  [ "$found" = "false" ] && ys_missing=$((ys_missing + 1))
done
assert_eq "YSTREAM_STEPS subset of STEP_ORDER" "$ys_missing" "0"

# Dependency values reference valid step keys
dep_invalid=0
for step in "${!STEP_DEPENDENCIES[@]}"; do
  deps="${STEP_DEPENDENCIES[$step]:-}"
  [ -z "$deps" ] && continue
  IFS="," read -ra dep_arr <<< "$deps"
  for dep in "${dep_arr[@]}"; do
    found=false
    for sk in "${STEP_ORDER[@]}"; do [ "$sk" = "$dep" ] && found=true && break; done
    [ "$found" = "false" ] && dep_invalid=$((dep_invalid + 1))
  done
done
assert_eq "dependency values are valid step keys" "$dep_invalid" "0"

# AUTOMATION_LEVEL values
al_invalid=0
for step in "${STEP_ORDER[@]}"; do
  level="${AUTOMATION_LEVEL[$step]:-}"
  case "$level" in auto|review|gate) ;; *) al_invalid=$((al_invalid + 1)) ;; esac
done
assert_eq "AUTOMATION_LEVEL values valid" "$al_invalid" "0"

# ============================================================================
echo ""
echo "=== 2b. Conductor Constants ==="
# ============================================================================

# ZSTREAM_STEPS count
assert_eq "ZSTREAM_STEPS has 1 entry" "${#ZSTREAM_STEPS[@]}" "1"

# DAG fix: versionLabels in upstreamRelease deps
deps="${STEP_DEPENDENCIES[upstreamRelease]:-}"
echo "$deps" | grep -qF "versionLabels" && vl_in_deps="yes" || vl_in_deps="no"
assert_eq "versionLabels in upstreamRelease deps" "$vl_in_deps" "yes"

# DAG fix: cveFixes is review (not auto)
assert_eq "cveFixes automation is review" "${AUTOMATION_LEVEL[cveFixes]:-}" "review"

# DAG fix: releaseNotes depends on componentStage (notes modify existing YAML)
deps="${STEP_DEPENDENCIES[releaseNotes]:-}"
echo "$deps" | grep -qF "componentStage" && cs_in_deps="yes" || cs_in_deps="no"
assert_eq "componentStage in releaseNotes deps" "$cs_in_deps" "yes"

# STEP_SCRIPT keys are valid STEP_ORDER entries
script_invalid=0
for key in "${!STEP_SCRIPT[@]}"; do
  found=false
  for sk in "${STEP_ORDER[@]}"; do [ "$sk" = "$key" ] && found=true && break; done
  [ "$found" = "false" ] && script_invalid=$((script_invalid + 1))
done
assert_eq "STEP_SCRIPT keys valid" "$script_invalid" "0"

# STEP_EXTRA_ARGS keys exist in STEP_SCRIPT
args_invalid=0
for key in "${!STEP_EXTRA_ARGS[@]}"; do
  [ -z "${STEP_SCRIPT[$key]:-}" ] && args_invalid=$((args_invalid + 1))
done
assert_eq "STEP_EXTRA_ARGS keys in STEP_SCRIPT" "$args_invalid" "0"

# step_applies_to_release
step_applies_to_release "cveFixes" "z-stream" && r1="yes" || r1="no"
assert_eq "cveFixes applies to z-stream" "$r1" "yes"
step_applies_to_release "createBranches" "z-stream" && r2="yes" || r2="no"
assert_eq "createBranches skipped for z-stream" "$r2" "no"
step_applies_to_release "versionLabels" "y-stream" && r3="yes" || r3="no"
assert_eq "versionLabels skipped for y-stream" "$r3" "no"
step_applies_to_release "versionLabels" "z-stream" && r4="yes" || r4="no"
assert_eq "versionLabels applies to z-stream" "$r4" "yes"

# ============================================================================
echo ""
echo "=== 3. Subtask Counts ==="
# ============================================================================

export JIRA_TRACKER_DRY_RUN=true
export _JIRA_STALE_RETRY_DELAY=0  # no sleep in tests
query_jira() { echo "[]"; }
# shellcheck disable=SC2034  # ACM_VERSION used by library after mock returns
calculate_acm_version() { ACM_VERSION="ACM 2.17.0"; }

# Y-stream: 18 subtasks (versionLabels is Z-stream-only)
output=$(create_release_tracker "0.24.0" 2>&1 >/dev/null)
count=$(printf '%s' "$output" | grep -c "Would create: Sub-task" || true)
assert_eq "y-stream: 18 subtasks" "$count" "18"

# Z-stream: 15 subtasks
output=$(create_release_tracker "0.24.1" 2>&1 >/dev/null)
count=$(printf '%s' "$output" | grep -c "Would create: Sub-task" || true)
assert_eq "z-stream: 15 subtasks" "$count" "15"

# Idempotent: existing tracker returns key, no subtasks
query_jira() { echo '[{"key":"ACM-EXISTING"}]'; }
key=$(create_release_tracker "0.24.0" 2>/dev/null)
assert_eq "idempotent: returns existing key" "$key" "ACM-EXISTING"

# Idempotency check can't reach Jira (query fails → find_release_tracker rc 2):
# refuse rather than create a possible duplicate.
query_jira() { return 1; }
rc=0
out=$(create_release_tracker "0.24.0" 2>&1) || rc=$?
assert_eq "query failure → refuse (rc 1)" "$rc" "1"
created=$(printf '%s' "$out" | grep -c "Would create" || true)
assert_eq "query failure → no tracker created" "$created" "0"

# Stale-index retry: initial query empty (stale), retry finds existing tracker.
# Verifies no duplicate creation when the index clears between initial and retry.
# Uses a temp file counter because query_jira runs in subshells of find_release_tracker,
# so an in-memory counter would reset each call (subshells don't update parent vars).
_stale_ctr=$(mktemp)
printf '0' > "$_stale_ctr"
query_jira() {
  _n=$(cat "$_stale_ctr"); _n=$((_n + 1)); printf '%s' "$_n" > "$_stale_ctr"
  [ "$_n" -le 1 ] && { echo "[]"; return 0; }
  echo '[{"key":"ACM-RETRY"}]'
}
key=$(create_release_tracker "0.24.0" 2>/dev/null)
assert_eq "stale-index retry: found on retry -> returns key" "$key" "ACM-RETRY"
rm -f "$_stale_ctr"

unset JIRA_TRACKER_DRY_RUN _JIRA_STALE_RETRY_DELAY
query_jira() { echo "[]"; }

# ============================================================================
echo ""
echo "=== 4. check_freshness ==="
# ============================================================================

# Save original get_step before overriding
_SAVED_GET_STEP=$(declare -f get_step)

# No staleness rule
result=$(check_freshness "0.24.0" "createBranches" "ACM-99" 2>/dev/null)
assert_eq "no rule: fresh" "$result" "fresh"

# Time-based: 1 day ago, 3-day rule → fresh
get_step() {
  local ts
  ts=$(date -u -d "1 day ago" +"%Y-%m-%dT%H:%M:%SZ")
  printf '%s' "{\"_t\":\"STEP_DATA\",\"step\":\"cveFixes\",\"timestamp\":\"$ts\",\"status\":\"complete\",\"data\":{}}"
}
result=$(check_freshness "0.24.0" "cveFixes" "ACM-99" 2>/dev/null)
assert_eq "1d ago, 3d rule: fresh" "$result" "fresh"

# Time-based: 5 days ago, 3-day rule → stale
get_step() {
  local ts
  ts=$(date -u -d "5 days ago" +"%Y-%m-%dT%H:%M:%SZ")
  printf '%s' "{\"_t\":\"STEP_DATA\",\"step\":\"cveFixes\",\"timestamp\":\"$ts\",\"status\":\"complete\",\"data\":{}}"
}
result=$(check_freshness "0.24.0" "cveFixes" "ACM-99" 2>/dev/null)
assert_eq "5d ago, 3d rule: stale" "$result" "stale"

# Status in_progress → fresh
get_step() {
  printf '%s' '{"_t":"STEP_DATA","step":"cveFixes","timestamp":"2026-01-01T00:00:00Z","status":"in_progress","data":{}}'
}
result=$(check_freshness "0.24.0" "cveFixes" "ACM-99" 2>/dev/null)
assert_eq "in_progress: fresh" "$result" "fresh"

# Snapshot: same → fresh
get_step() {
  case "$2" in
    ecFixes)    printf '%s' '{"_t":"STEP_DATA","step":"ecFixes","timestamp":"2026-07-01T00:00:00Z","status":"complete","data":{"snapshot":"snap-abc"}}' ;;
    bundleShas) printf '%s' '{"_t":"STEP_DATA","step":"bundleShas","timestamp":"2026-07-01T00:00:00Z","status":"complete","data":{"snapshot":"snap-abc"}}' ;;
  esac
}
result=$(check_freshness "0.24.0" "ecFixes" "ACM-99" 2>/dev/null)
assert_eq "same snapshot: fresh" "$result" "fresh"

# Snapshot: different → stale
get_step() {
  case "$2" in
    ecFixes)    printf '%s' '{"_t":"STEP_DATA","step":"ecFixes","timestamp":"2026-07-01T00:00:00Z","status":"complete","data":{"snapshot":"snap-old"}}' ;;
    bundleShas) printf '%s' '{"_t":"STEP_DATA","step":"bundleShas","timestamp":"2026-07-01T00:00:00Z","status":"complete","data":{"snapshot":"snap-new"}}' ;;
  esac
}
result=$(check_freshness "0.24.0" "ecFixes" "ACM-99" 2>/dev/null)
assert_eq "different snapshot: stale" "$result" "stale"

# Snapshot: missing → fresh
get_step() {
  printf '%s' '{"_t":"STEP_DATA","step":"ecFixes","timestamp":"2026-07-01T00:00:00Z","status":"complete","data":{}}'
}
result=$(check_freshness "0.24.0" "ecFixes" "ACM-99" 2>/dev/null)
assert_eq "no snapshot field: fresh" "$result" "fresh"

# Snapshot: step has one but bundleShas has none → fresh (nothing to compare
# against). Guards the `[ -n "$latest_snapshot" ]` conjunct at check_freshness's
# snapshot arm; without it, an absent bundleShas snapshot spuriously flags every
# downstream step as stale.
get_step() {
  case "$2" in
    ecFixes)    printf '%s' '{"_t":"STEP_DATA","step":"ecFixes","timestamp":"2026-07-01T00:00:00Z","status":"complete","data":{"snapshot":"snap-abc"}}' ;;
    bundleShas) printf '%s' '{"_t":"STEP_DATA","step":"bundleShas","timestamp":"2026-07-01T00:00:00Z","status":"complete","data":{}}' ;;
  esac
}
result=$(check_freshness "0.24.0" "ecFixes" "ACM-99" 2>/dev/null)
assert_eq "step snapshot but no bundleShas snapshot: fresh" "$result" "fresh"

# Snapshot: get_step(bundleShas) fails (rc!=0) → stale (fail-closed)
get_step() {
  case "$2" in
    ecFixes)    printf '%s' '{"_t":"STEP_DATA","step":"ecFixes","timestamp":"2026-07-01T00:00:00Z","status":"complete","data":{"snapshot":"snap-abc"}}' ;;
    bundleShas) return 2 ;;
  esac
}
result=$(check_freshness "0.24.0" "ecFixes" "ACM-99" 2>/dev/null)
assert_eq "bundleShas get_step failure → stale (fail-closed)" "$result" "stale"

# Restore original get_step (saved before section 4 overrides)
eval "$_SAVED_GET_STEP"

# ============================================================================
echo ""
echo "=== 5. get_step Parser ==="
# ============================================================================

# Save original find_release_tracker before overriding
_SAVED_FIND_RELEASE_TRACKER=$(declare -f find_release_tracker)

# Mock acli comment list with hardcoded fixtures. Real acli (1.3.x) returns a
# {"comments":[...]} OBJECT (not a bare array), so the fixture uses that shape to
# exercise _fetch_tracker_comments' normalization on the real contract.
acli() {
  if [[ "${*}" == *"comment list"* ]]; then
    cat <<'MOCK'
{
  "comments": [
    {"body": "Just a comment"},
    {"body": "## CVE fixes\n\n---\n```STEP_DATA\n{\"_t\":\"STEP_DATA\",\"step\":\"cveFixes\",\"timestamp\":\"2026-07-01T10:00:00Z\",\"status\":\"complete\",\"data\":{}}\n```"},
    {"body": "## Bundle SHAs\n\n---\n```STEP_DATA\n{\"_t\":\"STEP_DATA\",\"step\":\"bundleShas\",\"timestamp\":\"2026-07-02T10:00:00Z\",\"status\":\"complete\",\"data\":{\"snapshot\":\"snap-123\"}}\n```"},
    {"body": "## CVE fixes attempt 2\n\n---\n```STEP_DATA\n{\"_t\":\"STEP_DATA\",\"step\":\"cveFixes\",\"timestamp\":\"2026-07-05T10:00:00Z\",\"status\":\"complete\",\"data\":{\"attempt\":2}}\n```"}
  ]
}
MOCK
  fi
}
find_release_tracker() { printf '%s' "ACM-99"; }

# Standard extraction
result=$(get_step "0.24.0" "cveFixes" "ACM-99")
ts=$(printf '%s' "$result" | jq -r '.timestamp' 2>/dev/null)
assert_eq "cveFixes: latest timestamp" "$ts" "2026-07-05T10:00:00Z"

# Different step filter
snap=$(printf '%s' "$(get_step "0.24.0" "bundleShas" "ACM-99")" | jq -r '.data.snapshot' 2>/dev/null)
assert_eq "bundleShas: correct snapshot" "$snap" "snap-123"

# Non-existent step → empty
result=$(get_step "0.24.0" "nonExistent" "ACM-99")
assert_eq "missing step: empty" "$result" ""

# acli --paginate streams one {"comments":[...]} object PER PAGE; the fetch must
# slurp all pages into one array. Mock two concatenated page objects and assert a
# step recorded on page 2 is still found (guards the jq -s slurp + object unwrap).
acli() {
  if [[ "${*}" == *"comment list"* ]]; then
    cat <<'MOCK'
{"comments":[{"body":"## CVE fixes\n\n---\n```STEP_DATA\n{\"_t\":\"STEP_DATA\",\"step\":\"cveFixes\",\"timestamp\":\"2026-07-01T10:00:00Z\",\"status\":\"complete\",\"data\":{}}\n```"}]}
{"comments":[{"body":"## Bundle SHAs\n\n---\n```STEP_DATA\n{\"_t\":\"STEP_DATA\",\"step\":\"bundleShas\",\"timestamp\":\"2026-07-09T10:00:00Z\",\"status\":\"complete\",\"data\":{\"snapshot\":\"snap-page2\"}}\n```"}]}
MOCK
  fi
}
snap=$(printf '%s' "$(get_step "0.24.0" "bundleShas" "ACM-99")" | jq -r '.data.snapshot' 2>/dev/null)
assert_eq "multi-page: step from page 2 found" "$snap" "snap-page2"

# Empty comments → empty
acli() { printf '%s' "[]"; }
result=$(get_step "0.24.0" "cveFixes" "ACM-99")
assert_eq "no comments: empty" "$result" ""

# A genuinely empty tracker (valid `[]`) is a GOOD read → exit 0, empty output.
# This is the case evidence recorders must NOT confuse with a failed read below.
gs_rc=0; get_step "0.24.0" "cveFixes" "ACM-99" >/dev/null || gs_rc=$?
assert_eq "empty tracker: exit 0 (absent, not failed)" "$gs_rc" "0"

# Failed fetch (acli non-zero) → non-zero, so callers can tell a blip from absence
acli() { return 1; }
gs_rc=0; result=$(get_step "0.24.0" "cveFixes" "ACM-99") || gs_rc=$?
assert_eq "fetch failure: non-zero exit" "$gs_rc" "1"
assert_eq "fetch failure: no output" "$result" ""

# Garbled success (exit 0 but not a JSON array) → treated as unreliable → non-zero
acli() { printf '%s' 'not json'; }
gs_rc=0; result=$(get_step "0.24.0" "cveFixes" "ACM-99") || gs_rc=$?
assert_eq "garbled read: non-zero exit" "$gs_rc" "1"
assert_eq "garbled read: no output" "$result" ""

# Empty stdout on exit 0 (truncated response) → unreliable → non-zero
acli() { printf ''; }
gs_rc=0; result=$(get_step "0.24.0" "cveFixes" "ACM-99") || gs_rc=$?
assert_eq "empty stdout read: non-zero exit" "$gs_rc" "1"

# Reset mocks (restore library function behavior)
eval "$_SAVED_FIND_RELEASE_TRACKER"
acli() { :; }

# ============================================================================
echo ""
echo "=== 6. Contract Tests ==="
# ============================================================================

# Stub internals for update_step tests
query_jira() { echo '[{"key":"ACM-99"}]'; }
_find_subtask() { printf '%s' "ACM-98"; }
_add_comment() { return 0; }
_transition_issue() { return 0; }

# Returns 0
update_step "0.24.0" "cveFixes" "complete" "{}" "ACM-99" 2>/dev/null
assert_eq "update_step returns 0" "$?" "0"

# Returns 0 when _add_comment fails
_add_comment() { return 1; }
update_step "0.24.0" "cveFixes" "complete" "{}" "ACM-99" 2>/dev/null
assert_eq "update_step returns 0 on failure" "$?" "0"
_add_comment() { return 0; }

# No stdout
stdout=$(update_step "0.24.0" "cveFixes" "complete" "{}" "ACM-99" 2>/dev/null)
assert_eq "update_step: no stdout" "$stdout" ""

# Verify STEP_DATA comment contains valid JSON with data field
_ADD_COMMENT_BODY=""
_add_comment() { _ADD_COMMENT_BODY="$2"; return 0; }
_update_step_impl "0.24.0" "cveFixes" "complete" "{}" "ACM-99" 2>/dev/null || true
step_json=$(printf '%s\n' "$_ADD_COMMENT_BODY" | sed -n '/STEP_DATA/{n;p;}')
data_field=$(printf '%s' "$step_json" | jq -r '.data' 2>/dev/null) || data_field="PARSE_FAILED"
assert_eq "STEP_DATA has valid data field" "$data_field" "{}"

# STEP_DATA is the DAG's persistence contract: find_next_step keys the walk on
# .step and gates completion on .status, so a write that corrupts either field
# would re-run done steps or skip pending ones. Pin both.
assert_eq "STEP_DATA .step is the step key" \
  "$(printf '%s' "$step_json" | jq -r '.step')" "cveFixes"
assert_eq "STEP_DATA .status is the status" \
  "$(printf '%s' "$step_json" | jq -r '.status')" "complete"

# update_step maps step status → subtask Jira transition. Record the targets so
# a swapped or deleted transition (leaving subtasks stale) fails a test.
_transition_issue() { _T="${_T}${1}=>${2}"$'\n'; return 0; }
_T=""; update_step "0.24.0" "cveFixes" "complete" "{}" "ACM-99" 2>/dev/null
assert_eq "update_step: complete → subtask Resolved" \
  "$(printf '%s' "$_T" | grep -q 'ACM-98=>Resolved' && echo yes || echo no)" "yes"
_T=""; update_step "0.24.0" "cveFixes" "in_progress" "{}" "ACM-99" 2>/dev/null
assert_eq "update_step: in_progress → subtask In Progress" \
  "$(printf '%s' "$_T" | grep -q 'ACM-98=>In Progress' && echo yes || echo no)" "yes"
_T=""; update_step "0.24.0" "cveFixes" "failed" "{}" "ACM-99" 2>/dev/null
assert_eq "update_step: failed → no subtask transition" "$_T" ""
_transition_issue() { return 0; }

# find_release_tracker: invalid version → empty (not crash)
query_jira() { printf '%s' "SHOULD NOT BE CALLED"; }
result=$(find_release_tracker "bad" 2>/dev/null)
assert_eq "find_release_tracker: invalid version → empty" "$result" ""

# Reset
query_jira() { echo "[]"; }
_add_comment() { return 0; }

# find_release_tracker works with 2-segment version (normalized internally)
query_jira() { echo '[{"key":"ACM-222"}]'; }
result=$(find_release_tracker "0.24" 2>/dev/null)
assert_eq "find_release_tracker: 2-seg version works" "$result" "ACM-222"
query_jira() { echo "[]"; }

# find_release_tracker: Jira query failure → return 2 (distinct from absent)
query_jira() { return 1; }
result=$(find_release_tracker "0.24.0" 2>/dev/null) && rc=0 || rc=$?
assert_eq "find_release_tracker: query failure → rc 2" "$rc" "2"
assert_eq "find_release_tracker: query failure → empty stdout" "$result" ""

# find_release_tracker: genuinely absent (query ok, empty) → return 0, empty
query_jira() { echo "[]"; }
result=$(find_release_tracker "0.24.0" 2>/dev/null) && rc=0 || rc=$?
assert_eq "find_release_tracker: absent → rc 0" "$rc" "0"
assert_eq "find_release_tracker: absent → empty stdout" "$result" ""

# find_release_tracker: exit-0 but garbled response (not an array) → return 2,
# NOT 0/empty. A bare null / error object / truncated page must not be read as
# "absent" (that would let create_release_tracker make a DUPLICATE).
query_jira() { echo "null"; }
result=$(find_release_tracker "0.24.0" 2>/dev/null) && rc=0 || rc=$?
assert_eq "find_release_tracker: garbled (null) → rc 2" "$rc" "2"
assert_eq "find_release_tracker: garbled (null) → empty stdout" "$result" ""
query_jira() { printf '%s' '{"errorMessages":["boom"]}'; }
result=$(find_release_tracker "0.24.0" 2>/dev/null) && rc=0 || rc=$?
assert_eq "find_release_tracker: garbled (error obj) → rc 2" "$rc" "2"
query_jira() { echo "[]"; }

# Bare $(find_release_tracker) call sites must not set -e abort on the rc 2:
# get_release_summary echoes "{}" and returns 0 even when the lookup fails.
query_jira() { return 1; }
result=$(get_release_summary "0.24.0" 2>/dev/null) && rc=0 || rc=$?
assert_eq "get_release_summary: query failure → rc 0 (shielded)" "$rc" "0"
assert_eq "get_release_summary: query failure → {}" "$result" "{}"
query_jira() { echo "[]"; }

# close_release_tracker: resolves parent + open subtasks to "Resolved" (the same
# terminal status per-step completion uses), never "Closed". (Mocks find_release_tracker
# from here on — no test below relies on the real one.)
_has_transition() { printf '%s' "$_TRANSITIONS" | grep -q "$1" && echo yes || echo no; }
find_release_tracker() { printf '%s' "ACM-99"; }
_add_comment() { return 0; }
query_jira() { echo '[{"key":"ACM-101"},{"key":"ACM-102"}]'; }
_TRANSITIONS=""
_transition_issue() { _TRANSITIONS="${_TRANSITIONS}${1}=>${2}"$'\n'; return 0; }
close_release_tracker "0.24.0" "Release 0.24.0 complete" >/dev/null 2>&1; rc=$?
assert_eq "close: returns 0" "$rc" "0"
assert_eq "close: parent resolved" "$(_has_transition 'ACM-99=>Resolved')" "yes"
assert_eq "close: subtask ACM-101 resolved" "$(_has_transition 'ACM-101=>Resolved')" "yes"
assert_eq "close: subtask ACM-102 resolved" "$(_has_transition 'ACM-102=>Resolved')" "yes"
assert_eq "close: never transitions to Closed" "$(_has_transition 'Closed')" "no"

# close_release_tracker: subtask query filters on "status != Resolved".
# query_jira runs inside a $() subshell in the impl, so capture via a temp file
# (a global var assignment would not survive the subshell).
_CLOSE_JQL_FILE=$(mktemp)
query_jira() { printf '%s' "$*" >"$_CLOSE_JQL_FILE"; echo '[]'; }
close_release_tracker "0.24.0" "x" >/dev/null 2>&1 || true
assert_eq "close: subtask query filters status != Resolved" \
  "$(grep -q 'status != Resolved' "$_CLOSE_JQL_FILE" && echo yes || echo no)" "yes"
rm -f "$_CLOSE_JQL_FILE"

# close_release_tracker: no tracker found → returns 0, no transitions attempted
find_release_tracker() { printf '%s' ""; }
_TRANSITIONS=""
query_jira() { echo '[]'; }
close_release_tracker "0.24.0" "x" >/dev/null 2>&1; rc=$?
assert_eq "close: no tracker → returns 0" "$rc" "0"
assert_eq "close: no tracker → no transitions" "$_TRANSITIONS" ""

# close_release_tracker: best-effort — a failed transition still returns 0
find_release_tracker() { printf '%s' "ACM-99"; }
query_jira() { echo '[]'; }
_transition_issue() { return 1; }
close_release_tracker "0.24.0" "x" >/dev/null 2>&1; rc=$?
assert_eq "close: transition failure → returns 0" "$rc" "0"

# Reset mocks touched above for the smoke tests that follow
_transition_issue() { return 0; }
query_jira() { echo "[]"; }
_add_comment() { return 0; }

# tracker_is_open: gates auto-close so re-runs on a resolved release don't
# re-probe / re-comment. Open only when it POSITIVELY reads a non-Resolved status.
# (Capture rc via `&& ... || ...` so a returned 1 doesn't set -e abort the run.)
query_jira() { echo '[{"key":"ACM-99","fields":{"status":{"name":"In Progress"}}}]'; }
tracker_is_open "0.24.0" >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq "tracker_is_open: In Progress → open (0)" "$rc" "0"
query_jira() { echo '[{"key":"ACM-99","fields":{"status":{"name":"Resolved"}}}]'; }
tracker_is_open "0.24.0" >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq "tracker_is_open: Resolved → not open (1)" "$rc" "1"
query_jira() { echo '[]'; }
tracker_is_open "0.24.0" >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq "tracker_is_open: absent → not open (1)" "$rc" "1"
query_jira() { return 1; }
tracker_is_open "0.24.0" >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq "tracker_is_open: query failure → not open (1)" "$rc" "1"
query_jira() { echo "null"; }
tracker_is_open "0.24.0" >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq "tracker_is_open: garbled (non-array) → not open (1)" "$rc" "1"
tracker_is_open "bad-version" >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq "tracker_is_open: invalid version → not open (1)" "$rc" "1"
query_jira() { echo "[]"; }

# ============================================================================
echo ""
echo "=== 6b. File Existence ==="
# ============================================================================

GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)

# STEP_SCRIPT paths
script_missing=0
for key in "${!STEP_SCRIPT[@]}"; do
  if [ ! -f "$GIT_ROOT/${STEP_SCRIPT[$key]}" ]; then
    echo "  Missing STEP_SCRIPT: ${STEP_SCRIPT[$key]}" >&2
    script_missing=$((script_missing + 1))
  fi
done
assert_eq "all STEP_SCRIPT files exist" "$script_missing" "0"

# STEP_SKILL_HINT embedded workflow paths
hint_missing=0
for key in "${!STEP_SKILL_HINT[@]}"; do
  hint="${STEP_SKILL_HINT[$key]}"
  path=$(echo "$hint" | grep -oP '\.agents/workflows/\S+\.md' || true)
  [ -z "$path" ] && continue
  if [ ! -f "$GIT_ROOT/$path" ]; then
    echo "  Missing STEP_SKILL_HINT path: $path" >&2
    hint_missing=$((hint_missing + 1))
  fi
done
assert_eq "all STEP_SKILL_HINT workflow paths exist" "$hint_missing" "0"

# ============================================================================
echo ""
echo "=== 7. Smoke Tests ==="
# ============================================================================

# get_release_summary: valid JSON
find_release_tracker() { printf '%s' "ACM-99"; }
query_jira() {
  echo '[{"key":"ACM-100","fields":{"summary":"CVE fixes","status":{"name":"New"}}}]'
}
acli() { [[ "${*}" == *"comment list"* ]] && echo "[]"; }

summary=$(get_release_summary "0.24.0" 2>/dev/null)
printf '%s' "$summary" | jq -e . >/dev/null 2>&1 && valid="yes" || valid="no"
assert_eq "get_release_summary: valid JSON" "$valid" "yes"

step_count=$(printf '%s' "$summary" | jq '.steps | keys | length' 2>/dev/null)
assert_eq "get_release_summary: 18 steps (y-stream, versionLabels excluded)" "$step_count" "18"

# Template completeness
fallback_found=0
for key in "${STEP_ORDER[@]}"; do
  desc=$(_generate_subtask_description "$key" "0.24.0")
  if printf '%s' "$desc" | grep -qF "no description template"; then
    fallback_found=$((fallback_found + 1))
  fi
done
assert_eq "all step keys have templates" "$fallback_found" "0"

# OCP range in FBC subtask descriptions reflects FBC_OCP_VERSIONS (no hardcoded fallback)
_first_ocp=$(echo "$FBC_OCP_VERSIONS" | awk '{print $1}')
_last_ocp=$(echo "$FBC_OCP_VERSIONS" | awk '{print $NF}')
_expected_ocp_range="4.$_first_ocp through 4.$_last_ocp"
ocp_range_ok=0
for _fbc_step in fbcCatalogUpdate fbcStageReleases fbcProdReleases; do
  _desc=$(_generate_subtask_description "$_fbc_step" "0.24.0")
  if ! printf '%s' "$_desc" | grep -qF "$_expected_ocp_range"; then
    echo "  ✗ OCP range missing from $_fbc_step description (want: '$_expected_ocp_range')"
    ocp_range_ok=$((ocp_range_ok + 1))
  fi
done
assert_eq "FBC subtask descriptions contain OCP range from FBC_OCP_VERSIONS" "$ocp_range_ok" "0"

# create_release_tracker: ACM version failure
find_release_tracker() { :; }
query_jira() { echo "[]"; }
calculate_acm_version() { return 1; }
create_release_tracker "0.24.0" 2>/dev/null && crc=0 || crc=$?
assert_eq "create fails on ACM version error" "$crc" "1"
# shellcheck disable=SC2034  # ACM_VERSION used by library after mock returns
calculate_acm_version() { ACM_VERSION="ACM 2.17.0"; }

# ============================================================================
echo ""
echo "=== 8. Staleness surfaced end-to-end via get_release_summary ==="
# ============================================================================
# Section 4 tests check_freshness directly, always with 3 args (the re-fetch
# branch) and never asserting a value in the summary. Section 7 stubs comments
# to "[]", so every step's step_data stays "{}", the != "{}" guard is always
# false, and freshness never leaves its "fresh" default. This section drives the
# real production path (release-status.sh's only consumer): comments carry
# STEP_DATA, so get_release_summary hits the guard, calls check_freshness, and
# emits the freshness field — the wiring a regression would silently break.

_SAVED_FRT=$(declare -f find_release_tracker)
_SAVED_QJ=$(declare -f query_jira)
_SAVED_ACLI=$(declare -f acli)

find_release_tracker() { printf '%s' "ACM-99"; }
query_jira() { echo "[]"; }

# ecFixes recorded against snap-old while bundleShas advanced to snap-new → stale.
acli() {
  [[ "${*}" == *"comment list"* ]] || return 0
  cat <<'JSON'
[
  {"body":"```STEP_DATA\n{\"_t\":\"STEP_DATA\",\"step\":\"ecFixes\",\"timestamp\":\"2026-07-01T00:00:00Z\",\"status\":\"complete\",\"data\":{\"snapshot\":\"snap-old\"}}\n```"},
  {"body":"```STEP_DATA\n{\"_t\":\"STEP_DATA\",\"step\":\"bundleShas\",\"timestamp\":\"2026-07-01T00:00:00Z\",\"status\":\"complete\",\"data\":{\"snapshot\":\"snap-new\"}}\n```"}
]
JSON
}
summary=$(get_release_summary "0.24.0" 2>/dev/null)
result=$(printf '%s' "$summary" | jq -r '.steps.ecFixes.freshness')
assert_eq "advanced snapshot surfaces as stale in summary" "$result" "stale"

# Same snapshot → fresh (guards against a rule that flags everything stale).
acli() {
  [[ "${*}" == *"comment list"* ]] || return 0
  cat <<'JSON'
[
  {"body":"```STEP_DATA\n{\"_t\":\"STEP_DATA\",\"step\":\"ecFixes\",\"timestamp\":\"2026-07-01T00:00:00Z\",\"status\":\"complete\",\"data\":{\"snapshot\":\"snap-same\"}}\n```"},
  {"body":"```STEP_DATA\n{\"_t\":\"STEP_DATA\",\"step\":\"bundleShas\",\"timestamp\":\"2026-07-01T00:00:00Z\",\"status\":\"complete\",\"data\":{\"snapshot\":\"snap-same\"}}\n```"}
]
JSON
}
summary=$(get_release_summary "0.24.0" 2>/dev/null)
result=$(printf '%s' "$summary" | jq -r '.steps.ecFixes.freshness')
assert_eq "matching snapshot stays fresh in summary" "$result" "fresh"

eval "$_SAVED_FRT"
eval "$_SAVED_QJ"
eval "$_SAVED_ACLI"

# ============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ "$FAIL" -eq 0 ]; then
  echo "All $PASS tests passed"
else
  echo "$FAIL FAILED, $PASS passed"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
[ "$FAIL" -eq 0 ] || exit 1
