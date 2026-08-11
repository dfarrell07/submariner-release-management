#!/bin/bash
# Tracker-vs-reality drift detection for release-status.sh.
#
# The conductor's find_next_step skips any step the Jira tracker marks complete,
# forever, with no ground-truth re-check — so "tracker says complete but the
# commit was reverted / the release was never applied" is a silent footgun in a
# permanently hand-driven flow. This library flags that drift by comparing the
# tracker's per-step status against the ground-truth signals release-status.sh
# already computed (globals), re-probing NOTHING (Principle: don't duplicate
# release-status.sh). Only steps with an unambiguous signal are covered; every
# other step — and any step whose probe could not reach GitHub — is "unknown" so
# drift is never claimed on a guess. That last part matters: a probe FAILURE
# (offline / unauthenticated / rate-limited / transient flake) looks identical to
# "genuinely not done", so release-status.sh records a per-step *_FETCH_FAILED
# flag that forces "unknown" here instead of a false "tracker is stale" warning.
#
# Sourced by release-status.sh (reads its globals: IS_ZSTREAM, BRANCH_CHECK,
# BRANCH_FETCH_FAILED, MISSING_TEKTON, TEKTON_FETCH_FAILED, WRONG_COUNT,
# FETCH_FAILED, TAG_EXISTS, TAG_FETCH_FAILED) and by test-tracker-drift.sh
# (which sets those globals directly).

# Guard against double-sourcing.
[ -n "${_TRACKER_DRIFT_SOURCED:-}" ] && return 0
_TRACKER_DRIFT_SOURCED=1

# Jira status that means "complete". release-status.sh sources jira-tracker.sh
# first, which sets JIRA_STATUS_RESOLVED (readonly); the := below is a no-op then.
# Standalone (tests) it provides the same default so the lib is usable alone.
: "${JIRA_STATUS_RESOLVED:=Resolved}"

# Ground-truth done-ness for the tracker steps release-status.sh can confidently
# probe, read purely from globals it already populated (no re-probing).
# Echoes: "done" | "not-done" | "unknown". "unknown" => never compared, so drift
# is not claimed when the signal is stream-inapplicable or inconclusive.
#
# Deliberately excluded (would risk false drift, so left "unknown"):
#   - componentProd/fbc*: a missing prod bundle and an unreachable registry both
#     make skopeo exit non-zero — indistinguishable, so "absent" can't be trusted.
#     Item #9 (shipped-gate) owns the registry probe with that caveat in mind.
#   - configureDownstream: the no-cluster fallback reports "configured in repo
#     (cluster status unknown)" — not a clean done/not-done signal.
#   - versionLabels on Y-stream: release-status.sh only probes labels on Z-stream
#     (step 5b), so Y-stream label drift is not checkable here.
ground_truth_done() {
  case "$1" in
    createBranches)
      [ "${IS_ZSTREAM:-false}" = "true" ] && { echo unknown; return; }
      [ "${BRANCH_FETCH_FAILED:-0}" -gt 0 ] && { echo unknown; return; }  # couldn't reach GitHub
      [ "${BRANCH_CHECK:-}" = "all" ] && echo "done" || echo "not-done" ;;
    tektonComponents)
      [ "${IS_ZSTREAM:-false}" = "true" ] && { echo unknown; return; }
      [ "${TEKTON_FETCH_FAILED:-0}" -gt 0 ] && { echo unknown; return; }  # non-404 probe error
      [ "${MISSING_TEKTON:-0}" -eq 0 ] && echo "done" || echo "not-done" ;;
    versionLabels)
      [ "${IS_ZSTREAM:-false}" = "false" ] && { echo unknown; return; }
      [ "${WRONG_COUNT:-0}" -gt 0 ] && { echo not-done; return; }  # proven incomplete
      [ "${FETCH_FAILED:-0}" -gt 0 ] && { echo unknown; return; }  # can't prove done
      echo "done" ;;
    upstreamRelease)
      [ "${TAG_FETCH_FAILED:-0}" -gt 0 ] && { echo unknown; return; }  # couldn't reach GitHub
      [ -n "${TAG_EXISTS:-}" ] && echo "done" || echo "not-done" ;;
    *) echo unknown ;;
  esac
}

# Pure drift classification (no I/O, unit-tested offline).
# Args: $1=tracker_complete ("true"|"false"), $2=ground_truth (done|not-done|unknown)
# Echoes: "tracker-ahead" | "reality-ahead" | "ok" | "skip"
#   tracker-ahead: tracker says complete, ground truth says NOT done (the footgun)
#   reality-ahead: ground truth done, tracker not marked complete (self-healing)
classify_drift() {
  local tracker_complete="$1" gt="$2"
  [ "$gt" = "unknown" ] && { echo skip; return; }
  if [ "$tracker_complete" = "true" ]; then
    [ "$gt" = "not-done" ] && echo tracker-ahead || echo ok
  else
    [ "$gt" = "done" ] && echo reality-ahead || echo ok
  fi
}

# Print a drift section from a get_release_summary JSON blob (reuse the one the
# summary already fetched — no extra Jira query). Ground truth comes from globals
# via ground_truth_done. Prints nothing and returns 1 when there is no drift.
print_tracker_drift() {
  local summary="$1"
  [ -z "$summary" ] || [ "$summary" = "{}" ] && return 1

  local -a ahead=() behind=()
  local key title jira_status tracker_complete gt verdict
  # Only these keys have a checkable ground-truth signal (see ground_truth_done).
  for key in createBranches tektonComponents versionLabels upstreamRelease; do
    # Skip steps this release's tracker doesn't track (absent => empty title).
    title=$(printf '%s' "$summary" | jq -r --arg k "$key" '.steps[$k].title // empty' 2>/dev/null) || true
    [ -z "$title" ] && continue
    jira_status=$(printf '%s' "$summary" | jq -r --arg k "$key" '.steps[$k].jiraStatus // "Unknown"' 2>/dev/null) || true

    tracker_complete=false
    [ "$jira_status" = "$JIRA_STATUS_RESOLVED" ] && tracker_complete=true

    gt=$(ground_truth_done "$key")
    verdict=$(classify_drift "$tracker_complete" "$gt")
    case "$verdict" in
      tracker-ahead) ahead+=("$title") ;;
      reality-ahead) behind+=("$title") ;;
    esac
  done

  [ "${#ahead[@]}" -eq 0 ] && [ "${#behind[@]}" -eq 0 ] && return 1

  local list
  if [ "${#ahead[@]}" -gt 0 ]; then
    list=$(printf '%s; ' "${ahead[@]}"); list=${list%; }
    echo "⚠️  Tracker drift — marked complete but ground truth says NOT done: $list"
    echo "   ⮕ Re-verify these; the tracker may be stale (reverted commit / never applied)."
  fi
  if [ "${#behind[@]}" -gt 0 ]; then
    list=$(printf '%s; ' "${behind[@]}"); list=${list%; }
    echo "ℹ️  Tracker drift — done on ground truth but not marked complete: $list"
  fi
  return 0
}
