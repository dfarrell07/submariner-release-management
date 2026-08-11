#!/bin/bash
# Tests for autorelease DAG walk logic (sources the REAL find_next_step)
# Run: ./scripts/lib/test-autorelease.sh
# shellcheck disable=SC2034  # step_statuses is read by find_next_step as a global
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source jira-tracker.sh for constants + step_applies_to_release
unset _JIRA_TRACKER_SOURCED
source "$SCRIPT_DIR/jira-tracker.sh" 2>/dev/null || true

# Stub external calls
query_jira() { echo "[]"; }
acli() { :; }
# shellcheck disable=SC2034
calculate_acm_version() { ACM_VERSION="ACM 2.17.0"; }

# Source the real find_next_step (guarded by _AUTORELEASE_TESTING)
export _AUTORELEASE_TESTING=true
source "$SCRIPT_DIR/../autorelease.sh"

PASS=0 FAIL=0
assert_eq() {
  if [ "$2" = "$3" ]; then echo "  ✓ $1"; PASS=$((PASS + 1))
  else echo "  ✗ $1 (got: '$2', want: '$3')"; FAIL=$((FAIL + 1)); fi
}
assert_contains() {
  # assert_contains LABEL haystack needle
  if printf '%s' "$2" | grep -qF -- "$3"; then echo "  ✓ $1"; PASS=$((PASS + 1))
  else echo "  ✗ $1 (expected '$3' in: '$2')"; FAIL=$((FAIL + 1)); fi
}

echo "=== Version Resolution Tests ==="

# Save original stubs
_orig_query_jira=$(declare -f query_jira)
_orig_latest_downstream=$(declare -f _latest_downstream_version 2>/dev/null || echo "")
_orig_latest_upstream=$(declare -f _latest_upstream_release 2>/dev/null || echo "")
_orig_tracker_is_open=$(declare -f tracker_is_open 2>/dev/null || echo "")

# Default stub: tracker is open (non-Resolved) so Strategy 1 returns it.
tracker_is_open() { return 0; }

# 1: Tracker with multiple patches → picks latest (open tracker)
query_jira() {
  echo '[
    {"fields":{"summary":"Release Submariner 0.24.0"}},
    {"fields":{"summary":"Release Submariner 0.24.2"}},
    {"fields":{"summary":"Release Submariner 0.24.1"}},
    {"fields":{"summary":"Release Submariner 0.25.0"}}
  ]'
}
_latest_downstream_version() { :; }
_latest_upstream_release() { :; }
resolved=$(_resolve_version "0.24")
assert_eq "tracker: picks latest patch" "${resolved%%:*}" "0.24.2"
assert_eq "tracker: source is tracker" "${resolved#*:}" "tracker"

# 1b: Resolved tracker → falls through to Strategy 2/3 (next patch computed).
# The new JQL (AND status != Resolved) returns empty for a resolved tracker, so
# stub query_jira to return [] to simulate the server-side filter.
_ldv_1b=$(declare -f _latest_downstream_version)
_lus_1b=$(declare -f _latest_upstream_release)
_qj_1b=$(declare -f query_jira)
query_jira() { echo '[]'; }
_latest_downstream_version() { echo "0.24.2:complete"; }
_latest_upstream_release() { echo "0.24.2"; }
resolved=$(_resolve_version "0.24")
assert_eq "resolved tracker: falls through to next patch" "${resolved%%:*}" "0.24.3"
assert_eq "resolved tracker: source is released" "${resolved#*:}" "released"
eval "$_qj_1b"
eval "$_ldv_1b"; eval "$_lus_1b"

# 2: Tracker doesn't cross Y-streams → default
resolved=$(_resolve_version "0.26")
assert_eq "tracker: no cross-stream match" "${resolved#*:}" "default"

# 3: Downstream in-progress
query_jira() { echo "[]"; }
_latest_downstream_version() { echo "0.24.1:in-progress"; }
_latest_upstream_release() { :; }
resolved=$(_resolve_version "0.24")
assert_eq "downstream in-progress" "${resolved%%:*}" "0.24.1"
assert_eq "in-progress source" "${resolved#*:}" "in-progress"

# 4: Both equal → next patch
query_jira() { echo "[]"; }
_latest_downstream_version() { echo "0.24.0:complete"; }
_latest_upstream_release() { echo "0.24.0"; }
resolved=$(_resolve_version "0.24")
assert_eq "both equal: next patch" "${resolved%%:*}" "0.24.1"
assert_eq "both equal: source" "${resolved#*:}" "released"

# 5: Upstream ahead
query_jira() { echo "[]"; }
_latest_downstream_version() { echo "0.24.0:complete"; }
_latest_upstream_release() { echo "0.24.1"; }
resolved=$(_resolve_version "0.24")
assert_eq "upstream ahead" "${resolved%%:*}" "0.24.1"
assert_eq "upstream ahead: source" "${resolved#*:}" "upstream"

# 6: Downstream only (gh unavailable)
query_jira() { echo "[]"; }
_latest_downstream_version() { echo "0.24.0:complete"; }
_latest_upstream_release() { :; }
resolved=$(_resolve_version "0.24")
assert_eq "downstream only: next patch" "${resolved%%:*}" "0.24.1"
assert_eq "downstream only: source" "${resolved#*:}" "released"

# 7: Upstream only (no downstream YAMLs)
query_jira() { echo "[]"; }
_latest_downstream_version() { :; }
_latest_upstream_release() { echo "0.24.0"; }
resolved=$(_resolve_version "0.24")
assert_eq "upstream only" "${resolved%%:*}" "0.24.0"
assert_eq "upstream only: source" "${resolved#*:}" "upstream"

# 8: Downstream ahead of upstream
query_jira() { echo "[]"; }
_latest_downstream_version() { echo "0.24.1:complete"; }
_latest_upstream_release() { echo "0.24.0"; }
resolved=$(_resolve_version "0.24")
assert_eq "downstream ahead: next patch" "${resolved%%:*}" "0.24.2"
assert_eq "downstream ahead: source" "${resolved#*:}" "released"

# 9: Both empty → default
query_jira() { echo "[]"; }
_latest_downstream_version() { :; }
_latest_upstream_release() { :; }
resolved=$(_resolve_version "0.99")
assert_eq "fallback: defaults to .0" "${resolved%%:*}" "0.99.0"
assert_eq "fallback: source is default" "${resolved#*:}" "default"

# Strategy 1 degrades gracefully on a Jira outage: query_jira non-zero →
# tracker_result="" (line 50 `|| tracker_result=""`) → skip tracker, fall through
# to the downstream/upstream strategies rather than aborting. All the cases above
# feed query_jira valid output, so this failure path was never exercised.
query_jira() { return 1; }
_latest_downstream_version() { echo "0.24.1:in-progress"; }
_latest_upstream_release() { :; }
resolved=$(_resolve_version "0.24")
assert_eq "jira outage: falls back to downstream" "${resolved%%:*}" "0.24.1"
assert_eq "jira outage: source is downstream" "${resolved#*:}" "in-progress"

# Restore original stubs
eval "$_orig_query_jira"
if [ -n "$_orig_latest_downstream" ]; then
  eval "$_orig_latest_downstream"
else
  _latest_downstream_version() { :; }
fi
if [ -n "$_orig_latest_upstream" ]; then
  eval "$_orig_latest_upstream"
else
  _latest_upstream_release() { :; }
fi
if [ -n "$_orig_tracker_is_open" ]; then
  eval "$_orig_tracker_is_open"
else
  tracker_is_open() { return 0; }
fi

echo ""
echo "=== _latest_downstream_version Tests (real function, fixture tree) ==="

# The version-resolution tests above stub _latest_downstream_version, so its real
# parsing (sed filename decode, sort -V, and the grep -qxF exact-line stage-in-prod
# check) is otherwise never exercised. Drive the real function against a fixture
# release tree by overriding the global $GIT_ROOT it reads, then restore it.
_ldv_orig_git_root="$GIT_ROOT"
_ldv_fixture=$(mktemp -d)

_ldv_reset() {  # $1 = major.minor (e.g. 0.24)
  rm -rf "${_ldv_fixture:?}/releases"
  mkdir -p "$_ldv_fixture/releases/$1/stage" "$_ldv_fixture/releases/$1/prod"
}
GIT_ROOT="$_ldv_fixture"

# stage-only, no prod counterpart → in-progress
_ldv_reset "0.24"
touch "$_ldv_fixture/releases/0.24/stage/submariner-0-24-1-stage-20260101-01.yaml"
assert_eq "ldv: stage-only → in-progress" "$(_latest_downstream_version 0.24)" "0.24.1:in-progress"

# latest stage has a matching prod → complete
_ldv_reset "0.24"
touch "$_ldv_fixture/releases/0.24/stage/submariner-0-24-1-stage-20260101-01.yaml"
touch "$_ldv_fixture/releases/0.24/prod/submariner-0-24-1-prod-20260102-01.yaml"
assert_eq "ldv: stage==prod → complete" "$(_latest_downstream_version 0.24)" "0.24.1:complete"

# stage 0.24.1 with only 0.24.10 in prod → in-progress (grep -x, not substring match)
_ldv_reset "0.24"
touch "$_ldv_fixture/releases/0.24/stage/submariner-0-24-1-stage-20260101-01.yaml"
touch "$_ldv_fixture/releases/0.24/prod/submariner-0-24-10-prod-20260102-01.yaml"
assert_eq "ldv: grep -x avoids 0.24.1 ⊂ 0.24.10" "$(_latest_downstream_version 0.24)" "0.24.1:in-progress"

# multiple stage patches → latest by version sort (0.24.10 > 0.24.2, not lexical)
_ldv_reset "0.24"
touch "$_ldv_fixture/releases/0.24/stage/submariner-0-24-2-stage-20260101-01.yaml"
touch "$_ldv_fixture/releases/0.24/stage/submariner-0-24-10-stage-20260103-01.yaml"
assert_eq "ldv: sort -V picks 0.24.10 not 0.24.2" "$(_latest_downstream_version 0.24)" "0.24.10:in-progress"

# empty tree → empty output
_ldv_reset "0.24"
assert_eq "ldv: empty tree → empty" "$(_latest_downstream_version 0.24)" ""

GIT_ROOT="$_ldv_orig_git_root"
rm -rf "$_ldv_fixture"

echo ""
echo "=== _latest_upstream_release Tests (real function, mocked gh) ==="

# The version-resolution tests above stub _latest_upstream_release, so its real
# parsing (sort -V patch selection + the X.Y.Z regex guard that rejects malformed
# tags) is otherwise never exercised. Drive the real function against a mocked
# `gh` (whose output stands in for the already --jq-filtered tag_names), then
# remove the mock. A regression to lexical sort or a dropped regex guard would
# silently resolve the conductor onto the wrong patch — these tests catch that.

# multiple patches → latest by version sort (0.24.10 > 0.24.2, not lexical)
gh() { printf 'v0.24.0\nv0.24.10\nv0.24.2\n'; }
assert_eq "lur: sort -V picks 0.24.10 not 0.24.2" "$(_latest_upstream_release 0.24)" "0.24.10"

# malformed tag output → X.Y.Z regex guard rejects it → empty result
gh() { printf 'garbage\n'; }
assert_eq "lur: non-X.Y.Z rejected → empty" "$(_latest_upstream_release 0.24)" ""

# gh unavailable (non-zero) → `|| return 0` yields empty (feeds strategy-3 fallback)
gh() { return 1; }
assert_eq "lur: gh failure → empty" "$(_latest_upstream_release 0.24)" ""

unset -f gh

echo ""
echo "=== DAG Walk Tests (real find_next_step) ==="

# 1: Z-stream fresh → first no-dep step (after reorder: rpmLockfiles first)
declare -A step_statuses=()
find_next_step "0.99.1" "z-stream" "FAKE-123" 2>/dev/null
assert_eq "z-stream fresh: rpmLockfiles" "$NEXT_STEP" "rpmLockfiles"

# 2: Build readiness partial → versionLabels next
step_statuses=([cveFixes]=complete [ecFixes]=complete [rpmLockfiles]=complete [tektonTasks]=complete)
find_next_step "0.99.1" "z-stream" "FAKE-123" 2>/dev/null
assert_eq "z-stream partial: versionLabels" "$NEXT_STEP" "versionLabels"

# 3: All upstream deps done → upstreamRelease
step_statuses[versionLabels]=complete
find_next_step "0.99.1" "z-stream" "FAKE-123" 2>/dev/null
assert_eq "z-stream: upstreamRelease ready" "$NEXT_STEP" "upstreamRelease"

# 4: componentStage runs before releaseNotes (notes modify existing YAML)
step_statuses[upstreamRelease]=complete
step_statuses[bundleShas]=complete
find_next_step "0.99.1" "z-stream" "FAKE-123" 2>/dev/null
assert_eq "componentStage before releaseNotes" "$NEXT_STEP" "componentStage"

# 5: After componentStage → releaseNotes (depends on componentStage)
step_statuses[componentStage]=complete
find_next_step "0.99.1" "z-stream" "FAKE-123" 2>/dev/null
assert_eq "releaseNotes after componentStage" "$NEXT_STEP" "releaseNotes"

# 6: Y-stream starts with createBranches
declare -A step_statuses=()
find_next_step "0.99.0" "y-stream" "FAKE-123" 2>/dev/null
assert_eq "y-stream: createBranches first" "$NEXT_STEP" "createBranches"

# 7: Y-stream auto-satisfies versionLabels in upstreamRelease deps
step_statuses=([createBranches]=complete [configureDownstream]=complete [tektonComponents]=complete [tektonBundle]=complete [cveFixes]=complete [ecFixes]=complete [rpmLockfiles]=complete [tektonTasks]=complete)
find_next_step "0.99.0" "y-stream" "FAKE-123" 2>/dev/null
assert_eq "y-stream: upstreamRelease (vl skipped)" "$NEXT_STEP" "upstreamRelease"

# 7b: Y-stream upstreamRelease blocked when tektonComponents incomplete (new dep)
step_statuses=([createBranches]=complete [configureDownstream]=complete [tektonBundle]=complete [cveFixes]=complete [ecFixes]=complete [rpmLockfiles]=complete [tektonTasks]=complete)
find_next_step "0.99.0" "y-stream" "FAKE-123" 2>/dev/null
assert_eq "y-stream: upstreamRelease blocked (tektonComponents incomplete)" "$NEXT_STEP" "tektonComponents"

# 8: All done
for step in "${STEP_ORDER[@]}"; do step_statuses[$step]=complete; done
find_next_step "0.99.1" "z-stream" "FAKE-123" 2>/dev/null
assert_eq "all done" "$NEXT_STEP" ""
assert_eq "all done reason" "$NEXT_REASON" "all_done"

# 9: NEXT_REASON is correct for gate steps
declare -A step_statuses=([cveFixes]=complete [ecFixes]=complete [rpmLockfiles]=complete [tektonTasks]=complete [versionLabels]=complete)
find_next_step "0.99.1" "z-stream" "FAKE-123" 2>/dev/null
assert_eq "gate step: upstreamRelease" "$NEXT_STEP" "upstreamRelease"
assert_eq "gate reason" "$NEXT_REASON" "gate"

# 10: NEXT_REASON is correct for hint steps. rpmLockfiles → versionLabels →
# tektonTasks → cveFixes are all script-backed (run); ecFixes is the first hint step.
declare -A step_statuses=()
find_next_step "0.99.1" "z-stream" "FAKE-123" 2>/dev/null
assert_eq "hint step: rpmLockfiles (first, has script)" "$NEXT_STEP" "rpmLockfiles"
assert_eq "first step reason is run (has script)" "$NEXT_REASON" "run"
# Mark script-backed steps complete to reach the first hint step
step_statuses=([rpmLockfiles]=complete [versionLabels]=complete [tektonTasks]=complete [cveFixes]=complete)
find_next_step "0.99.1" "z-stream" "FAKE-123" 2>/dev/null
assert_eq "first hint: ecFixes" "$NEXT_STEP" "ecFixes"
assert_eq "hint reason (ecFixes has hint, no script)" "$NEXT_REASON" "hint"

# 11: NEXT_REASON="run" for steps with scripts
step_statuses=([cveFixes]=complete [ecFixes]=complete [rpmLockfiles]=complete [tektonTasks]=complete)
find_next_step "0.99.1" "z-stream" "FAKE-123" 2>/dev/null
assert_eq "run step: versionLabels (has script)" "$NEXT_STEP" "versionLabels"
assert_eq "run reason" "$NEXT_REASON" "run"

# 12: componentProd three-way join — blocked until all 3 deps satisfied
step_statuses=([cveFixes]=complete [ecFixes]=complete [rpmLockfiles]=complete [tektonTasks]=complete [versionLabels]=complete [upstreamRelease]=complete [bundleShas]=complete [componentStage]=complete [releaseNotes]=complete [fbcCatalogUpdate]=complete [fbcStageReleases]=complete [qeValidation]=complete)
find_next_step "0.99.1" "z-stream" "FAKE-123" 2>/dev/null
assert_eq "componentProd ready (all 3 deps met)" "$NEXT_STEP" "componentProd"
assert_eq "componentProd reason" "$NEXT_REASON" "run"

# 13: componentProd blocked when releaseNotes incomplete
step_statuses=([cveFixes]=complete [ecFixes]=complete [rpmLockfiles]=complete [tektonTasks]=complete [versionLabels]=complete [upstreamRelease]=complete [bundleShas]=complete [componentStage]=complete [fbcCatalogUpdate]=complete [fbcStageReleases]=complete [qeValidation]=complete)
find_next_step "0.99.1" "z-stream" "FAKE-123" 2>/dev/null
assert_eq "componentProd blocked (releaseNotes missing)" "$NEXT_STEP" "releaseNotes"

# 14: fbcCatalogUpdate after releaseNotes (both depend on componentStage)
step_statuses=([cveFixes]=complete [ecFixes]=complete [rpmLockfiles]=complete [tektonTasks]=complete [versionLabels]=complete [upstreamRelease]=complete [bundleShas]=complete [componentStage]=complete [releaseNotes]=complete)
find_next_step "0.99.1" "z-stream" "FAKE-123" 2>/dev/null
assert_eq "fbcCatalogUpdate after releaseNotes" "$NEXT_STEP" "fbcCatalogUpdate"

echo ""
echo "=== handle_step_override Tests ==="

# Save original update_step and install mock
_orig_update_step=$(declare -f update_step)
_UPDATE_STEP_CALLS=()
update_step() {
  _UPDATE_STEP_CALLS+=("$1|$2|$3|$4|$5")
}

# 15: Valid step key accepted
_UPDATE_STEP_CALLS=()
handle_step_override "0.99.1" "cveFixes" "complete" "FAKE-123" 2>/dev/null
assert_eq "valid step accepted (exit 0)" "$?" "0"
assert_eq "update_step called once" "${#_UPDATE_STEP_CALLS[@]}" "1"
assert_eq "update_step args" "${_UPDATE_STEP_CALLS[0]}" "0.99.1|cveFixes|complete|{}|FAKE-123"

# 16: Invalid step key rejected
_UPDATE_STEP_CALLS=()
override_exit=0
handle_step_override "0.99.1" "bogusStep" "complete" "FAKE-123" 2>/dev/null || override_exit=$?
assert_eq "invalid step rejected (exit 1)" "$override_exit" "1"
assert_eq "update_step not called" "${#_UPDATE_STEP_CALLS[@]}" "0"

# 17: Refresh action passes in_progress to update_step
_UPDATE_STEP_CALLS=()
handle_step_override "0.99.1" "bundleShas" "in_progress" "FAKE-123" 2>/dev/null
assert_eq "refresh action accepted" "$?" "0"
assert_eq "update_step refresh args" "${_UPDATE_STEP_CALLS[0]}" "0.99.1|bundleShas|in_progress|{}|FAKE-123"

# 18: Empty step key rejected
_UPDATE_STEP_CALLS=()
override_exit=0
handle_step_override "0.99.1" "" "complete" "FAKE-123" 2>/dev/null || override_exit=$?
assert_eq "empty step rejected (exit 1)" "$override_exit" "1"
assert_eq "update_step not called (empty)" "${#_UPDATE_STEP_CALLS[@]}" "0"

# 18b: Snapshot-rule step completed by hand records the bundleShas snapshot
_orig_snapshot_step_data=$(declare -f snapshot_step_data)
snapshot_step_data() { echo '{"snapshot":"submariner-0-99-abc"}'; }
_UPDATE_STEP_CALLS=()
handle_step_override "0.99.1" "qeValidation" "complete" "FAKE-123" 2>/dev/null
assert_eq "qeValidation --complete records snapshot" "${_UPDATE_STEP_CALLS[0]}" \
  '0.99.1|qeValidation|complete|{"snapshot":"submariner-0-99-abc"}|FAKE-123'

# 18c: No bundleShas snapshot known → falls back to {}
snapshot_step_data() { echo '{}'; }
_UPDATE_STEP_CALLS=()
handle_step_override "0.99.1" "qeValidation" "complete" "FAKE-123" 2>/dev/null
assert_eq "qeValidation --complete empty snapshot → {}" "${_UPDATE_STEP_CALLS[0]}" \
  '0.99.1|qeValidation|complete|{}|FAKE-123'

# 18d: in_progress never stamps a snapshot, even for a snapshot-rule step
snapshot_step_data() { echo '{"snapshot":"should-not-be-used"}'; }
_UPDATE_STEP_CALLS=()
handle_step_override "0.99.1" "qeValidation" "in_progress" "FAKE-123" 2>/dev/null
assert_eq "qeValidation in_progress → {} (guard is action=complete)" "${_UPDATE_STEP_CALLS[0]}" \
  '0.99.1|qeValidation|in_progress|{}|FAKE-123'

# 18e: a time-rule step (cveFixes = "3d") completed by hand must NOT stamp a snapshot,
# even when one is available — the guard's second condition is STALENESS_RULES[step]==snapshot.
snapshot_step_data() { echo '{"snapshot":"should-not-be-used"}'; }
_UPDATE_STEP_CALLS=()
handle_step_override "0.99.1" "cveFixes" "complete" "FAKE-123" 2>/dev/null
assert_eq "cveFixes (time rule) --complete → {} (not snapshot-stamped)" "${_UPDATE_STEP_CALLS[0]}" \
  '0.99.1|cveFixes|complete|{}|FAKE-123'
eval "$_orig_snapshot_step_data"

# Restore original update_step
eval "$_orig_update_step"

echo ""
echo "=== Step Verifier Tests ==="

# 19: STEP_VERIFIER map has entries for createBranches and upstreamRelease
assert_eq "createBranches has verifier" "${STEP_VERIFIER[createBranches]}" "verify_createBranches"
assert_eq "upstreamRelease has verifier" "${STEP_VERIFIER[upstreamRelease]}" "verify_upstreamRelease"

# 20: Steps with/without verifiers
assert_eq "ecFixes has verifier" "${STEP_VERIFIER[ecFixes]}" "verify_ecFixes"
assert_eq "fbcProdUrls has verifier" "${STEP_VERIFIER[fbcProdUrls]}" "verify_fbcProdUrls"
assert_eq "qeValidation has no verifier" "${STEP_VERIFIER[qeValidation]:-}" ""
assert_eq "componentStage has no verifier" "${STEP_VERIFIER[componentStage]:-}" ""

echo ""
echo "=== Verifier Evidence Tests ==="

# Verifiers must emit the evidence they checked on stdout so the conductor can
# record it as STEP_DATA (feeding snapshot-staleness rules + tracker legibility).

# 21: verify_ecFixes emits {snapshot,version} for the latest EC-passing snapshot
_orig_oc=$(declare -f oc 2>/dev/null || echo "")
_OC_SNAPSHOTS=''
oc() { case "$1" in whoami) return 0 ;; get) echo "$_OC_SNAPSHOTS" ;; *) return 0 ;; esac; }
_OC_SNAPSHOTS='{"items":[{"metadata":{"name":"submariner-0-99-abc123","labels":{"pac.test.appstudio.openshift.io/event-type":"push"},"annotations":{"test.appstudio.openshift.io/status":"[{\"scenario\":\"submariner-enterprise-contract\",\"status\":\"TestPassed\"}]"}}}]}'
ec_exit=0
ec_out=$(verify_ecFixes "0.99.1" 2>/dev/null) || ec_exit=$?
assert_eq "verify_ecFixes verified (exit 0)" "$ec_exit" "0"
assert_eq "verify_ecFixes emits snapshot+version" "$ec_out" \
  '{"snapshot":"submariner-0-99-abc123","version":"0.99.1"}'

# 22: EC failed → return 1 with no output (no false STEP_DATA)
_OC_SNAPSHOTS='{"items":[{"metadata":{"name":"submariner-0-99-abc123","labels":{"pac.test.appstudio.openshift.io/event-type":"push"},"annotations":{"test.appstudio.openshift.io/status":"[{\"scenario\":\"submariner-enterprise-contract\",\"status\":\"TestFailed\"}]"}}}]}'
ec_exit=0
ec_out=$(verify_ecFixes "0.99.1" 2>/dev/null) || ec_exit=$?
assert_eq "verify_ecFixes not verified (exit 1)" "$ec_exit" "1"
assert_eq "verify_ecFixes no output on failure" "$ec_out" ""

# 22a: fallback path must reject PR builds. The only EC-passing snapshot is a
# pull_request build (not a real main-branch build), so verify must decline —
# exit 1, no output. Guards the event-type filter in the fallback selector.
_OC_SNAPSHOTS='{"items":[{"metadata":{"name":"submariner-0-99-prbuild","labels":{"pac.test.appstudio.openshift.io/event-type":"pull_request"},"annotations":{"test.appstudio.openshift.io/status":"[{\"scenario\":\"submariner-enterprise-contract\",\"status\":\"TestPassed\"}]"}}}]}'
ec_exit=0
ec_out=$(verify_ecFixes "0.99.1" 2>/dev/null) || ec_exit=$?
assert_eq "verify_ecFixes rejects PR-event snapshot (exit 1)" "$ec_exit" "1"
assert_eq "verify_ecFixes PR-event → no output" "$ec_out" ""

# 22a2: with both a PR build and an older push build EC-passing, the push one
# must be selected (PR builds are filtered out, not merely deprioritized).
_OC_SNAPSHOTS='{"items":[{"metadata":{"name":"submariner-0-99-push-old","labels":{"pac.test.appstudio.openshift.io/event-type":"push"},"annotations":{"test.appstudio.openshift.io/status":"[{\"scenario\":\"submariner-enterprise-contract\",\"status\":\"TestPassed\"}]"}}},{"metadata":{"name":"submariner-0-99-pr-new","labels":{"pac.test.appstudio.openshift.io/event-type":"pull_request"},"annotations":{"test.appstudio.openshift.io/status":"[{\"scenario\":\"submariner-enterprise-contract\",\"status\":\"TestPassed\"}]"}}}]}'
ec_exit=0
ec_out=$(verify_ecFixes "0.99.1" 2>/dev/null) || ec_exit=$?
assert_eq "verify_ecFixes picks push over newer PR build (exit 0)" "$ec_exit" "0"
assert_eq "verify_ecFixes selects the push snapshot" "$ec_out" \
  '{"snapshot":"submariner-0-99-push-old","version":"0.99.1"}'

# 22a3/22a4: the accepted main-branch event set is push OR incoming OR
# retest-all-comment. Cover the two non-push types so dropping either clause
# from the selector fails a test (push + pull_request already covered above).
_OC_SNAPSHOTS='{"items":[{"metadata":{"name":"submariner-0-99-incoming","labels":{"pac.test.appstudio.openshift.io/event-type":"incoming"},"annotations":{"test.appstudio.openshift.io/status":"[{\"scenario\":\"submariner-enterprise-contract\",\"status\":\"TestPassed\"}]"}}}]}'
ec_exit=0
ec_out=$(verify_ecFixes "0.99.1" 2>/dev/null) || ec_exit=$?
assert_eq "verify_ecFixes accepts incoming-event snapshot (exit 0)" "$ec_exit" "0"
assert_eq "verify_ecFixes selects the incoming snapshot" "$ec_out" \
  '{"snapshot":"submariner-0-99-incoming","version":"0.99.1"}'

_OC_SNAPSHOTS='{"items":[{"metadata":{"name":"submariner-0-99-retest","labels":{"pac.test.appstudio.openshift.io/event-type":"retest-all-comment"},"annotations":{"test.appstudio.openshift.io/status":"[{\"scenario\":\"submariner-enterprise-contract\",\"status\":\"TestPassed\"}]"}}}]}'
ec_exit=0
ec_out=$(verify_ecFixes "0.99.1" 2>/dev/null) || ec_exit=$?
assert_eq "verify_ecFixes accepts retest-all-comment snapshot (exit 0)" "$ec_exit" "0"
assert_eq "verify_ecFixes selects the retest snapshot" "$ec_out" \
  '{"snapshot":"submariner-0-99-retest","version":"0.99.1"}'

# 22b-e: with a tracker, verify_ecFixes checks EC on the *bundleShas* snapshot
# (reconcilable rule) instead of the latest EC-passing one.
_orig_get_step_ec=$(declare -f get_step)
# 22b: bundleShas snapshot present + EC passed → records that exact snapshot
_OC_SNAPSHOTS='{"items":[{"metadata":{"name":"submariner-0-99-BBB","annotations":{"test.appstudio.openshift.io/status":"[{\"scenario\":\"submariner-enterprise-contract\",\"status\":\"TestPassed\"}]"}}}]}'
get_step() { echo '{"status":"complete","data":{"snapshot":"submariner-0-99-BBB"}}'; }
ec_exit=0
ec_out=$(verify_ecFixes "0.99.1" "FAKE-123" 2>/dev/null) || ec_exit=$?
assert_eq "verify_ecFixes (tracker) verifies bundleShas snapshot" "$ec_exit" "0"
assert_eq "verify_ecFixes (tracker) records bundleShas snapshot" "$ec_out" \
  '{"snapshot":"submariner-0-99-BBB","version":"0.99.1"}'

# 22c: bundleShas snapshot present but EC failed → return 1 (not verified)
_OC_SNAPSHOTS='{"items":[{"metadata":{"name":"submariner-0-99-BBB","annotations":{"test.appstudio.openshift.io/status":"[{\"scenario\":\"submariner-enterprise-contract\",\"status\":\"TestFailed\"}]"}}}]}'
ec_exit=0
ec_out=$(verify_ecFixes "0.99.1" "FAKE-123" 2>/dev/null) || ec_exit=$?
assert_eq "verify_ecFixes (tracker) EC-failed on bundleShas snapshot → exit 1" "$ec_exit" "1"
assert_eq "verify_ecFixes (tracker) EC-failed → no output" "$ec_out" ""

# 22d: bundleShas snapshot absent from the snapshot list → return 1 (can't verify).
# The list DOES contain a valid fallback snapshot (push + EC-passing), so a
# regression that ignored the tracker ($2) would wrongly succeed via the fallback
# path — this asserts exit 1 AND empty output to catch that.
_OC_SNAPSHOTS='{"items":[{"metadata":{"name":"submariner-0-99-abc123","labels":{"pac.test.appstudio.openshift.io/event-type":"push"},"annotations":{"test.appstudio.openshift.io/status":"[{\"scenario\":\"submariner-enterprise-contract\",\"status\":\"TestPassed\"}]"}}}]}'
get_step() { echo '{"status":"complete","data":{"snapshot":"submariner-0-99-MISSING"}}'; }
ec_exit=0
ec_out=$(verify_ecFixes "0.99.1" "FAKE-123" 2>/dev/null) || ec_exit=$?
assert_eq "verify_ecFixes (tracker) missing bundleShas snapshot → exit 1" "$ec_exit" "1"
assert_eq "verify_ecFixes (tracker) missing snapshot → no output" "$ec_out" ""

# 22e: tracker set but bundleShas has no snapshot yet → falls back to latest EC-passing
_OC_SNAPSHOTS='{"items":[{"metadata":{"name":"submariner-0-99-abc123","labels":{"pac.test.appstudio.openshift.io/event-type":"push"},"annotations":{"test.appstudio.openshift.io/status":"[{\"scenario\":\"submariner-enterprise-contract\",\"status\":\"TestPassed\"}]"}}}]}'
get_step() { echo '{"status":"complete","data":{}}'; }
ec_exit=0
ec_out=$(verify_ecFixes "0.99.1" "FAKE-123" 2>/dev/null) || ec_exit=$?
assert_eq "verify_ecFixes (tracker, no bundleShas snapshot) falls back" "$ec_exit" "0"
assert_eq "verify_ecFixes fallback records latest EC-passing" "$ec_out" \
  '{"snapshot":"submariner-0-99-abc123","version":"0.99.1"}'

# 22f: FAILED bundleShas read (get_step non-zero) must NOT fall back to the
# latest snapshot — that would verify/record EC against the wrong build. A valid
# fallback snapshot is present, so a regression that ignored the read failure
# would wrongly succeed via fallback; this asserts exit 1 AND no output.
_OC_SNAPSHOTS='{"items":[{"metadata":{"name":"submariner-0-99-abc123","labels":{"pac.test.appstudio.openshift.io/event-type":"push"},"annotations":{"test.appstudio.openshift.io/status":"[{\"scenario\":\"submariner-enterprise-contract\",\"status\":\"TestPassed\"}]"}}}]}'
get_step() { return 1; }
ec_exit=0
ec_out=$(verify_ecFixes "0.99.1" "FAKE-123" 2>/dev/null) || ec_exit=$?
assert_eq "verify_ecFixes (tracker) failed bundleShas read → exit 1" "$ec_exit" "1"
assert_eq "verify_ecFixes (tracker) failed read → no output (no wrong-snapshot fallback)" "$ec_out" ""
eval "$_orig_get_step_ec"

# 22g: EC failed (fallback) → stderr names the snapshot and status; stdout empty.
# Confirms that when the conductor stops at ecFixes the operator can read the
# diagnostic without querying oc manually.
_OC_SNAPSHOTS='{"items":[{"metadata":{"name":"submariner-0-99-abc123","labels":{"pac.test.appstudio.openshift.io/event-type":"push"},"annotations":{"test.appstudio.openshift.io/status":"[{\"scenario\":\"submariner-enterprise-contract\",\"status\":\"TestFailed\"}]"}}}]}'
ec_exit=0 _ec_err_tmp=$(mktemp)
ec_out=$(verify_ecFixes "0.99.1" 2>"$_ec_err_tmp") || ec_exit=$?
ec_diag=$(cat "$_ec_err_tmp"); rm -f "$_ec_err_tmp"
assert_eq "22g: fallback EC-failed stdout still empty" "$ec_out" ""
assert_eq "22g: fallback EC-failed exit 1" "$ec_exit" "1"
assert_contains "22g: fallback EC-failed stderr names snapshot" "$ec_diag" "submariner-0-99-abc123"
assert_contains "22g: fallback EC-failed stderr shows status" "$ec_diag" "TestFailed"

# 22h: EC failed on bundleShas snapshot → stderr names that snapshot + status.
get_step() { echo '{"status":"complete","data":{"snapshot":"submariner-0-99-BBB"}}'; }
_OC_SNAPSHOTS='{"items":[{"metadata":{"name":"submariner-0-99-BBB","annotations":{"test.appstudio.openshift.io/status":"[{\"scenario\":\"submariner-enterprise-contract\",\"status\":\"TestFailed\"}]"}}}]}'
ec_exit=0 _ec_err_tmp=$(mktemp)
ec_out=$(verify_ecFixes "0.99.1" "FAKE-123" 2>"$_ec_err_tmp") || ec_exit=$?
ec_diag=$(cat "$_ec_err_tmp"); rm -f "$_ec_err_tmp"
assert_eq "22h: target EC-failed stdout still empty" "$ec_out" ""
assert_eq "22h: target EC-failed exit 1" "$ec_exit" "1"
assert_contains "22h: target EC-failed stderr names snapshot" "$ec_diag" "submariner-0-99-BBB"
assert_contains "22h: target EC-failed stderr shows status" "$ec_diag" "TestFailed"

# 22i: no qualifying snapshot → stderr says so; stdout empty.
_OC_SNAPSHOTS='{"items":[]}'
ec_exit=0 _ec_err_tmp=$(mktemp)
ec_out=$(verify_ecFixes "0.99.1" 2>"$_ec_err_tmp") || ec_exit=$?
ec_diag=$(cat "$_ec_err_tmp"); rm -f "$_ec_err_tmp"
assert_eq "22i: no snapshot stdout empty" "$ec_out" ""
assert_eq "22i: no snapshot exit 1" "$ec_exit" "1"
assert_contains "22i: no snapshot stderr mentions prefix" "$ec_diag" "submariner-0-99-"

eval "$_orig_get_step_ec"
[ -n "$_orig_oc" ] && eval "$_orig_oc" || unset -f oc

# 23/24: verify_createBranches / verify_upstreamRelease emit git evidence
_orig_git=$(declare -f git 2>/dev/null || echo "")
_MOCK_LSREMOTE=''
git() { if [ "$1" = "ls-remote" ]; then echo "$_MOCK_LSREMOTE"; return 0; fi; command git "$@"; }

_MOCK_LSREMOTE=$'cafe123\trefs/heads/release-0.99'
cb_exit=0
cb_out=$(verify_createBranches "0.99.1" 2>/dev/null) || cb_exit=$?
assert_eq "verify_createBranches verified (exit 0)" "$cb_exit" "0"
assert_eq "verify_createBranches emits branch+sha" "$cb_out" \
  '{"branch":"release-0.99","operatorSha":"cafe123"}'

# Branch absent → return 1 with NO stdout (failure contract; mirrors upstreamRelease below).
_MOCK_LSREMOTE=''
cb_exit=0
cb_out=$(verify_createBranches "0.99.1" 2>/dev/null) || cb_exit=$?
assert_eq "verify_createBranches branch absent (exit 1)" "$cb_exit" "1"
assert_eq "verify_createBranches no output when absent" "$cb_out" ""

_MOCK_LSREMOTE=$'deadbeef\trefs/tags/v0.99.1'
ur_exit=0
ur_out=$(verify_upstreamRelease "0.99.1" 2>/dev/null) || ur_exit=$?
assert_eq "verify_upstreamRelease verified (exit 0)" "$ur_exit" "0"
assert_eq "verify_upstreamRelease emits tag+sha" "$ur_out" \
  '{"tag":"v0.99.1","operatorSha":"deadbeef"}'

_MOCK_LSREMOTE=''
ur_exit=0
ur_out=$(verify_upstreamRelease "0.99.1" 2>/dev/null) || ur_exit=$?
assert_eq "verify_upstreamRelease not tagged (exit 1)" "$ur_exit" "1"
assert_eq "verify_upstreamRelease no output when absent" "$ur_out" ""
[ -n "$_orig_git" ] && eval "$_orig_git" || unset -f git

# 25: verify_fbcProdUrls emits the resolved registry.redhat.io bundle image
_fbc_home=$(mktemp -d)
mkdir -p "$_fbc_home/konflux/submariner-operator-fbc"
printf '  - name: submariner.v0.99.1\n    image: registry.redhat.io/rhacm2/submariner-operator-bundle@sha256:abc\n' \
  > "$_fbc_home/konflux/submariner-operator-fbc/catalog-template.yaml"
_real_home="$HOME"; HOME="$_fbc_home"
fp_exit=0
fp_out=$(verify_fbcProdUrls "0.99.1" 2>/dev/null) || fp_exit=$?
HOME="$_real_home"; rm -rf "$_fbc_home"
assert_eq "verify_fbcProdUrls verified (exit 0)" "$fp_exit" "0"
assert_eq "verify_fbcProdUrls emits bundleImage" "$fp_out" \
  '{"bundleImage":"registry.redhat.io/rhacm2/submariner-operator-bundle@sha256:abc","version":"0.99.1"}'

# 25b-d: verify_fbcProdUrls failure paths must return 1 with NO stdout (no false
# STEP_DATA). Helper writes a catalog-template with the given image line.
_fbcprod_case() {
  local image="$1" home; home=$(mktemp -d)
  mkdir -p "$home/konflux/submariner-operator-fbc"
  if [ -n "$image" ]; then
    printf '  - name: submariner.v0.99.1\n    image: %s\n' "$image" \
      > "$home/konflux/submariner-operator-fbc/catalog-template.yaml"
  else
    # No bundle entry for this version.
    printf '  - name: submariner.v0.98.0\n    image: registry.redhat.io/x@sha256:old\n' \
      > "$home/konflux/submariner-operator-fbc/catalog-template.yaml"
  fi
  local real="$HOME" out exit=0; HOME="$home"
  out=$(verify_fbcProdUrls "0.99.1" 2>/dev/null) || exit=$?
  HOME="$real"; rm -rf "$home"
  printf '%s|%s' "$exit" "$out"
}
# 25b: still on temporary quay.io build URL → not done
assert_eq "verify_fbcProdUrls quay.io build URL → exit 1, no output" \
  "$(_fbcprod_case 'quay.io/redhat-user-workloads/submariner-tenant/x@sha256:abc')" "1|"
# 25c: neither quay build nor registry.redhat.io (unexpected registry) → not done
assert_eq "verify_fbcProdUrls non-prod registry → exit 1, no output" \
  "$(_fbcprod_case 'quay.io/submariner/submariner-operator-bundle@sha256:abc')" "1|"
# 25d: no bundle entry for this version → not done
assert_eq "verify_fbcProdUrls missing bundle entry → exit 1, no output" \
  "$(_fbcprod_case '')" "1|"

# 25e: real catalog templates interleave a 6-space channel entry and longer
# ".p" pre-release bundles with the GA bundle. The "^  - name: ...$" anchors
# (2-space indent + end-of-name) must resolve the GA bundle — not the channel
# entry (which drops the leading indent anchor would match) nor the earlier
# ".p" bundle (which dropping the "$" anchor would match). Ordering the decoys
# before the GA entry is what makes each mutation observable.
_fbc_home=$(mktemp -d)
mkdir -p "$_fbc_home/konflux/submariner-operator-fbc"
{
  printf '      - name: submariner.v0.99.1\n        replaces: submariner.v0.99.0\n'
  printf '  - name: submariner.v0.99.1-0.123.p\n    image: registry.redhat.io/rhacm2/x@sha256:PRE\n'
  printf '  - name: submariner.v0.99.1\n    image: registry.redhat.io/rhacm2/submariner-operator-bundle@sha256:GA\n'
} > "$_fbc_home/konflux/submariner-operator-fbc/catalog-template.yaml"
_real_home="$HOME"; HOME="$_fbc_home"
fp_exit=0
fp_out=$(verify_fbcProdUrls "0.99.1" 2>/dev/null) || fp_exit=$?
HOME="$_real_home"; rm -rf "$_fbc_home"
assert_eq "verify_fbcProdUrls resolves GA bundle past channel + .p decoys (exit 0)" "$fp_exit" "0"
assert_eq "verify_fbcProdUrls emits GA image, not channel or .p" "$fp_out" \
  '{"bundleImage":"registry.redhat.io/rhacm2/submariner-operator-bundle@sha256:GA","version":"0.99.1"}'

echo ""
echo "=== snapshot_step_data Tests ==="

# snapshot_step_data pulls bundleShas's snapshot so downstream snapshot-rule steps
# have a comparable value; falls back to {} when unavailable.
_orig_get_step=$(declare -f get_step)
get_step() { echo '{"_t":"STEP_DATA","step":"bundleShas","status":"complete","data":{"snapshot":"submariner-0-99-xyz","version":"0.99.1"}}'; }
assert_eq "snapshot_step_data extracts bundleShas snapshot" \
  "$(snapshot_step_data 0.99.1 FAKE-123)" '{"snapshot":"submariner-0-99-xyz"}'
get_step() { echo ''; }
assert_eq "snapshot_step_data no bundleShas step → {}" \
  "$(snapshot_step_data 0.99.1 FAKE-123)" '{}'
get_step() { echo '{"_t":"STEP_DATA","step":"bundleShas","status":"complete","data":{}}'; }
assert_eq "snapshot_step_data bundleShas without snapshot → {}" \
  "$(snapshot_step_data 0.99.1 FAKE-123)" '{}'
# Failed tracker read (get_step non-zero) → still {} so the step completes, but
# warns to stderr instead of silently disabling staleness tracking.
get_step() { return 1; }
_ssd_out=$(snapshot_step_data 0.99.1 FAKE-123 2>/dev/null)
assert_eq "snapshot_step_data failed read → {} (step still completes)" "$_ssd_out" '{}'
_ssd_warn=$(snapshot_step_data 0.99.1 FAKE-123 2>&1 >/dev/null)
case "$_ssd_warn" in *degraded*) _ssd_warned=yes;; *) _ssd_warned=no;; esac
assert_eq "snapshot_step_data failed read warns to stderr" "$_ssd_warned" "yes"
eval "$_orig_get_step"

echo ""
echo "=== Release-YAML Step Classification Tests ==="

# 20b: release-YAML steps drive the "After apply/watch" trailer
assert_eq "componentStage is release-YAML" "${RELEASE_YAML_STEPS[componentStage]:-}" "1"
assert_eq "componentProd is release-YAML" "${RELEASE_YAML_STEPS[componentProd]:-}" "1"
assert_eq "fbcStageReleases is release-YAML" "${RELEASE_YAML_STEPS[fbcStageReleases]:-}" "1"
assert_eq "fbcProdReleases is release-YAML" "${RELEASE_YAML_STEPS[fbcProdReleases]:-}" "1"
# PR-based / non-YAML steps keep the "After PRs merge" trailer
assert_eq "bundleShas is not release-YAML" "${RELEASE_YAML_STEPS[bundleShas]:-}" ""
assert_eq "fbcCatalogUpdate is not release-YAML" "${RELEASE_YAML_STEPS[fbcCatalogUpdate]:-}" ""
assert_eq "releaseNotes is not release-YAML" "${RELEASE_YAML_STEPS[releaseNotes]:-}" ""

# classify_log_growth: maps per-step push-log growth to the flag name the main
# loop must set — the core b8d7e01 fix. It is the single source of truth for the
# dispatch (the conductor just does `printf -v "$flag" 1`), so asserting it here
# means a revert/mis-map of the classifier fails loudly.
assert_eq "classify: release-YAML step + growth → ran_release_yaml_step" \
  "$(classify_log_growth componentStage 0 10)" "ran_release_yaml_step"
assert_eq "classify: bundleShas + growth → ran_direct_push_step" \
  "$(classify_log_growth bundleShas 0 10)" "ran_direct_push_step"
assert_eq "classify: no growth → empty" \
  "$(classify_log_growth componentStage 10 10)" ""
assert_eq "classify: fbcProdReleases + growth → ran_release_yaml_step" \
  "$(classify_log_growth fbcProdReleases 5 99)" "ran_release_yaml_step"
assert_eq "classify: fbcCatalogUpdate + growth → ran_direct_push_step" \
  "$(classify_log_growth fbcCatalogUpdate 0 10)" "ran_direct_push_step"

# Drive the REAL dispatch mechanism the conductor uses (classify_log_growth
# echoes the flag name; printf -v sets it). A mixed run must end with all
# applicable flags set. The surrounding `[ -n ] && printf -v` guard is
# load-bearing under set -euo pipefail (printf -v "" exits 2 and aborts the
# conductor), so reaching the asserts at all proves it held.
# Steps are "name:before:after" tuples to allow per-step log sizes.
# bundleShas is now DIRECT_PUSH_STEPS (not PR), so use rpmLockfiles for PR arm.
ran_pr_step="" ran_release_yaml_step="" ran_direct_push_step=""
for _spec in "rpmLockfiles:0:10" "tektonTasks:10:10" "componentStage:10:20" "fbcCatalogUpdate:20:30"; do
  _step=${_spec%%:*}; _rest=${_spec#*:}; _before=${_rest%%:*}; _after=${_rest##*:}
  _growth_flag=$(classify_log_growth "$_step" "$_before" "$_after")
  [ -n "$_growth_flag" ] && printf -v "$_growth_flag" '%s' 1
done
assert_eq "dispatch: mixed run sets ran_pr_step" "$ran_pr_step" "1"
assert_eq "dispatch: mixed run sets ran_release_yaml_step" "$ran_release_yaml_step" "1"
assert_eq "dispatch: mixed run sets ran_direct_push_step" "$ran_direct_push_step" "1"
assert_eq "dispatch: no-growth step is a safe no-op (guard held, no abort)" \
  "$ran_pr_step$ran_release_yaml_step$ran_direct_push_step" "111"

# print_pending_trailer: multiple block types can occur in one run, so multiple
# lines may print. 4-arg form adds direct-push trailer.
assert_eq "trailer: PR only" \
  "$(print_pending_trailer "1" "" "0.99.1")" \
  "After PRs merge, wait for Konflux to rebuild (~15-30 min), then re-run: /autorelease 0.99.1"
assert_eq "trailer: release-YAML only" \
  "$(print_pending_trailer "" "1" "0.99.1")" \
  "After apply/watch succeeds, re-run: /autorelease 0.99.1"
assert_eq "trailer: mixed (both) prints both lines" \
  "$(print_pending_trailer "1" "1" "0.99.1")" \
  "$(printf 'After PRs merge, wait for Konflux to rebuild (~15-30 min), then re-run: /autorelease 0.99.1\nAfter apply/watch succeeds, re-run: /autorelease 0.99.1')"
assert_eq "trailer: neither → generic fallback" \
  "$(print_pending_trailer "" "" "0.99.1")" \
  "After the actions above complete, re-run: /autorelease 0.99.1"
assert_eq "trailer: direct-push only" \
  "$(print_pending_trailer "" "" "0.99.1" "1")" \
  "After push + rebuild completes (~15-30 min), re-run: /autorelease 0.99.1"
assert_eq "trailer: direct-push + PR → both lines" \
  "$(print_pending_trailer "1" "" "0.99.1" "1")" \
  "$(printf 'After PRs merge, wait for Konflux to rebuild (~15-30 min), then re-run: /autorelease 0.99.1\nAfter push + rebuild completes (~15-30 min), re-run: /autorelease 0.99.1')"

# print_review_stop: a review step defers to the Pending Actions trailer whenever
# the run queued push/apply work (non-empty log) — including when an *earlier*
# chained auto step, not this review step, grew the log — and says "re-run now"
# only when nothing is pending. Keyed on log emptiness, matching the EXIT trailer
# so the two guidance lines never contradict each other.
_rev_log=$(mktemp)
assert_eq "review stop: empty push log → re-run now" \
  "$(print_review_stop "$_rev_log" "0.99.1")" \
  "  Review the output above, then re-run: /autorelease 0.99.1"
printf '\n  cd x\n  git push origin release-0.99\n' > "$_rev_log"
assert_eq "review stop: non-empty push log → defer to Pending Actions" \
  "$(print_review_stop "$_rev_log" "0.99.1")" \
  "  Review the output above, then complete the Pending Actions below."
rm -f "$_rev_log"

# print_propagation_note: names a failing step's immediate dependency (from
# STEP_DEPENDENCIES) so a raw "❌ failed" points at the likely propagation gap
# instead of a phantom bug. A single dep names one title; multiple deps list all;
# a dependency-less step prints nothing (its failure is never a propagation wait).
# (assert_contains is defined later, so exact-match with assert_eq here.)
assert_eq "propagation note: single dep names its title" \
  "$(print_propagation_note componentStage)" \
  "$(printf '%s\n%s' \
    "  If blocked on an earlier step, make sure the changes from" \
    "  Update bundle SHAs are pushed, merged, and rebuilt, then re-run.")"
assert_eq "propagation note: multi-dep lists all titles" \
  "$(print_propagation_note componentProd)" \
  "$(printf '%s\n%s' \
    "  If blocked on an earlier step, make sure the changes from" \
    "  QE testing, Component stage release, Release notes are pushed, merged, and rebuilt, then re-run.")"
assert_eq "propagation note: dependency-less step prints nothing" \
  "$(print_propagation_note rpmLockfiles)" ""

echo ""
echo "=== handle_close Tests ==="

# handle_close delegates to close_release_tracker (version + reason), exit 0
_orig_close=$(declare -f close_release_tracker)
_CLOSE_CALLS=()
close_release_tracker() { _CLOSE_CALLS+=("$1|$2"); return 0; }
close_exit=0
handle_close "0.99.1" "FAKE-123" 2>/dev/null || close_exit=$?
assert_eq "close: handle_close exit 0" "$close_exit" "0"
assert_eq "close: handle_close passes version" "${_CLOSE_CALLS[0]%%|*}" "0.99.1"
assert_eq "close: handle_close passes completion reason" "${_CLOSE_CALLS[0]#*|}" "Release 0.99.1 complete"
eval "$_orig_close"

echo ""
echo "=== try_auto_verify Tests (gate/hint chaining decision) ==="

# The gate|hint dispatch arm delegates its auto-verify-and-chain decision to
# try_auto_verify (extracted so it is reachable outside the _AUTORELEASE_TESTING
# guard). These drive that helper directly with stubbed verifiers + update_step.
_orig_update_step3=$(declare -f update_step)
VERSION="0.99.1"
TRACKER="FAKE-123"

# Verifiers run inside a command substitution (a subshell), so they record
# invocation via a temp file rather than a variable (which wouldn't propagate).
_VCALL_FILE=$(mktemp)
_fake_verify_ok()    { echo x >>"$_VCALL_FILE"; echo '{"evidence":"x"}'; return 0; }
_fake_verify_empty() { echo x >>"$_VCALL_FILE"; return 0; }   # exit 0, no stdout
_fake_verify_fail()  { echo x >>"$_VCALL_FILE"; return 1; }
update_step() { _UPDATE_STEP_CALLS+=("$1|$2|$3|$4|$5"); }

# A: step with no verifier → don't chain, no write
declare -A verified_steps=()
_UPDATE_STEP_CALLS=()
tav_exit=0; try_auto_verify "componentStage" || tav_exit=$?
assert_eq "try_auto_verify: no verifier → exit 1" "$tav_exit" "1"
assert_eq "try_auto_verify: no verifier → no update_step" "${#_UPDATE_STEP_CALLS[@]}" "0"

# B: verifier passes with evidence → chain, record STEP_DATA, mark quiet+tried
STEP_VERIFIER["faketest_ok"]="_fake_verify_ok"
declare -A verified_steps=()
_UPDATE_STEP_CALLS=(); : >"$_VCALL_FILE"; _AUTORELEASE_QUIET=""
tav_exit=0; try_auto_verify "faketest_ok" || tav_exit=$?
assert_eq "verifier passes → exit 0 (chain)" "$tav_exit" "0"
assert_eq "verifier passes → verifier invoked" "$(wc -l <"$_VCALL_FILE")" "1"
assert_eq "verifier passes → update_step complete+evidence" "${_UPDATE_STEP_CALLS[0]}" \
  '0.99.1|faketest_ok|complete|{"evidence":"x"}|FAKE-123'
assert_eq "verifier passes → marks verified_steps" "${verified_steps[faketest_ok]:-}" "1"
assert_eq "verifier passes → sets quiet" "$_AUTORELEASE_QUIET" "true"

# C: verifier passes but emits nothing → data defaults to {}
STEP_VERIFIER["faketest_empty"]="_fake_verify_empty"
declare -A verified_steps=()
_UPDATE_STEP_CALLS=()
tav_exit=0; try_auto_verify "faketest_empty" || tav_exit=$?
assert_eq "verifier empty stdout → exit 0" "$tav_exit" "0"
assert_eq "verifier empty stdout → data {}" "${_UPDATE_STEP_CALLS[0]}" \
  "0.99.1|faketest_empty|complete|{}|FAKE-123"

# D: already tried this run → don't re-verify (the anti-infinite-loop guard)
STEP_VERIFIER["faketest_guard"]="_fake_verify_ok"
declare -A verified_steps=([faketest_guard]=1)
_UPDATE_STEP_CALLS=(); : >"$_VCALL_FILE"
tav_exit=0; try_auto_verify "faketest_guard" || tav_exit=$?
assert_eq "already-tried guard → exit 1" "$tav_exit" "1"
assert_eq "already-tried guard → verifier NOT re-invoked" "$(wc -l <"$_VCALL_FILE")" "0"
assert_eq "already-tried guard → no update_step" "${#_UPDATE_STEP_CALLS[@]}" "0"

# E: verifier fails → don't chain, but mark tried so the walk can't loop forever
STEP_VERIFIER["faketest_fail"]="_fake_verify_fail"
declare -A verified_steps=()
_UPDATE_STEP_CALLS=(); : >"$_VCALL_FILE"
tav_exit=0; try_auto_verify "faketest_fail" || tav_exit=$?
assert_eq "verifier fails → exit 1 (stop)" "$tav_exit" "1"
assert_eq "verifier fails → verifier was invoked" "$(wc -l <"$_VCALL_FILE")" "1"
assert_eq "verifier fails → still marked tried" "${verified_steps[faketest_fail]:-}" "1"
assert_eq "verifier fails → no update_step" "${#_UPDATE_STEP_CALLS[@]}" "0"

# Cleanup: drop temp verifier map entries, restore real update_step
rm -f "$_VCALL_FILE"
unset 'STEP_VERIFIER[faketest_ok]' 'STEP_VERIFIER[faketest_empty]' \
  'STEP_VERIFIER[faketest_guard]' 'STEP_VERIFIER[faketest_fail]'
eval "$_orig_update_step3"

echo ""
echo "=== find_next_step Fetch/Parse Tests (real Jira read path) ==="

# The DAG-walk tests above run with _AUTORELEASE_TESTING=true, which skips the
# acli fetch entirely. These unset that flag in subshells and mock acli to drive
# the fetch/parse/refuse-on-bad-read block — the code that decides whether a
# read is trustworthy before the conductor acts on it. Subshells isolate the
# `exit 1` refusal paths from the test runner.

# Build an acli-style comments JSON array from "step:status" pairs, each body
# carrying a STEP_DATA fence exactly like update_step writes.
_build_comments() {
  local objs=() pair s st
  for pair in "$@"; do
    s="${pair%%:*}"; st="${pair#*:}"
    objs+=("$(jq -cn --arg s "$s" --arg st "$st" \
      '{body: ("---\n```STEP_DATA\n" + ({_t:"STEP_DATA",step:$s,status:$st,data:{}} | tojson) + "\n```")}')")
  done
  printf '%s\n' "${objs[@]}" | jq -s '.'
}

# A: valid read with 4 complete steps parses and feeds the DAG (→ versionLabels,
# matching the hand-seeded DAG test with the same statuses).
result=$(
  unset _AUTORELEASE_TESTING
  acli() { _build_comments "cveFixes:complete" "ecFixes:complete" "rpmLockfiles:complete" "tektonTasks:complete"; }
  declare -A step_statuses=()
  find_next_step "0.99.1" "z-stream" "FAKE-123" 2>/dev/null
  echo "$NEXT_STEP"
)
assert_eq "fetch+parse: 4 complete steps → versionLabels" "$result" "versionLabels"

# B: acli fails (nonzero) → refuse, exit 1 (never treat as zero steps done)
rc=0
( unset _AUTORELEASE_TESTING; acli() { return 4; }; declare -A step_statuses=(); \
  find_next_step "0.99.1" "z-stream" "FAKE-123" >/dev/null 2>&1 ) || rc=$?
assert_eq "fetch fails → refuse (exit 1)" "$rc" "1"

# C: acli exits 0 but empty output → refuse (a truncated/blank read is unsafe)
rc=0
( unset _AUTORELEASE_TESTING; acli() { return 0; }; declare -A step_statuses=(); \
  find_next_step "0.99.1" "z-stream" "FAKE-123" >/dev/null 2>&1 ) || rc=$?
assert_eq "fetch empty output → refuse (exit 1)" "$rc" "1"

# D: acli returns non-JSON garbage → refuse
rc=0
( unset _AUTORELEASE_TESTING; acli() { echo "garbage {["; }; declare -A step_statuses=(); \
  find_next_step "0.99.1" "z-stream" "FAKE-123" >/dev/null 2>&1 ) || rc=$?
assert_eq "fetch invalid JSON → refuse (exit 1)" "$rc" "1"

# D2: acli returns bare `null` → refuse. This is the case `jq empty` alone let
# through (it exits 0 on null); the `type=="array"` guard rejects it.
rc=0
( unset _AUTORELEASE_TESTING; acli() { echo "null"; }; declare -A step_statuses=(); \
  find_next_step "0.99.1" "z-stream" "FAKE-123" >/dev/null 2>&1 ) || rc=$?
assert_eq "fetch bare null → refuse (exit 1)" "$rc" "1"

# D3: acli returns a JSON object (e.g. an error body) → refuse. Also passes
# `jq empty`; rejected by the array guard.
rc=0
( unset _AUTORELEASE_TESTING; acli() { echo '{"errorMessages":["boom"]}'; }; declare -A step_statuses=(); \
  find_next_step "0.99.1" "z-stream" "FAKE-123" >/dev/null 2>&1 ) || rc=$?
assert_eq "fetch JSON object (error body) → refuse (exit 1)" "$rc" "1"

# E: genuinely empty tracker (valid "[]") → proceed to the first step. This is
# the load-bearing distinction: "[]" is safe, an empty string is not.
result=$(
  unset _AUTORELEASE_TESTING
  acli() { echo "[]"; }
  declare -A step_statuses=()
  find_next_step "0.99.1" "z-stream" "FAKE-123" 2>/dev/null
  echo "$NEXT_STEP"
)
assert_eq "fetch valid [] (empty tracker) → first step rpmLockfiles" "$result" "rpmLockfiles"

# F: latest-wins dedup. A step's normal re-run history is two comments — an
# earlier in_progress then a later complete (update_step appends one per run).
# The parser's `group_by(.step) | map(last)` must take the LAST, so rpmLockfiles
# reads complete and the walk advances past it to versionLabels. If dedup
# regressed to map(first), rpmLockfiles would read in_progress and be re-selected
# — a re-run of a done step, the exact hazard the read path guards against.
result=$(
  unset _AUTORELEASE_TESTING
  acli() { _build_comments "rpmLockfiles:in_progress" "rpmLockfiles:complete"; }
  declare -A step_statuses=()
  find_next_step "0.99.1" "z-stream" "FAKE-123" 2>/dev/null
  echo "$NEXT_STEP"
)
assert_eq "fetch+parse: dup step in_progress→complete → advances (versionLabels)" "$result" "versionLabels"

# G: a non-complete status is not mistaken for done. rpmLockfiles present only as
# in_progress must still be selected (not skipped). Guards status extraction: if
# the parser dropped .status or coerced it to complete, the walk would wrongly
# advance to versionLabels.
result=$(
  unset _AUTORELEASE_TESTING
  acli() { _build_comments "rpmLockfiles:in_progress"; }
  declare -A step_statuses=()
  find_next_step "0.99.1" "z-stream" "FAKE-123" 2>/dev/null
  echo "$NEXT_STEP"
)
assert_eq "fetch+parse: lone in_progress step is not skipped" "$result" "rpmLockfiles"

echo ""
echo "=== run_dry_run Tests (--dry-run preview) ==="

# run_dry_run reads the VERSION/RELEASE_TYPE/TRACKER globals and mutates the
# file-scope step_statuses; it prints everything to stderr and never writes.
assert_not_contains() {
  if printf '%s' "$2" | grep -qF -- "$3"; then echo "  ✗ $1 (unexpectedly present: '$3')"; FAIL=$((FAIL + 1))
  else echo "  ✓ $1"; PASS=$((PASS + 1)); fi
}

VERSION="0.99.1"; RELEASE_TYPE="z-stream"; TRACKER="FAKE-123"

# DR-1: Fresh z-stream → runs the four script steps (rpmLockfiles →
# versionLabels → tektonTasks → cveFixes), then stops AT cveFixes because it is a
# `review` run step (runs its script, then the loop breaks). No verifier crossed →
# plain "Stops at".
declare -A step_statuses=()
dr=$(run_dry_run 2>&1)
assert_contains "dry-run fresh z: runs rpmLockfiles"   "$dr" "run: scripts/rpm-lockfile-update.sh 0.99.1"
assert_contains "dry-run fresh z: runs versionLabels"  "$dr" "run: scripts/update-version-labels.sh 0.99.1"
assert_contains "dry-run fresh z: runs tektonTasks"    "$dr" "run: scripts/tekton-task-refs-update.sh 0.99.1"
assert_contains "dry-run fresh z: runs cveFixes"       "$dr" "run: scripts/cve-fixes-update.sh 0.99.1"
assert_contains "dry-run fresh z: stops at cveFixes (review)" "$dr" "Stops at: CVE fixes — runs the script then pauses for review — re-run /autorelease 0.99.1 to execute"
assert_not_contains "dry-run fresh z: no conditional stop (no gate crossed)" "$dr" "Earliest possible stop"

# DR-2: Mid-chain resume (seed through ecFixes, the plan's 5-step seed) →
# upstreamRelease shown "chains only if it passes" and the walk CONTINUES past it
# → bundleShas RUNS and then STOPS. bundleShas is `review` (the human stop that
# breaks the bundleShas → componentStage auto-chain, so the operator merges the
# SHA-bump PR and awaits the rebuild first), so componentStage is NOT reached.
# The flagship case: a verifier gate is conditional-not-hard-stop AND a review
# run stops.
step_statuses=([rpmLockfiles]=complete [versionLabels]=complete [tektonTasks]=complete [cveFixes]=complete [ecFixes]=complete)
midout=$(run_dry_run 2>&1)
assert_contains "dry-run mid: upstreamRelease conditional gate" "$midout" \
  "gate · auto-verifies: v0.99.1 tag exists on submariner-operator (verify_upstreamRelease;"
assert_contains "dry-run mid: chains to bundleShas"   "$midout" "run: scripts/bundle-image-update.sh 0.99.1"
assert_not_contains "dry-run mid: stops at bundleShas, componentStage NOT reached" "$midout" \
  "run: scripts/create-component-release.sh 0.99.1 stage"
assert_contains "dry-run mid: conditional stop line" "$midout" \
  "Earliest possible stop: Cut upstream release (verifier: v0.99.1 tag exists on submariner-operator)"
assert_contains "dry-run mid: stops at bundleShas (review)" "$midout" \
  "Otherwise stops at: Update bundle SHAs — runs the script then pauses for review — re-run /autorelease 0.99.1 to execute"

# DR-2b: each completed step's ✓-done line prints at most once (guards the
# _AUTORELEASE_QUIET set-before-rewalk — a leak would reprint it every re-walk).
assert_eq "dry-run mid: ✓ done printed once per step" \
  "$(printf '%s\n' "$midout" | grep -c '✓ RPM lockfile updates: done')" "1"

# DR-2c: footnote present on a run-stop; no push-log/Pending-Actions trailer.
assert_contains "dry-run mid: optimism footnote present" "$midout" "this offline preview is optimistic"
assert_not_contains "dry-run mid: no push-log trailer" "$midout" "Pending Actions"

# DR-3: Side-effect classification, git-push arm. The mid-chain run stops at the
# bundleShas review step → exactly one "→ then" line: bundleShas → git push.
assert_contains "dry-run side-effect: bundleShas → git push"   "$midout" "→ then: git push (direct push, no PR; wait ~15-30 min for rebuild)"
assert_eq "dry-run side-effect: mid-run has exactly 1 → then (stops at bundleShas)" \
  "$(printf '%s\n' "$midout" | grep -c '→ then:')" "1"

# DR-3b: apply/watch arm. componentStage is "review", so dry-run stops there
# (does not chain to releaseNotes). Exactly one "→ then" for apply/watch.
step_statuses=([rpmLockfiles]=complete [versionLabels]=complete [tektonTasks]=complete [cveFixes]=complete [ecFixes]=complete [upstreamRelease]=complete [bundleShas]=complete)
compout=$(run_dry_run 2>&1)
assert_contains "dry-run side-effect: componentStage → apply/watch" "$compout" "→ then: make apply/watch (release CR)"
assert_not_contains "dry-run side-effect: stops before releaseNotes" "$compout" "run: scripts/add-release-notes.sh 0.99.1"
assert_eq "dry-run side-effect: exactly 1 → then (stops at componentStage)" \
  "$(printf '%s\n' "$compout" | grep -c '→ then:')" "1"

# DR-3c: fbcStageReleases (also a RELEASE_YAML step) → make apply/watch.
step_statuses=([cveFixes]=complete [ecFixes]=complete [rpmLockfiles]=complete [tektonTasks]=complete [versionLabels]=complete [upstreamRelease]=complete [bundleShas]=complete [componentStage]=complete [releaseNotes]=complete [fbcCatalogUpdate]=complete)
fbcstage=$(run_dry_run 2>&1)
assert_contains "dry-run: fbcStageReleases shown"        "$fbcstage" "run: scripts/create-fbc-releases.sh 0.99.1 stage"
assert_contains "dry-run: fbcStageReleases → apply/watch" "$fbcstage" "→ then: make apply/watch (release CR)"

# DR-3d: no trailing space on an extra-args-less run: line (bundleShas has none).
bs_line=$(printf '%s\n' "$midout" | grep 'bundle-image-update.sh')
assert_eq "dry-run: no trailing space on args-less run line" "$bs_line" \
  "       run: scripts/bundle-image-update.sh 0.99.1"

# DR-4: fbcProdUrls terminal (seed all complete except fbcProdUrls) → prints the
# "all release steps shipped" block pointing at the prod-URL conversion with a
# re-run-to-close nudge; NOT "all done", NOT the generic --complete hint nudge,
# and NO optimism footnote (the terminal carries its own text).
step_statuses=([cveFixes]=complete [ecFixes]=complete [rpmLockfiles]=complete [tektonTasks]=complete [versionLabels]=complete [upstreamRelease]=complete [bundleShas]=complete [componentStage]=complete [releaseNotes]=complete [fbcCatalogUpdate]=complete [fbcStageReleases]=complete [qeValidation]=complete [componentProd]=complete [fbcProdReleases]=complete)
term=$(run_dry_run 2>&1)
assert_contains "dry-run terminal: all-shipped block" "$term" "All automated steps complete for 0.99.1"
assert_contains "dry-run terminal: re-run-to-close nudge" "$term" "Re-run once done to close the release: /autorelease 0.99.1"
assert_contains "dry-run terminal: dry-run conversion caveat" "$term" "cannot confirm whether the conversion has happened"
assert_not_contains "dry-run terminal: not 'nothing left'" "$term" "Nothing left to run"
assert_not_contains "dry-run terminal: no --complete nudge" "$term" "--complete fbcProdUrls"
assert_not_contains "dry-run terminal: no optimism footnote" "$term" "this offline preview is optimistic"

# DR-5: genuinely all done (seed everything) → "Nothing left to run", no footnote.
for step in "${STEP_ORDER[@]}"; do step_statuses[$step]=complete; done
alldone=$(run_dry_run 2>&1)
assert_contains "dry-run all-done: nothing left" "$alldone" "Nothing left to run for 0.99.1"
assert_not_contains "dry-run all-done: not terminal block" "$alldone" "All automated steps complete"
assert_not_contains "dry-run all-done: no optimism footnote" "$alldone" "this offline preview is optimistic"

# DR-6: fresh y-stream → createBranches (hint+verifier) chains with a PLAIN label
# (no "gate ·"), then the auto chain (configureDownstream, tektonComponents,
# tektonBundle, rpmLockfiles, versionLabels, tektonTasks) runs until cveFixes
# (first review stop). ecFixes (auto, reached as hint+verifier) also gets a plain label.
VERSION="0.99.0"; RELEASE_TYPE="y-stream"; TRACKER="FAKE-9"
declare -A step_statuses=()
yout=$(run_dry_run 2>&1)
assert_contains "dry-run y: createBranches plain label" "$yout" \
  "auto-verifies: release-0.99 branches exist on all upstream repos (verify_createBranches;"
assert_not_contains "dry-run y: createBranches has no gate · prefix" "$yout" \
  "gate · auto-verifies: release-0.99 branches exist"
assert_contains "dry-run y: conditional stop names createBranches verifier" "$yout" \
  "Earliest possible stop: Create upstream release branches (verifier: release-0.99 branches exist on all upstream repos)"
assert_contains "dry-run y: tektonComponents listed as run step" "$yout" "Tekton component setup"
assert_contains "dry-run y: stops at cveFixes (first review)" "$yout" "Otherwise stops at: CVE fixes"

# DR-6b: ecFixes reaches the verifier arm as hint (auto level) → plain label.
VERSION="0.99.1"; RELEASE_TYPE="z-stream"; TRACKER="FAKE-123"
step_statuses=([rpmLockfiles]=complete [versionLabels]=complete [tektonTasks]=complete [cveFixes]=complete)
ecout=$(run_dry_run 2>&1)
assert_contains "dry-run: ecFixes plain verifier label" "$ecout" \
  "auto-verifies: EC passes on Konflux snapshot (verify_ecFixes;"
assert_not_contains "dry-run: ecFixes has no gate · prefix" "$ecout" \
  "gate · auto-verifies: EC passes on Konflux snapshot"

# DR-7: fetch-once/freeze transition — the ONLY coverage of the NOFETCH arm
# (dead under _AUTORELEASE_TESTING). Unset it in a subshell, spy on the fetch, and
# assert exactly one real fetch AND that the fetched state drives the walk.
_FETCH_SPY=$(mktemp)
result=$(
  unset _AUTORELEASE_TESTING
  _fetch_tracker_comments() { echo x >>"$_FETCH_SPY"; _build_comments \
    "rpmLockfiles:complete" "versionLabels:complete" "tektonTasks:complete" \
    "cveFixes:complete" "ecFixes:complete"; }
  declare -A step_statuses=()
  VERSION="0.99.1"; RELEASE_TYPE="z-stream"; TRACKER="FAKE-123"
  run_dry_run 2>&1
)
assert_eq "dry-run freeze: exactly one fetch (rest walk in memory)" "$(wc -l <"$_FETCH_SPY")" "1"
assert_contains "dry-run freeze: fetched state drives the walk" "$result" \
  "auto-verifies: v0.99.1 tag exists on submariner-operator"
rm -f "$_FETCH_SPY"

# DR-8: a bad Jira read refuses the dry run too (find_next_step's own exit 1),
# and nothing is previewed. Subshell contains the exit.
rc=0
badout=$(
  unset _AUTORELEASE_TESTING
  _fetch_tracker_comments() { return 4; }
  declare -A step_statuses=()
  VERSION="0.99.1"; RELEASE_TYPE="z-stream"; TRACKER="FAKE-123"
  run_dry_run 2>&1
) || rc=$?
assert_eq "dry-run bad read → exit 1" "$rc" "1"
assert_not_contains "dry-run bad read → nothing previewed" "$badout" "Would run next"

# DR-9: strictly read-only. Redefine every WRITE function dry-run could reach —
# update_step and all four verify_* — to touch a sentinel then fail. Run on TWO
# seeds (mid-chain resume AND fbcProdUrls-terminal). Isolated in a subshell so the
# redefinitions don't leak. No sentinel written == strictly read-only.
ro_rc=0
(
  SENTINEL=$(mktemp -u)
  update_step() { touch "$SENTINEL"; return 1; }
  verify_createBranches() { touch "$SENTINEL"; return 1; }
  verify_upstreamRelease() { touch "$SENTINEL"; return 1; }
  verify_ecFixes() { touch "$SENTINEL"; return 1; }
  verify_fbcProdUrls() { touch "$SENTINEL"; return 1; }
  VERSION="0.99.1"; RELEASE_TYPE="z-stream"; TRACKER="FAKE-123"
  declare -A step_statuses=([rpmLockfiles]=complete [versionLabels]=complete [tektonTasks]=complete [cveFixes]=complete [ecFixes]=complete)
  run_dry_run >/dev/null 2>&1
  step_statuses=([cveFixes]=complete [ecFixes]=complete [rpmLockfiles]=complete [tektonTasks]=complete [versionLabels]=complete [upstreamRelease]=complete [bundleShas]=complete [componentStage]=complete [releaseNotes]=complete [fbcCatalogUpdate]=complete [fbcStageReleases]=complete [qeValidation]=complete [componentProd]=complete [fbcProdReleases]=complete)
  run_dry_run >/dev/null 2>&1
  [ -e "$SENTINEL" ] && exit 1
  exit 0
) || ro_rc=$?
assert_eq "dry-run strictly read-only (2 seeds, no write fn called)" "$ro_rc" "0"

echo ""
echo "=== run_preflight Tests (readiness report) ==="

# run_preflight probes jq/git (real, present here) plus acli/gh/oc, which we stub
# as shell functions so `command -v` sees them present and the auth/login
# sub-probes read our canned exit/output. Restored to good stubs between cases.
_pf_good_acli() { acli() { echo "Logged in as tester@example.com"; }; }
_pf_good_gh()   { gh() { return 0; }; }
_pf_good_oc()   { oc() { [ "$1" = whoami ] && { echo "kube:admin"; return 0; }; return 0; }; }
_pf_good_acli; _pf_good_gh; _pf_good_oc

# All good → every line ✓, no warnings, returns 0.
pf=$(run_preflight 2>&1); pf_rc=$?
assert_eq "preflight all-good: returns 0" "$pf_rc" "0"
assert_contains "preflight all-good: jq ✓"  "$pf" "✓ jq"
assert_contains "preflight all-good: git ✓" "$pf" "✓ git"
assert_contains "preflight all-good: acli authed"  "$pf" "✓ acli — Jira authenticated"
assert_contains "preflight all-good: gh authed"    "$pf" "✓ gh — authenticated"
assert_contains "preflight all-good: oc logged in (user shown)" "$pf" "✓ oc — logged in (kube:admin)"
assert_not_contains "preflight all-good: no warnings" "$pf" "⚠"

# gh unauthed → ⚠ with the login hint; unrelated probes stay ✓.
gh() { return 1; }
pf=$(run_preflight 2>&1)
assert_contains "preflight gh-unauthed: ⚠ + fix" "$pf" "gh — not authenticated; run: gh auth login"
assert_contains "preflight gh-unauthed: acli still ✓" "$pf" "✓ acli — Jira authenticated"
_pf_good_gh

# oc not logged in → ⚠ that explains the silent-verifier consequence.
oc() { return 1; }
pf=$(run_preflight 2>&1)
assert_contains "preflight oc-logged-out: ⚠ verifier note" "$pf" "verifier gate steps can't self-confirm"
_pf_good_oc

# acli output lacking the authenticated marker → ⚠ + login hint.
acli() { echo "No active session"; }
pf=$(run_preflight 2>&1)
assert_contains "preflight acli-unauthed: ⚠ + login hint" "$pf" \
  "acli — not authenticated to Jira; run: acli jira auth login --web"
_pf_good_acli

# Never blocks: every cred failing still returns 0 (purely additive, per plan).
acli() { echo ""; }; gh() { return 1; }; oc() { return 1; }
run_preflight >/dev/null 2>&1; pf_rc=$?
assert_eq "preflight all-fail: still returns 0 (never blocks)" "$pf_rc" "0"
_pf_good_acli; _pf_good_gh; _pf_good_oc

# Strictly read-only: redefine a write function to trip a sentinel; preflight
# (all reads) must never touch it.
_PF_SENT=$(mktemp -u)
_pf_orig_update=$(declare -f update_step)
update_step() { touch "$_PF_SENT"; }
run_preflight >/dev/null 2>&1
assert_eq "preflight strictly read-only (no update_step)" \
  "$([ -e "$_PF_SENT" ] && echo touched || echo clean)" "clean"
eval "$_pf_orig_update"; rm -f "$_PF_SENT"

echo ""
echo "=== Snapshot Staleness Warning Tests ==="

# The staleness warning in find_next_step's complete arm fires when a snapshot-rule
# step's recorded snapshot differs from bundleShas's recorded snapshot.
# step_snaps is normally populated by the Jira fetch, which is skipped under
# _AUTORELEASE_TESTING=true; seed it directly to test the warning path.

# Warning fires: ecFixes was verified on OLD snap, bundleShas records NEW snap.
# Reset QUIET — a prior test leaves it "true" which would suppress the warning.
_AUTORELEASE_QUIET=""
step_snaps=([ecFixes]="submariner-0-99-OLD" [bundleShas]="submariner-0-99-NEW")
declare -A step_statuses=([cveFixes]=complete [ecFixes]=complete \
  [rpmLockfiles]=complete [tektonTasks]=complete [versionLabels]=complete)
_stale_err=$(find_next_step "0.99.1" "z-stream" "FAKE-123" 2>&1 >/dev/null)
assert_contains "staleness: warning fires when snapshots differ" \
  "$_stale_err" "stale — snapshot changed since completion"
assert_contains "staleness: --refresh suggestion included" \
  "$_stale_err" "--refresh ecFixes"

# No warning when snapshots match.
step_snaps=([ecFixes]="submariner-0-99-SAME" [bundleShas]="submariner-0-99-SAME")
declare -A step_statuses=([cveFixes]=complete [ecFixes]=complete \
  [rpmLockfiles]=complete [tektonTasks]=complete [versionLabels]=complete)
_stale_err=$(find_next_step "0.99.1" "z-stream" "FAKE-123" 2>&1 >/dev/null)
assert_not_contains "staleness: no warning when snapshots match" \
  "$_stale_err" "stale — snapshot"

# No warning when bundleShas snap is absent (can't compare; safe direction).
step_snaps=([ecFixes]="submariner-0-99-OLD")
declare -A step_statuses=([cveFixes]=complete [ecFixes]=complete \
  [rpmLockfiles]=complete [tektonTasks]=complete [versionLabels]=complete)
_stale_err=$(find_next_step "0.99.1" "z-stream" "FAKE-123" 2>&1 >/dev/null)
assert_not_contains "staleness: no warning when bundleShas snap absent" \
  "$_stale_err" "stale — snapshot"

# No warning when step snap is absent (step completed before snapshot tracking).
step_snaps=([bundleShas]="submariner-0-99-NEW")
declare -A step_statuses=([cveFixes]=complete [ecFixes]=complete \
  [rpmLockfiles]=complete [tektonTasks]=complete [versionLabels]=complete)
_stale_err=$(find_next_step "0.99.1" "z-stream" "FAKE-123" 2>&1 >/dev/null)
assert_not_contains "staleness: no warning when step snap absent" \
  "$_stale_err" "stale — snapshot"

# Time-based rule (cveFixes="3d") must NOT trigger the snapshot-staleness check.
# Guards the `if [ "${STALENESS_RULES[$step]:-}" = "snapshot" ]` gate.
step_snaps=([cveFixes]="submariner-0-99-OLD" [bundleShas]="submariner-0-99-NEW")
declare -A step_statuses=([rpmLockfiles]=complete [versionLabels]=complete \
  [tektonTasks]=complete [cveFixes]=complete)
_stale_err=$(find_next_step "0.99.1" "z-stream" "FAKE-123" 2>&1 >/dev/null)
assert_not_contains "staleness: time-rule step not snapshot-stale" \
  "$_stale_err" "stale — snapshot"

# Snapshot staleness warning is suppressed when _AUTORELEASE_QUIET=true.
# Mirrors the positive test above but with QUIET=true — ensures the QUIET guard
# covers the staleness path.
_AUTORELEASE_QUIET=true
step_snaps=([ecFixes]="submariner-0-99-OLD" [bundleShas]="submariner-0-99-NEW")
declare -A step_statuses=([cveFixes]=complete [ecFixes]=complete \
  [rpmLockfiles]=complete [tektonTasks]=complete [versionLabels]=complete)
_stale_err=$(find_next_step "0.99.1" "z-stream" "FAKE-123" 2>&1 >/dev/null)
assert_not_contains "staleness: quiet suppresses snapshot warning" \
  "$_stale_err" "stale — snapshot"
_AUTORELEASE_QUIET=""

# Time-based staleness warning fires when step_timestamps shows a timestamp
# older than the rule (cveFixes="3d"). Seed an epoch timestamp well in the past.
_AUTORELEASE_QUIET=""
step_snaps=()
step_timestamps=([cveFixes]="2000-01-01T00:00:00Z")
declare -A step_statuses=([rpmLockfiles]=complete [versionLabels]=complete \
  [tektonTasks]=complete [cveFixes]=complete)
_stale_err=$(find_next_step "0.99.1" "z-stream" "FAKE-123" 2>&1 >/dev/null)
assert_contains "staleness: time-rule fires when stale" \
  "$_stale_err" "stale — completed"
assert_contains "staleness: time-rule includes --refresh suggestion" \
  "$_stale_err" "--refresh cveFixes"

# Time-based staleness suppressed when _AUTORELEASE_QUIET=true.
_AUTORELEASE_QUIET=true
_stale_err=$(find_next_step "0.99.1" "z-stream" "FAKE-123" 2>&1 >/dev/null)
assert_not_contains "staleness: quiet suppresses time-rule warning" \
  "$_stale_err" "stale — completed"
_AUTORELEASE_QUIET=""
step_timestamps=()

# Restore step_snaps (file-scope; persists across sections).
step_snaps=()

echo ""
echo "=== Dry-run In-Progress Annotation Tests ==="

# run_dry_run annotates in_progress steps inline (e.g., "RPM lockfile updates
# (in_progress)") to visually connect the upfront ⚠ warning to the numbered
# step — without the annotation, operators must mentally match step names across
# two separate blocks. Tests run under _AUTORELEASE_TESTING=true (fetch stubbed),
# so step_statuses is seeded directly.

VERSION="0.99.1"; RELEASE_TYPE="z-stream"; TRACKER="FAKE-123"

# in_progress step is annotated in the numbered list.
declare -A step_statuses=([rpmLockfiles]=in_progress)
dr10=$(run_dry_run 2>&1)
assert_contains "dry-run: in_progress step annotated in numbered list" \
  "$dr10" "RPM lockfile updates (in_progress)"

# A non-in_progress step (fresh / no status) has no annotation.
declare -A step_statuses=()
dr10b=$(run_dry_run 2>&1)
assert_not_contains "dry-run: fresh step has no annotation" \
  "$dr10b" "RPM lockfile updates (in_progress)"

echo ""
echo "=== auto_close_verdict Tests (item 9) ==="

# Provably shipped: bundle live AND every in-scope index lists the bundle.
assert_eq "shipped + all 7 indexes present -> close" \
  "$(auto_close_verdict shipped 7 7)" "close"

# Bundle live but an index still missing the bundle -> hold off.
assert_eq "shipped + partial indexes -> skip" \
  "$(auto_close_verdict shipped 7 6)" "skip"

# Bundle not confirmed live -> never close, even if indexes somehow matched.
assert_eq "not-shipped -> skip" \
  "$(auto_close_verdict not-shipped 7 7)" "skip"
assert_eq "unreachable bundle -> skip" \
  "$(auto_close_verdict unreachable 7 0)" "skip"

# Undeterminable scope (0 OCP versions) -> skip, never a vacuous close.
assert_eq "shipped + empty scope -> skip" \
  "$(auto_close_verdict shipped 0 0)" "skip"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ "$FAIL" -eq 0 ]; then echo "All $PASS tests passed"
else echo "$FAIL FAILED, $PASS passed"; fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
[ "$FAIL" -eq 0 ] || exit 1
