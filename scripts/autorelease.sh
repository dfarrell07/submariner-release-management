#!/bin/bash
# Autorelease conductor: find the next ready release step and run it
#
# Usage: autorelease.sh <version> [--complete STEP | --refresh STEP | --close]
#
# <version> may be a full patch (0.25.1) or a 2-segment stream (0.25), which is
# auto-resolved to the target patch version. Walks the release dependency graph,
# finds the first step that is ready (all deps complete, step not done), and
# either runs it or prints guidance. Chains consecutive auto steps. Stops at
# gate, review, hint, or manual steps.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GIT_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel 2>/dev/null || echo "")"
# Capture the lib dir before sourcing: each lib resets SCRIPT_DIR to its OWN
# location, so reusing SCRIPT_DIR for later source lines would resolve to lib/lib.
_LIB_DIR="$SCRIPT_DIR/lib"
# shellcheck source=lib/jira-tracker.sh
source "$_LIB_DIR/jira-tracker.sh"
# Registry-only shipped signals for auto-close (no cluster login): prod bundle
# tag check + operator-index bundle content check, and the per-release OCP scope.
# shellcheck source=lib/prod-bundle.sh
source "$_LIB_DIR/prod-bundle.sh"
# shellcheck source=lib/fbc-scope.sh
source "$_LIB_DIR/fbc-scope.sh"

usage() {
  echo "Usage: $0 <version> [--complete STEP | --refresh STEP | --close]"
  echo "  Run ready release steps, chaining consecutive auto steps"
  echo "  Stops at gate, hint, review, or manual steps"
  echo ""
  echo "Options:"
  echo "  --dry-run         Preview what would run next and what it would write,"
  echo "                    without executing or writing anything (read-only)"
  echo "  --complete STEP   Mark STEP as complete (skip the conductor loop)"
  echo "  --refresh STEP    Reset STEP to in_progress (re-run on next invocation)"
  echo "  --close           Mark the release done: resolve the tracker and its"
  echo "                    subtasks. Run only after confirming the prod releases"
  echo "                    shipped — the conductor can't verify that itself"
  echo ""
  echo "Example: $0 0.25.1"
  echo "         $0 0.25     # auto-detects the target patch version"
  echo "         $0 0.25.1 --complete cveFixes"
  echo "         $0 0.25.1 --refresh bundleShas"
  echo "         $0 0.25.1 --dry-run  # preview the chain, run/write nothing"
  echo "         $0 0.25.1 --close    # after the release has shipped"
}

# Resolve a 2-segment version (0.24) to a specific patch version.
# Strategy: 1) Jira tracker, 2) downstream in-progress, 3) latest released
#           (downstream prod YAMLs + upstream GitHub Releases), 4) default .0
# Output: "version:source" where source is tracker, in-progress, upstream, released, or default.
_resolve_version() {
  local major_minor="$1"

  # Strategy 1: latest tracked patch in Jira (status filter excludes resolved)
  local tracker_result
  tracker_result=$(query_jira --jql "project = ACM AND labels = release-tracking AND labels = submariner AND issuetype = Task AND status != Resolved" --fields "key,summary" 2>/dev/null) || tracker_result=""

  if [ -n "$tracker_result" ]; then
    local tracked
    tracked=$(echo "$tracker_result" | jq -r --arg mm "$major_minor" '
      [.[] | .fields.summary // "" |
       select(startswith("Release Submariner " + $mm + ".")) |
       capture("Release Submariner (?<ver>[0-9]+\\.[0-9]+\\.[0-9]+)") |
       .ver] |
      sort_by(split(".") | map(tonumber)) |
      last // empty
    ' 2>/dev/null || true)

    if [ -n "$tracked" ]; then
      echo "${tracked}:tracker"
      return 0
    fi
  fi

  # Strategy 2: downstream in-progress (stage YAML exists, no matching prod)
  local ds_result
  ds_result=$(_latest_downstream_version "$major_minor")
  if [ -n "$ds_result" ]; then
    local ds_ver="${ds_result%%:*}"
    local ds_state="${ds_result#*:}"
    if [ "$ds_state" = "in-progress" ]; then
      echo "${ds_ver}:in-progress"
      return 0
    fi
  fi

  # Strategy 3: latest released (downstream prod vs upstream GitHub Releases)
  local ds_prod=""
  [ -n "$ds_result" ] && ds_prod="${ds_result%%:*}"

  local upstream
  upstream=$(_latest_upstream_release "$major_minor")

  if [ -z "$ds_prod" ] && [ -z "$upstream" ]; then
    echo "${major_minor}.0:default"
    return 0
  fi

  local latest
  if [ -z "$ds_prod" ]; then
    latest="$upstream"
  elif [ -z "$upstream" ]; then
    latest="$ds_prod"
  else
    latest=$(printf '%s\n%s\n' "$ds_prod" "$upstream" | sort -V | tail -1)
  fi

  # upstream > ds_prod: a GitHub release exists that hasn't shipped through Konflux yet — target it.
  # Otherwise: latest shipped, so bump to the next patch as the new target.
  if [ -n "$upstream" ] && [ "$upstream" != "$ds_prod" ] && [ "$latest" = "$upstream" ]; then
    echo "${upstream}:upstream"
    return 0
  fi

  local patch="${latest##*.}"
  local next=$((patch + 1))
  echo "${major_minor}.${next}:released"
}

_latest_downstream_version() {
  local mm="$1"
  local stage_vers prod_vers
  stage_vers=$(find "$GIT_ROOT/releases/$mm/stage/" -maxdepth 1 \
    -name "submariner-*-stage-*.yaml" -type f 2>/dev/null | \
    sed -nE 's/.*submariner-([0-9]+-[0-9]+-[0-9]+)-stage-.*/\1/p' | \
    tr '-' '.' | sort -V -u) || true
  prod_vers=$(find "$GIT_ROOT/releases/$mm/prod/" -maxdepth 1 \
    -name "submariner-*-prod-*.yaml" -type f 2>/dev/null | \
    sed -nE 's/.*submariner-([0-9]+-[0-9]+-[0-9]+)-prod-.*/\1/p' | \
    tr '-' '.' | sort -V -u) || true

  [ -z "$stage_vers" ] && [ -z "$prod_vers" ] && return 0

  local latest_stage
  latest_stage=$(echo "$stage_vers" | tail -1)
  if [ -n "$latest_stage" ] && ! echo "$prod_vers" | grep -qxF "$latest_stage"; then
    echo "${latest_stage}:in-progress"
    return 0
  fi

  local latest_prod
  latest_prod=$(echo "$prod_vers" | tail -1)
  [ -n "$latest_prod" ] && echo "${latest_prod}:complete"
}

_latest_upstream_release() {
  local mm="$1"
  local version
  version=$(timeout 30 gh api --paginate "repos/submariner-io/releases/releases" \
    --jq ".[] | select(.prerelease == false and .draft == false) | .tag_name | select(startswith(\"v${mm}.\"))" \
    2>/dev/null | sed 's/^v//' | sort -V | tail -1) || return 0
  if echo "$version" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "$version"
  fi
}

# --- Core logic: find_next_step ---
# Sets globals: NEXT_STEP, NEXT_REASON.
# Uses globals: step_statuses (associative array, pre-populated by caller or fetched here).
NEXT_STEP=""
NEXT_REASON=""

# step_statuses is populated by find_next_step (fetched from Jira) or seeded by
# the caller (tests, run_dry_run). Declared -A at file scope — OUTSIDE the main
# _AUTORELEASE_TESTING guard — because run_dry_run dispatches from the one-shot
# block (before the main loop's own `declare -A`) and writes string keys into it;
# under `set -u` a string subscript on an array never declared -A would
# arithmetic-evaluate an unset key and abort. Tests seed it before every walk.
declare -A step_statuses=()
# Per-step snapshot cache (populated alongside step_statuses from all_comments).
# Enables inline staleness checks in the complete arm without extra Jira fetches.
declare -A step_snaps=()
# Per-step timestamp cache (populated alongside step_statuses from all_comments).
# Enables inline time-based staleness checks in the complete arm.
declare -A step_timestamps=()

find_next_step() {
  # version/release_type/tracker are all used below (error hints, step_applies_to_release,
  # and the acli fetch key respectively) — no suppression needed.
  local version="$1"
  local release_type="$2"
  local tracker="$3"

  # Safety: jq -e 'type=="array"' rejects null/object returns from acli
  # (jq empty would accept them), preventing re-dispatch from step 1 on
  # partial reads, rate-limits, or auth failures.
  # Skip entirely under _AUTORELEASE_TESTING/NOFETCH — seeded state must not be wiped.
  if [ "${_AUTORELEASE_TESTING:-}" != "true" ] && [ "${_AUTORELEASE_NOFETCH:-}" != "1" ]; then
    local all_comments fetch_rc=0
    all_comments=$(_fetch_tracker_comments "$tracker") || fetch_rc=$?
    if [ "$fetch_rc" -ne 0 ]; then
      echo "" >&2
      echo "❌ Could not read tracker state from Jira (acli exit $fetch_rc)" >&2
      echo "   Refusing to proceed — re-running steps from an empty read is unsafe." >&2
      echo "   Check Jira auth/network, then re-run: /autorelease $version" >&2
      exit 1
    fi

    if [ -z "$all_comments" ] || ! printf '%s' "$all_comments" | jq -e 'type=="array"' >/dev/null 2>&1; then
      echo "" >&2
      echo "❌ Tracker read from Jira was empty or not a JSON array" >&2
      echo "   Refusing to proceed — re-running steps from a bad read is unsafe." >&2
      echo "   Check Jira auth/network, then re-run: /autorelease $version" >&2
      exit 1
    fi

    # MUST stay inside the fetch guard: NOFETCH/dry-run relies on the preserved
    # in-memory array to advance the sim across re-walks.
    step_statuses=()
    step_snaps=()
    while IFS=$'\t' read -r skey sstatus ssnap ststamp; do
      [ -n "$skey" ] || continue
      step_statuses[$skey]="$sstatus"
      [ -n "$ssnap" ] && step_snaps[$skey]="$ssnap"
      [ -n "$ststamp" ] && step_timestamps[$skey]="$ststamp"
    done < <(printf '%s' "$all_comments" | jq -r '
      [.[] | .body // empty |
       capture("```STEP_DATA\\n(?<json>\\{[^`]+)\\n```"; "g") // empty |
       .json] |
      map(fromjson? // empty) |
      map(select(._t == "STEP_DATA")) |
      group_by(.step) | map(last) |
      .[] | [.step, .status, (.data.snapshot // ""), (.timestamp // "")] | @tsv
    ' 2>/dev/null)
  fi

  for step in "${STEP_ORDER[@]}"; do
    step_applies_to_release "$step" "$release_type" || continue

    local status="${step_statuses[$step]:-}"

    if [ "$status" = "complete" ]; then
      [ "${_AUTORELEASE_QUIET:-}" != "true" ] && echo "  ✓ ${STEP_TITLES[$step]:-$step}: done" >&2
      # Advisory snapshot-staleness check (uses cached step_snaps — no extra
      # Jira fetch). If bundleShas recorded a newer snapshot since this step
      # completed, warn so the operator knows to --refresh before proceeding.
      if [ "${_AUTORELEASE_QUIET:-}" != "true" ] && \
         [ "${STALENESS_RULES[$step]:-}" = "snapshot" ]; then
        local _step_snap="${step_snaps[$step]:-}"
        local _bundle_snap="${step_snaps[bundleShas]:-}"
        if [ -n "$_step_snap" ] && [ -n "$_bundle_snap" ] && \
           [ "$_step_snap" != "$_bundle_snap" ]; then
          echo "  ⚠ ${STEP_TITLES[$step]:-$step}: stale — snapshot changed since completion" >&2
          echo "    Consider: /autorelease $version --refresh $step" >&2
        fi
      fi
      # Advisory time-based staleness check (uses cached step_timestamps — no
      # extra Jira fetch). cveFixes and rpmLockfiles have a 3d rule; warn when
      # the step was completed more than that many days ago so the operator
      # knows to --refresh before proceeding.
      if [ "${_AUTORELEASE_QUIET:-}" != "true" ]; then
        local _rule="${STALENESS_RULES[$step]:-}"
        if [[ "$_rule" =~ ^[0-9]+d$ ]]; then
          local _ts="${step_timestamps[$step]:-}"
          if [ -n "$_ts" ]; then
            local _days="${_rule%d}"
            local _ep _now _age _max
            _ep=$(date -d "$_ts" +%s 2>/dev/null || echo 0)
            _now=$(date +%s 2>/dev/null || echo 0)
            _age=$((_now - _ep))
            _max=$((_days * 86400))
            if [ "$_age" -gt "$_max" ]; then
              local _age_d=$((_age / 86400))
              echo "  ⚠ ${STEP_TITLES[$step]:-$step}: stale — completed ${_age_d}d ago (limit: ${_days}d)" >&2
              echo "    Consider: /autorelease $version --refresh $step" >&2
            fi
          fi
        fi
      fi
      continue
    fi

    # Check if all deps are satisfied
    local deps="${STEP_DEPENDENCIES[$step]:-}"
    local all_deps_met=true
    if [ -n "$deps" ]; then
      IFS=',' read -ra dep_arr <<< "$deps"
      for dep in "${dep_arr[@]}"; do
        [ -z "$dep" ] && continue
        step_applies_to_release "$dep" "$release_type" || continue
        local dep_status="${step_statuses[$dep]:-}"
        if [ "$dep_status" != "complete" ]; then
          all_deps_met=false
          break
        fi
      done
    fi

    if [ "$all_deps_met" = "false" ]; then
      continue
    fi

    # Found the next ready step
    NEXT_STEP="$step"
    local level="${AUTOMATION_LEVEL[$step]:-auto}"
    local script="${STEP_SCRIPT[$step]:-}"
    local hint="${STEP_SKILL_HINT[$step]:-}"

    if [ "$level" = "gate" ]; then
      NEXT_REASON="gate"
    elif [ -n "$script" ]; then
      NEXT_REASON="run"
    elif [ -n "$hint" ]; then
      NEXT_REASON="hint"
    else
      NEXT_REASON="manual"
    fi
    return 0
  done

  NEXT_STEP=""
  NEXT_REASON="all_done"
  return 0
}

# --- Step override: --complete / --refresh ---
# Callable from tests (outside the _AUTORELEASE_TESTING guard).
handle_step_override() {
  local version="$1"
  local step_key="$2"
  local action="$3"   # "complete" or "in_progress"
  local tracker="$4"

  if [ -z "$step_key" ]; then
    echo "ERROR: Step key must not be empty" >&2
    return 1
  fi

  # Validate step_key exists in STEP_TITLES
  if [ -z "${STEP_TITLES[$step_key]+_}" ]; then
    echo "ERROR: Unknown step key '$step_key'" >&2
    echo "Valid step keys:" >&2
    for k in "${STEP_ORDER[@]}"; do
      echo "  $k  (${STEP_TITLES[$k]})" >&2
    done
    return 1
  fi

  # Snapshot-staleness steps completed by hand (e.g. qeValidation via --complete)
  # must record the bundleShas snapshot they signed off against, or their
  # STALENESS_RULES entry is dead (an empty .data.snapshot always reads "fresh").
  local data="{}"
  if [ "$action" = "complete" ] && [ "${STALENESS_RULES[$step_key]:-}" = "snapshot" ]; then
    data=$(snapshot_step_data "$version" "$tracker")
  fi

  update_step "$version" "$step_key" "$action" "$data" "$tracker"
  echo "Step '$step_key' marked as $action for $version (tracker: $tracker)" >&2

  return 0
}

# --- Mark a finished release's tracker done (resolve parent + subtasks) ---
# Explicit, human-invoked (--close). The manual fallback for auto-close: a
# deliberate human action — same principle as apply/push — for when the operator
# knows the release shipped but the registry probes can't confirm it (auth/network
# gaps, or a scope the date-window heuristic can't resolve).
handle_close() {
  local version="$1"

  echo "" >&2
  close_release_tracker "$version" "Release $version complete"
  return 0
}

# --- Auto-close: resolve the tracker IFF the release provably shipped ---
# Pure verdict (no I/O, unit-tested): close only when the component bundle is
# confirmed live AND we resolved a non-empty OCP scope AND every scoped operator
# index lists the bundle. Any shortfall -> skip, the safe direction: a false
# "skip" just leaves the tracker for manual --close, whereas a false "close"
# would wrongly resolve an unshipped release.
# Args: $1 bundle_verdict (shipped|...), $2 scope_count, $3 present_count.
# Echoes: close | skip
auto_close_verdict() {
  local bundle_verdict="$1" scope_count="$2" present_count="$3"
  if [ "$bundle_verdict" = shipped ] && [ "$scope_count" -gt 0 ] && [ "$present_count" -eq "$scope_count" ]; then
    echo close
  else
    echo skip
  fi
}

# I/O wrapper (item 9): at a successful release end, resolve the tracker IFF the
# release is provably live in production. Registry-only, no cluster login:
#   1. prod_bundle_shipped   — component prod bundle live (skopeo; cheap gate)
#   2. get_fbc_ocp_scope     — which OCP versions THIS release targeted (files)
#   3. prod_index_has_bundle — every in-scope operator index lists bundle-vX.Y.Z
#      (oc image extract; the user-facing "installable via OperatorHub" signal)
# Probe-failure != absence: any unknown (missing tools, unreachable registry, an
# index not yet carrying the bundle) -> hold off and leave --close to the human.
# The expensive per-index probes run only after the cheap bundle gate passes.
# Prints its evidence to stderr. Returns 0 if it closed the tracker, 1 otherwise
# (caller then prints the standard terminal summary). Uses globals GIT_ROOT,
# FBC_OCP_VERSIONS, and (via close_release_tracker) the Jira helpers. Defined
# outside the _AUTORELEASE_TESTING guard so tests can drive auto_close_verdict.
try_auto_close() {
  local version="$1"

  # Need the probe tools; without them we can't confirm shipped, so hold off.
  local missing=()
  command -v skopeo >/dev/null 2>&1 || missing+=(skopeo)
  command -v jq >/dev/null 2>&1 || missing+=(jq)
  command -v oc >/dev/null 2>&1 || missing+=(oc)
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "" >&2
    echo "ℹ️  Auto-close skipped: need ${missing[*]} to verify the release shipped." >&2
    echo "    Once shipped, close manually: /autorelease $version --close" >&2
    return 1
  fi

  # Cheap gate first: is the component prod bundle live? (sets PROD_BUNDLE_*)
  prod_bundle_shipped "$version"
  if [ "$PROD_BUNDLE_VERDICT" != shipped ]; then
    echo "" >&2
    case "$PROD_BUNDLE_VERDICT" in
      not-shipped) echo "ℹ️  Auto-close skipped: prod bundle for $version not live in the registry yet." >&2 ;;
      *)           echo "ℹ️  Auto-close skipped: could not reach the prod bundle registry to verify $version." >&2 ;;
    esac
    echo "    Once shipped, close manually: /autorelease $version --close" >&2
    return 1
  fi

  # Which OCP versions did THIS release target? (date-window match, files only)
  local mm="${version%.*}" dash="${version//./-}" scope
  scope=$(get_fbc_ocp_scope "$GIT_ROOT" "$mm" "$dash" prod "$FBC_OCP_VERSIONS")
  if [ -z "$scope" ]; then
    echo "" >&2
    echo "ℹ️  Auto-close skipped: could not determine $version's OCP scope from releases/fbc/*/prod." >&2
    echo "    Once shipped, close manually: /autorelease $version --close" >&2
    return 1
  fi

  # Every in-scope operator index must list bundle-v$version before we close.
  local ocp verdict present=() pending=()
  for ocp in $scope; do
    verdict=$(prod_index_has_bundle "$ocp" "$version")
    case "$verdict" in
      present) present+=("4.$ocp") ;;
      *)       pending+=("4.$ocp($verdict)") ;;
    esac
  done

  local scope_count present_count
  scope_count=$(echo "$scope" | wc -w)
  present_count=${#present[@]}

  if [ "$(auto_close_verdict "$PROD_BUNDLE_VERDICT" "$scope_count" "$present_count")" != close ]; then
    echo "" >&2
    echo "ℹ️  Auto-close skipped: bundle-v$version is not yet in every in-scope prod index." >&2
    echo "    Present: ${present[*]:-none}" >&2
    echo "    Pending: ${pending[*]:-none}" >&2
    if printf '%s' "${pending[*]:-}" | grep -q '(unreachable)'; then
      echo "    ⚠ Some indexes were unreachable (network/auth) — check oc login and" >&2
      echo "      pull-secret before re-running." >&2
    fi
    echo "    Re-run later, or close manually once shipped: /autorelease $version --close" >&2
    return 1
  fi

  # Provably shipped: resolve the tracker (parent + subtasks), mirroring --close.
  echo "" >&2
  echo "✅ $version is live in production:" >&2
  echo "    Component bundle: ${PROD_BUNDLE_TAG} (${PROD_BUNDLE_DIGEST:7:12})" >&2
  echo "    Operator indexes: ${present[*]}" >&2
  echo "" >&2
  close_release_tracker "$version" "Release $version shipped (bundle live; in prod operator indexes for OCP ${present[*]})"
  return 0
}

# --- Auto-verify a gate/hint step and chain past it if it already happened ---
# Returns 0 if the step was externally verified and marked complete (caller
# should `continue` the walk); 1 if not (caller stops or handles terminals).
# Reads/sets the `verified_steps` guard so each step is auto-verified at most
# once per run — this is what stops the walk from looping forever on a step
# whose verifier keeps failing. Uses globals VERSION, TRACKER, verified_steps,
# STEP_VERIFIER, STEP_TITLES. Callable from tests (outside the
# _AUTORELEASE_TESTING guard).
try_auto_verify() {
  local step="$1"
  local verifier="${STEP_VERIFIER[$step]:-}"
  [ -n "$verifier" ] || return 1
  [ -n "${verified_steps[$step]:-}" ] && return 1
  verified_steps[$step]=1

  # Verifiers print the evidence they checked (snapshot/tag/bundle) on stdout;
  # record it as STEP_DATA so snapshot-staleness rules and the tracker see what
  # was verified, falling back to "{}" if empty. TRACKER is passed for verifiers
  # that cross-check the tracker (verify_ecFixes verifies EC on the recorded
  # bundleShas snapshot); others ignore it.
  #
  # Exit-code contract:
  #   0  — step verified complete; caller should `continue` the walk
  #   1  — step not yet complete (no evidence of work); caller runs script or stops
  #   2  — precondition failure (no oc, no network, missing repo); cannot tell
  #          whether step is done — caller should surface a diagnostic and stop
  #   3  — work in progress (PRs open, not merged); caller should wait, not re-run
  local vdata="" verify_rc=0
  vdata=$("$verifier" "$VERSION" "$TRACKER") || verify_rc=$?
  if [ "$verify_rc" -eq 2 ]; then
    return 2
  fi
  if [ "$verify_rc" -eq 3 ]; then
    # Work in progress (PRs open). vdata contains the Jira comment text emitted
    # by the verifier on stdout (subshell, so _add_comment wasn't available there).
    # Only post if the open PR set has changed since the last run (dedup via
    # local cache file — avoids an extra Jira write just to store the hash).
    if [ -n "$vdata" ] && [ -n "$TRACKER" ]; then
      local new_hash
      new_hash=$(printf '%s' "$vdata" | md5sum | cut -d' ' -f1)
      local cache_file="${GIT_ROOT}/.git/autorelease-pr-hash-${step}"
      local cached_hash=""
      [ -f "$cache_file" ] && cached_hash=$(cat "$cache_file")
      if [ "$new_hash" != "$cached_hash" ]; then
        _add_comment "$TRACKER" "$vdata" || true
        printf '%s' "$new_hash" > "$cache_file"
        update_subtask_description "$VERSION" "$step" \
          "$(printf '## PRs\n\n%s\n\n## Status\n\nPRs open — waiting for merge and Konflux rebuild.' "$vdata")" \
          "$TRACKER" || true
      fi
    fi
    return 3
  fi
  if [ "$verify_rc" -eq 0 ]; then
    echo "  ✓ ${STEP_TITLES[$step]:-$step}: verified externally" >&2
    # PR-merge verifiers emit Jira comment text on stdout (not JSON) so they can
    # run in this subshell context. Post the comment now, then record "{}" as the
    # tracker data (PR URLs already in the Jira comment; JSON tracker data is
    # secondary). Other verifiers (createBranches, upstreamRelease, ecFixes,
    # fbcProdUrls) emit JSON — detect by attempting jq parse.
    if [ -n "$vdata" ] && [ -n "$TRACKER" ]; then
      if ! printf '%s' "$vdata" | jq -e . >/dev/null 2>&1; then
        _add_comment "$TRACKER" "$vdata" || true
        update_subtask_description "$VERSION" "$step" \
          "$(printf '## PRs\n\n%s\n\n## Status\n\nAll PRs merged ✓' "$vdata")" \
          "$TRACKER" || true
        vdata="{}"
      fi
    fi
    [ -n "$vdata" ] || vdata="{}"
    update_step "$VERSION" "$step" "complete" "$vdata" "$TRACKER"
    _AUTORELEASE_QUIET=true
    return 0
  fi
  return 1
}

# --- Step verifiers: detect completion from external state ---
# Returns 0 if the step is verified complete, 1 otherwise.
# Callable from tests (outside the _AUTORELEASE_TESTING guard).

readonly SUBMARINER_UPSTREAM_REPOS="submariner-operator submariner lighthouse shipyard subctl admiral cloud-prepare"

# Thin wrapper around `git ls-remote` with a hard 30-second timeout to prevent
# firewall-silent TCP drops from stalling the conductor indefinitely.  Tests
# override this function to inject mock output without touching the PATH.
_git_ls_remote() { timeout 30 git ls-remote "$@"; }

verify_createBranches() {
  local major_minor="${1%.*}"
  local operator_sha=""
  for repo in $SUBMARINER_UPSTREAM_REPOS; do
    local ls_out ref ls_rc=0
    ls_out=$(_git_ls_remote --heads "https://github.com/submariner-io/$repo" "refs/heads/release-$major_minor" 2>/dev/null) || ls_rc=$?
    if [ "$ls_rc" -ne 0 ]; then
      echo "  ls-remote failed (exit $ls_rc) — network, rate-limit, or timeout issue for submariner-io/$repo" >&2
      return 2
    fi
    ref=$(echo "$ls_out" | grep -o "refs/heads/release-$major_minor" || true)
    if [ -z "$ref" ]; then
      echo "  could not confirm refs/heads/release-$major_minor on submariner-io/$repo — re-run to retry" >&2
      return 1
    fi
    [ "$repo" = "submariner-operator" ] && operator_sha=$(echo "$ls_out" | awk 'NR==1{print $1}')
  done
  # Record the branch and the operator-repo head so the tracker shows what was seen.
  jq -cn --arg branch "release-$major_minor" --arg sha "$operator_sha" '{branch:$branch,operatorSha:$sha}'
  return 0
}

verify_upstreamRelease() {
  local version="$1"
  # Check only the 5 repos that receive v$VERSION tags per cut-upstream-release.md:
  # submariner-operator (checked separately in step 3 of the workflow), plus the 4
  # repos verified in step 4 of the workflow.  Excludes admiral and cloud-prepare
  # (library repos present in SUBMARINER_UPSTREAM_REPOS that do not produce
  # deliverable images) and submariner-charts (an installer/charts repo).
  local component_repos="submariner-operator submariner lighthouse shipyard subctl"
  local operator_sha=""
  for repo in $component_repos; do
    local ls_out ls_rc=0
    ls_out=$(_git_ls_remote --tags "https://github.com/submariner-io/$repo" "refs/tags/v$version" 2>/dev/null) || ls_rc=$?
    if [ "$ls_rc" -ne 0 ]; then
      echo "  ls-remote failed (exit $ls_rc) — network, rate-limit, or timeout issue for submariner-io/$repo" >&2
      return 2
    fi
    if ! echo "$ls_out" | grep -q "refs/tags/v$version"; then
      echo "  v$version tag not found on submariner-io/$repo" >&2
      return 1
    fi
    [ "$repo" = "submariner-operator" ] && operator_sha=$(echo "$ls_out" | awk 'NR==1{print $1}')
  done
  jq -cn --arg tag "v$version" --arg sha "$operator_sha" '{tag:$tag,operatorSha:$sha}'
}

# Extract EC test status from a single snapshot object (stdin).
# Returns "TestPassed", "TestFailed", "no-ec-result", or "parse-error".
_ec_status_from_snap() {
  jq -r '.metadata.annotations["test.appstudio.openshift.io/status"] // "[]" | fromjson |
    [.[] | select(.scenario | contains("enterprise-contract"))][0] | .status // "no-ec-result"' \
    2>/dev/null || echo "parse-error"
}

verify_ecFixes() {
  local version="$1"
  local tracker="${2:-}"
  local dash_mm="${version%.*}"
  dash_mm="${dash_mm//./-}"

  # If fix-tekton-tasks-<mm> PRs are open in any repo, the Konflux rebuild
  # hasn't happened yet — return rc=3 (PRs open) so the conductor waits
  # instead of re-running the script unnecessarily.  We reuse _verify_prs_merged
  # (same branch + repos as verify_tektonTasks) but only act on the "open"
  # signal; if it returns 0 (all merged) or 1 (no PRs), fall through to EC check.
  if command -v gh &>/dev/null; then
    local _pr_rc=0 _pr_out=""
    # Capture stdout: _verify_prs_merged emits PR URLs on stdout which would
    # corrupt verify_ecFixes's own stdout (JSON returned to try_auto_verify).
    # Re-emit only on rc=3 so try_auto_verify can post the open URLs to Jira.
    _pr_out=$(_verify_prs_merged "$version" "" "fix-tekton-tasks-${version%.*}" \
      "submariner-io/submariner-operator submariner-io/submariner submariner-io/lighthouse submariner-io/shipyard submariner-io/subctl stolostron/submariner-operator-fbc" \
      2>/dev/null) || _pr_rc=$?
    if [ "$_pr_rc" -eq 3 ]; then
      printf '%s' "$_pr_out"
      return 3
    fi
  fi

  if ! command -v oc &>/dev/null; then
    echo "  oc not installed — install OpenShift CLI first" >&2
    return 2
  fi
  if ! oc whoami &>/dev/null 2>&1; then
    echo "  Not logged in — run: oc login --web https://api.kflux-prd-rh02.0fk9.p1.openshiftapps.com:6443/" >&2
    return 2
  fi
  local snaps snap_name oc_snaps_rc=0
  snaps=$(oc get snapshots -n submariner-tenant --sort-by=.metadata.creationTimestamp -o json --request-timeout=60s 2>/dev/null) || oc_snaps_rc=$?
  if [ "$oc_snaps_rc" -ne 0 ]; then
    echo "  oc get snapshots failed (exit $oc_snaps_rc) — check context: $(oc config current-context 2>/dev/null || echo unknown)" >&2
    echo "  Expected namespace: submariner-tenant on kflux-prd-rh02" >&2
    return 2
  fi

  # If bundleShas has already chosen the component build we're shipping, verify EC
  # on THAT exact snapshot and record its name. This keeps the ecFixes
  # snapshot-staleness rule (compared against bundleShas) reconcilable: it reads
  # fresh iff EC passed on the snapshot actually being released, and re-verifying
  # after bundleShas advances lands on the new snapshot. Before bundleShas exists
  # (Step 4, the first pass), fall back to the latest main-branch EC-passing
  # snapshot purely as evidence.
  local target_snap=""
  if [ -n "$tracker" ]; then
    local bundleShas_data bundleShas_rc=0
    bundleShas_data=$(get_step "$version" "bundleShas" "$tracker" 2>/dev/null) || bundleShas_rc=$?
    # A FAILED tracker read must not fall through to the "latest snapshot"
    # branch — that would verify EC on, and record, a build other than the one
    # bundleShas anchors. Decline to auto-verify (return 1); the conductor stops
    # and the human re-runs once Jira is readable. A good read with no snapshot
    # yet (rc 0, empty) is the legitimate pre-bundleShas first pass → fall back.
    if [ "$bundleShas_rc" -ne 0 ]; then
      echo "verify_ecFixes: Jira read failed for bundleShas (rc $bundleShas_rc) — re-run once Jira is reachable" >&2
      return 1
    fi
    target_snap=$(printf '%s' "$bundleShas_data" | jq -r '.data.snapshot // empty' 2>/dev/null) || target_snap=""
  fi

  if [ -n "$target_snap" ]; then
    # Verify enterprise-contract passed on the specific bundleShas snapshot. Split
    # into two steps so a diagnostic can name the snapshot and its EC status on
    # failure (previously: silent return 1 left the operator querying oc manually).
    local snap_json ec_status_t
    snap_json=$(echo "$snaps" | jq --arg n "$target_snap" '
      [.items[] | select(.metadata.name == $n)] | last // null
    ' 2>/dev/null) || snap_json="null"
    if [ -z "$snap_json" ] || [ "$snap_json" = "null" ]; then
      echo "  Snapshot $target_snap (from bundleShas) not found on cluster" >&2
      return 1
    fi
    ec_status_t=$(printf '%s' "$snap_json" | _ec_status_from_snap)
    if [ "$ec_status_t" != "TestPassed" ]; then
      local ui_url="https://konflux-ui.apps.kflux-prd-rh02.0fk9.p1.openshiftapps.com/ns/submariner-tenant/applications/submariner-${dash_mm}/snapshots/${target_snap}"
      echo "ecFixes: bundleShas snapshot: $target_snap (ec: $ec_status_t)" >&2
      echo "  View EC failure details: $ui_url" >&2
      echo "  If Tekton task refs are already current, EC is failing for a different reason." >&2
      echo "  Investigate the EC log, fix the root cause, then re-run: /autorelease $version" >&2
      return 1
    fi
    snap_name="$target_snap"
  else
    # Find the latest main-branch (push/incoming/retest-all-comment) snapshot, then
    # check its EC status. Two-step split gives a precise failure message instead of
    # a silent return 1, which previously forced the operator to query oc manually.
    local latest_candidate ec_status_f
    latest_candidate=$(echo "$snaps" | jq -r --arg p "submariner-${dash_mm}-" '
      [.items[] | select(.metadata.name | startswith($p)) |
       select(.metadata.labels["pac.test.appstudio.openshift.io/event-type"] == "push" or
              .metadata.labels["pac.test.appstudio.openshift.io/event-type"] == "incoming" or
              .metadata.labels["pac.test.appstudio.openshift.io/event-type"] == "retest-all-comment")] |
      last | .metadata.name // empty
    ' 2>/dev/null) || latest_candidate=""
    if [ -z "$latest_candidate" ] || [ "$latest_candidate" = "null" ]; then
      echo "  No qualifying main-branch snapshot for prefix submariner-${dash_mm}-" >&2
      return 1
    fi
    local snap_obj_f
    snap_obj_f=$(echo "$snaps" | jq --arg n "$latest_candidate" \
      '[.items[] | select(.metadata.name == $n)] | last' 2>/dev/null) || snap_obj_f="null"
    ec_status_f=$(printf '%s' "$snap_obj_f" | _ec_status_from_snap)
    if [ "$ec_status_f" != "TestPassed" ]; then
      local ui_url_f="https://konflux-ui.apps.kflux-prd-rh02.0fk9.p1.openshiftapps.com/ns/submariner-tenant/applications/submariner-${dash_mm}/snapshots/${latest_candidate}"
      echo "ecFixes: Latest snapshot: $latest_candidate (ec: $ec_status_f)" >&2
      echo "  View EC failure details: $ui_url_f" >&2
      echo "  If Tekton task refs are already current, EC is failing for a different reason." >&2
      echo "  Investigate the EC log, fix the root cause, then re-run: /autorelease $version" >&2
      return 1
    fi
    snap_name="$latest_candidate"
  fi
  [ -n "$snap_name" ] && [ "$snap_name" != "null" ] || return 1
  jq -cn --arg snap "$snap_name" --arg ver "$version" '{snapshot:$snap,version:$ver}'
}

verify_fbcProdUrls() {
  local version="$1"
  # Use FBC_REPO env-var override when set (e.g. set in the environment or
  # injected by tests); otherwise fall back to FBC_REPO_DEFAULT which is
  # the canonical path defined once in lib/jira-tracker.sh (sourced above).
  local fbc_repo="${FBC_REPO:-$FBC_REPO_DEFAULT}"
  if [ ! -d "$fbc_repo" ]; then
    echo "  FBC repo not found at $fbc_repo — clone it first: git clone https://github.com/stolostron/submariner-operator-fbc $fbc_repo" >&2
    return 2
  fi
  local template="$fbc_repo/catalog-template.yaml"
  [ -f "$template" ] || return 1

  # Find the olm.bundle image for this version using grep-based detection.
  # Searches for "submariner.v<version>" as a name field (any indentation),
  # then grabs the image: line that immediately follows it. The "$" anchor
  # in the name pattern prevents "0.17.2" from matching "0.17.2-0.<ts>.p".
  # This is intentionally indent-agnostic so format tweaks don't break the check.
  local image_line
  image_line=$(grep -A1 "name: submariner\.v${version}$" "$template" \
    | grep "image:" | head -1)

  # No bundle entry for this version yet → step not done.
  if [ -z "$image_line" ]; then
    echo "  (verify_fbcProdUrls: no bundle entry found for submariner.v${version} in $template)" >&2
    return 1
  fi

  # Done once the temporary quay.io build URL has been replaced by the
  # permanent registry.redhat.io URL.
  if echo "$image_line" | grep -q "quay.io/redhat-user-workloads"; then
    echo "  (verify_fbcProdUrls: bundle image still has temp quay.io build URL — prod URL not yet applied)" >&2
    return 1
  fi
  if ! echo "$image_line" | grep -q "registry.redhat.io"; then
    echo "  (verify_fbcProdUrls: bundle image URL not from registry.redhat.io — unexpected registry)" >&2
    return 1
  fi

  # Record the resolved prod bundle image for tracker legibility.
  local bundle_image
  bundle_image=$(echo "$image_line" | awk '{print $NF}')
  jq -cn --arg img "$bundle_image" --arg ver "$version" '{bundleImage:$img,version:$ver}'
}

# --- PR-merge verifiers for review-level steps ---
# Each checks that all expected PRs on a fix branch are merged, posts the PR
# URLs to Jira as a comment, and returns JSON data for the tracker.
# Exit codes: 0=verified complete, 1=no PRs found (script hasn't run yet),
#             2=precondition failure, 3=PRs open but not merged yet (wait).

# _verify_prs_merged: shared helper used by tektonTasks/rpmLockfiles/versionLabels.
# Args: $1=version $2=tracker $3=branch_name $4=space-separated "org/repo" list
# Stdout: JSON {prs:[...]} on success. Stderr: human-readable status.
_verify_prs_merged() {
  local version="$1"
  local tracker="$2"
  local branch="$3"
  local repos="$4"

  if ! command -v gh &>/dev/null; then
    echo "  gh not installed" >&2; return 2
  fi

  local all_merged=true
  local any_open=false
  local merged_urls=()
  local open_urls=()

  for repo in $repos; do
    local pr_json pr_rc=0
    pr_json=$(gh pr list --repo "$repo" --head "$branch" --state all \
      --json number,state,mergedAt,url --limit 5 2>/dev/null) || pr_rc=$?
    if [ "$pr_rc" -ne 0 ]; then
      echo "  gh pr list failed for $repo (exit $pr_rc) — network or auth issue" >&2
      return 2
    fi

    local merged_url
    merged_url=$(printf '%s' "$pr_json" | \
      jq -r '[.[] | select(.state=="MERGED")] | sort_by(.mergedAt) | last | .url // empty' \
      2>/dev/null) || merged_url=""

    if [ -n "$merged_url" ]; then
      merged_urls+=("$merged_url")
    else
      local open_url
      open_url=$(printf '%s' "$pr_json" | \
        jq -r '[.[] | select(.state=="OPEN")] | last | .url // empty' 2>/dev/null) || open_url=""
      if [ -n "$open_url" ]; then
        echo "  PR open, not yet merged: $open_url" >&2
        open_urls+=("$open_url")
        any_open=true
      else
        echo "  No PR found on $repo (branch: $branch)" >&2
      fi
      all_merged=false
    fi
  done

  if ! $all_merged; then
    if $any_open; then
      # Emit open (and any already-merged) URLs on stdout so the caller can
      # post them to Jira. _add_comment cannot be called here because this
      # function runs inside a $() subshell in try_auto_verify, where shell
      # functions from the parent are not available.
      local open_list merged_list=""
      open_list=$(printf '%s\n' "${open_urls[@]}")
      [ "${#merged_urls[@]}" -gt 0 ] && merged_list=$(printf '%s\n' "${merged_urls[@]}")
      if [ -n "$merged_list" ]; then
        printf 'PRs proposed for %s (some still open):\nOpen:\n%s\nMerged:\n%s' \
          "$branch" "$open_list" "$merged_list"
      else
        printf 'PRs proposed for %s:\n%s' "$branch" "$open_list"
      fi
      return 3
    fi
    return 1
  fi

  # All merged — emit comment text on stdout for try_auto_verify to post to Jira.
  # Tracker data recorded as '{}'; PR URLs are captured in the Jira comment.
  local url_list
  url_list=$(printf '%s\n' "${merged_urls[@]}")
  printf 'All PRs merged for %s:\n%s' "$branch" "$url_list"
  return 0
}

verify_tektonTasks() {
  local version="$1"
  local tracker="${2:-}"
  local major_minor="${version%.*}"
  local branch="fix-tekton-tasks-${major_minor}"
  # 5 component repos + FBC repo (stolostron org)
  local repos="submariner-io/submariner-operator submariner-io/submariner submariner-io/lighthouse submariner-io/shipyard submariner-io/subctl stolostron/submariner-operator-fbc"
  _verify_prs_merged "$version" "$tracker" "$branch" "$repos"
}

verify_rpmLockfiles() {
  local version="$1"
  local tracker="${2:-}"
  local branch="update-rpm-lockfiles-${version}"
  # RPM lockfiles only apply to submariner and shipyard
  local repos="submariner-io/submariner submariner-io/shipyard"
  _verify_prs_merged "$version" "$tracker" "$branch" "$repos"
}

verify_versionLabels() {
  local version="$1"
  local tracker="${2:-}"
  local major_minor="${version%.*}"
  local branch="fix-version-labels-${major_minor}"
  # Version labels apply to all 5 component repos
  local repos="submariner-io/submariner-operator submariner-io/submariner submariner-io/lighthouse submariner-io/shipyard submariner-io/subctl"
  _verify_prs_merged "$version" "$tracker" "$branch" "$repos"
}

# verify_cveFixes: detect CVE fix PR state across all 7 Go repos.
#
# CVE fix PRs are opened from a fork (the cve-fix skill uses fork-remote PR
# creation), so `gh pr list --head <branch>` on the upstream org won't find
# them — the head ref includes the fork username. Use `--search "fix-VERSION-cves
# in:head"` instead, which matches the branch name substring regardless of fork
# ownership, returning PRs from any fork targeting any base branch.
#
# "No PR found" for a repo means it was clean (no CVEs → no fix branch → no PR).
# That is treated as verified for that repo.
#
# Exit codes (same contract as _verify_prs_merged):
#   0  — all repos verified (all found PRs merged, or no PR needed)
#   1  — no CVE PRs found in any repo (script hasn't run for this version yet)
#   2  — gh not available or query failure
#   3  — at least one repo has an open CVE fix PR (wait for merge)
#
# Stdout on rc=0: Jira comment text ("All CVE fix PRs merged for X...")
# Stdout on rc=3: Jira comment text ("CVE fix PRs open for X...")
# Stdout must be empty on rc=1 and rc=2 (verifier failure contract).
verify_cveFixes() {
  local version="$1"
  local tracker="${2:-}"
  # The cve-fix skill names branches fix-<major.minor>-cves-<date> (not full X.Y.Z).
  # Use major.minor so the search matches e.g. "dfarrell07:fix-0.24-cves-20260825-v4".
  local major_minor="${version%.*}"
  local search_term="fix-${major_minor}-cves"
  # All 7 Go repos scanned by cve-fixes-update.sh (matches its REPO_ORDER)
  local repos="submariner-io/submariner-operator submariner-io/submariner submariner-io/lighthouse submariner-io/shipyard submariner-io/subctl submariner-io/admiral submariner-io/cloud-prepare"

  if ! command -v gh &>/dev/null; then
    echo "  gh not installed" >&2; return 2
  fi

  local any_open=false any_found=false
  local merged_urls=() open_urls=()

  for repo in $repos; do
    local pr_json pr_rc=0
    # --search finds PRs from any fork whose head branch contains the search
    # term, across all states. GitHub search in:head matches the "<user>:<branch>"
    # head ref string, so "fix-0.24-cves" matches e.g. "dfarrell07:fix-0.24-cves-20260825-v4".
    pr_json=$(gh pr list --repo "$repo" \
      --search "${search_term} in:head" \
      --state all \
      --json number,state,mergedAt,url --limit 5 2>/dev/null) || pr_rc=$?
    if [ "$pr_rc" -ne 0 ]; then
      echo "  gh pr list failed for $repo (exit $pr_rc) — network or auth issue" >&2
      return 2
    fi

    local merged_url open_url
    merged_url=$(printf '%s' "$pr_json" | \
      jq -r '[.[] | select(.state=="MERGED")] | sort_by(.mergedAt) | last | .url // empty' \
      2>/dev/null) || merged_url=""
    open_url=$(printf '%s' "$pr_json" | \
      jq -r '[.[] | select(.state=="OPEN")] | last | .url // empty' \
      2>/dev/null) || open_url=""

    # Check open before merged: a repo may have both (merged v1, open v2 re-run).
    # Open takes priority — an open PR blocks completion regardless of prior merges.
    if [ -n "$open_url" ]; then
      any_found=true any_open=true
      open_urls+=("$open_url")
      [ -n "$merged_url" ] && merged_urls+=("$merged_url")
      echo "  CVE fix PR open, not yet merged: $open_url" >&2
    elif [ -n "$merged_url" ]; then
      any_found=true
      merged_urls+=("$merged_url")
    fi
    # No PR found → repo was clean (no CVEs → no fix branch → no PR). Verified.
  done

  if ! $any_found; then
    # No CVE fix PRs in any repo — script hasn't run for this version yet.
    return 1
  fi

  if $any_open; then
    local open_list merged_list=""
    open_list=$(printf '%s\n' "${open_urls[@]}")
    [ "${#merged_urls[@]}" -gt 0 ] && merged_list=$(printf '%s\n' "${merged_urls[@]}")
    if [ -n "$merged_list" ]; then
      printf 'CVE fix PRs open for %s (some still open):\nOpen:\n%s\nMerged:\n%s' \
        "$version" "$open_list" "$merged_list"
    else
      printf 'CVE fix PRs open for %s:\n%s' "$version" "$open_list"
    fi
    return 3
  fi

  # All found PRs are merged; repos with no PR were clean.
  local url_list
  url_list=$(printf '%s\n' "${merged_urls[@]}")
  printf 'All CVE fix PRs merged for %s:\n%s' "$version" "$url_list"
  return 0
}

# Map step keys to verifier functions (only steps with external verifiers)
declare -A STEP_VERIFIER=(
  ["createBranches"]="verify_createBranches"
  ["upstreamRelease"]="verify_upstreamRelease"
  ["ecFixes"]="verify_ecFixes"
  ["fbcProdUrls"]="verify_fbcProdUrls"
  ["tektonTasks"]="verify_tektonTasks"
  ["rpmLockfiles"]="verify_rpmLockfiles"
  ["versionLabels"]="verify_versionLabels"
  ["cveFixes"]="verify_cveFixes"
)

# RELEASE_YAML_STEPS and DIRECT_PUSH_STEPS are defined in jira-tracker.sh
# (sourced above) alongside the other step metadata.
#
# NOTE: a single conductor run can in principle produce BOTH kinds of pending
# work (a PR-based git-push block AND a release-YAML apply/watch block), so the
# two block types are NOT mutually exclusive per invocation — the trailer is
# classified by which kinds of work actually grew the push log (see the run
# branch), not by a single flag, and both trailer lines are emitted when both
# occurred. (The original concrete trigger was bundleShas auto-chaining straight
# into componentStage; bundleShas is now `review` (AUTOMATION_LEVEL), so it stops
# the chain — the two-flag design is kept as the correct defensive shape.)

# Classify a step's push-log growth and echo the trailer flag it should set:
# "ran_release_yaml_step" (apply/watch block), "ran_direct_push_step" (direct
# push block — no PR, just git push then wait for rebuild),
# "ran_pr_step" (PR push block), or "" (no growth). This is the SINGLE source
# of truth for the main-loop dispatch — the caller just does
# `printf -v "$flag" 1`, so there are no case arms to swap and tests exercise
# the identical mapping. Multiple flags can be set across one run. Defined
# outside the testing guard so it is unit-testable.
# Args: $1=step key  $2=log size before  $3=log size after
classify_log_growth() {
  local step="$1" before="$2" after="$3"
  [ "$after" -gt "$before" ] || { echo ""; return 0; }
  if [ -n "${RELEASE_YAML_STEPS[$step]:-}" ]; then echo "ran_release_yaml_step"
  elif [ -n "${DIRECT_PUSH_STEPS[$step]:-}" ]; then echo "ran_direct_push_step"
  else echo "ran_pr_step"
  fi
}

# Emit the re-run trailer line(s) for the pending-actions summary, based on which
# kinds of pending work the run produced. Multiple flags can be set in one run,
# so multiple lines may print. Defined outside the testing guard so it is
# unit-testable.
# Args: $1=ran_pr_step (non-empty if a PR-based block was written)
#       $2=ran_release_yaml_step (non-empty if a release-YAML block was written)
#       $3=version
#       $4=ran_direct_push_step (non-empty if a direct-push block was written)
print_pending_trailer() {
  local pr="$1" yaml="$2" version="$3" direct="${4:-}"
  [ -n "$pr" ] && echo "After PRs merge, wait for Konflux to rebuild (~15-30 min), then re-run: /autorelease $version"
  [ -n "$yaml" ] && echo "After apply/watch succeeds, re-run: /autorelease $version"
  [ -n "$direct" ] && echo "After push + rebuild completes (~15-30 min), re-run: /autorelease $version"
  if [ -z "$pr" ] && [ -z "$yaml" ] && [ -z "$direct" ]; then
    echo "After the actions above complete, re-run: /autorelease $version"
  fi
}

# Emit the stop guidance for a review step. If the run queued any pending
# push/apply actions, the Pending Actions trailer owns the re-run instruction
# (and states the correct precondition), so defer to it rather than print a
# premature "re-run now" that would contradict it. Keyed on the push log — the
# same condition the EXIT-trap trailer uses — so the two never disagree, even
# when an earlier chained auto step (not this review step) grew the log.
# Defined outside the testing guard so it is unit-testable.
# Args: $1=push-log path  $2=version
print_review_stop() {
  local push_log="$1" version="$2"
  if [ -s "$push_log" ]; then
    echo "  Review the output above, then complete the Pending Actions below."
  else
    echo "  Review the output above, then re-run: /autorelease $version"
  fi
}

# --- Propagation note: guidance when a step is blocked on an unpushed dep ---
# Many steps produce LOCAL commits that must be pushed, merged, and (for
# build-consuming steps) rebuilt in Konflux/FBC before a *downstream* step can
# run — the "propagation gap" (see the plan). When a downstream script fails, a
# raw "❌ failed" says nothing about that gap: the common cause isn't a bug but a
# dependency whose changes haven't propagated yet. If STEP has an immediate
# dependency, print a conditional note naming it so the operator checks
# propagation before hunting a phantom bug. Dependency-less steps print nothing
# (their failures are never a propagation wait — no upstream to blame), which is
# why gating on STEP_DEPENDENCIES alone is honest without a second map. Output to
# stdout; callers redirect to stderr. Testable helper, mirroring print_review_stop.
print_propagation_note() {
  local step="$1"
  local deps="${STEP_DEPENDENCIES[$step]:-}"
  [ -n "$deps" ] || return 0
  # Split on comma the same way find_next_step does (IFS=',' read -ra), so the
  # two dependency readers stay consistent and neither relies on glob-unsafe
  # word-splitting.
  local titles="" dep dep_arr
  IFS=',' read -ra dep_arr <<< "$deps"
  for dep in "${dep_arr[@]}"; do
    [ -z "$dep" ] && continue
    titles="${titles:+$titles, }${STEP_TITLES[$dep]:-$dep}"
  done
  echo "  If blocked on an earlier step, make sure the changes from"
  echo "  ${titles} are pushed, merged, and rebuilt, then re-run."
}

# --- Terminal summary: the end-of-release message ---
# Printed when only the last step (fbcProdUrls) remains: every release-shipping
# step is done and only the quay.io→registry.redhat.io FBC prod URL conversion is
# left. verify_fbcProdUrls returns 1 until that conversion lands in the FBC
# template, so the walk stops here — this is a real next action, not a blocker.
# Once the operator does the conversion and re-runs, the verifier passes, the
# walk reaches all_done, and the tracker auto-closes. Shared by the real loop and
# run_dry_run so the wording never diverges. Param-free (reads the VERSION global;
# no Jira I/O). Owns the last-step title/hint lookup via ${STEP_ORDER[-1]} so the
# terminal step name lives in one place. Defined outside the testing guard so
# tests and run_dry_run call it directly. All output to stderr.
print_terminal_summary() {
  local last_step="${STEP_ORDER[-1]}"
  echo "" >&2
  echo "✅ All automated steps complete for $VERSION" >&2
  echo "" >&2
  echo "  Before announcing, confirm the prod component and FBC releases" >&2
  echo "  were applied (make apply) and their pipelines succeeded — the" >&2
  echo "  conductor does not apply prod release CRs itself." >&2
  echo "" >&2
  echo "  One step remains — '${STEP_TITLES[$last_step]:-$last_step}':" >&2
  echo "  convert the temporary quay.io bundle URLs to permanent" >&2
  echo "  registry.redhat.io URLs in the FBC template." >&2
  local hint="${STEP_SKILL_HINT[$last_step]:-}"
  [ -n "$hint" ] && echo "  $hint" >&2
  echo "" >&2
  echo "  Re-run once done to close the release: /autorelease $VERSION" >&2
}

# --- --dry-run: preview the auto-chain without executing or writing anything ---
# Answers "what would /autorelease do next, and what would it write?" purely as a
# simulation. Fetch real tracker state ONCE (via a normal find_next_step call —
# reusing its acli/jq error handling: a bad Jira read refuses the dry run too),
# then re-walk the DAG in memory, marking each would-run/auto step complete in the
# file-scope step_statuses array (NEVER update_step) until the first stop.
#
# Consumes-and-mutates the caller's step_statuses global (find_next_step reads
# it). Reads globals VERSION, RELEASE_TYPE, TRACKER. Defined outside the testing
# guard so tests call it directly. All output to stderr (matches find_next_step's
# ✓ lines; `--dry-run >file` never splits). NEVER calls update_step,
# handle_step_override, any per-step script, or any verifier.
run_dry_run() {
  # Freeze boundary (explicit): shadow both flags EMPTY so they are
  # function-scoped and auto-reset on return (nothing leaks into later tests),
  # call find_next_step once genuinely UNFROZEN (real fetch + error handling +
  # step_statuses seed + the free `✓ done` echoes), THEN freeze before re-walking.
  local _AUTORELEASE_NOFETCH='' _AUTORELEASE_QUIET=''

  # No tracker yet: treat as a fresh release (all steps pending), skip real fetch.
  if [ -z "$TRACKER" ]; then
    TRACKER="(no tracker — all steps pending)"
    _AUTORELEASE_NOFETCH=1
  fi

  echo "Dry run: Submariner $VERSION ($RELEASE_TYPE) · tracker $TRACKER" >&2
  echo "No scripts run, nothing written to Jira." >&2
  echo "" >&2

  # Seed call: genuine fetch (skipped when no tracker, NOFETCH=1 set above).
  # A bad read exits 1 here via find_next_step's own refusal — the dry run
  # declines too, exactly like a real run.
  # find_next_step sets NEXT_STEP and NEXT_REASON as side effects.
  find_next_step "$VERSION" "$RELEASE_TYPE" "$TRACKER"

  # Freeze: every later walk runs against the in-memory step_statuses array, and
  # QUIET suppresses re-printing the completed-steps list on each re-walk.
  _AUTORELEASE_NOFETCH=1 _AUTORELEASE_QUIET=true

  # Note any in_progress steps so the operator knows partial work may exist.
  local _ip_step
  for _ip_step in "${STEP_ORDER[@]}"; do
    if [ "${step_statuses[$_ip_step]:-}" = "in_progress" ]; then
      echo "⚠ ${STEP_TITLES[$_ip_step]:-$_ip_step}: in_progress — re-running may duplicate work if changes are already committed" >&2
    fi
  done

  local n=0 printed_header=""
  local stop="" stop_title="" stop_reason=""
  local first_gate="" first_gate_title=""
  local gate_prefix="" script="" args="" level=""

  while true; do
    case "$NEXT_REASON" in
      all_done)
        echo "" >&2
        echo "✅ Nothing left to run for $VERSION" >&2
        break
        ;;

      gate|hint)
        # Arm (a) MUST precede the verifier arm: dry-run can't invoke
        # verify_fbcProdUrls (which returns 1 until the prod-URL conversion lands
        # in the FBC template), so the last step is always the terminal summary
        # here, never an optimistic chain.
        if [ "$NEXT_STEP" = "${STEP_ORDER[-1]}" ]; then
          print_terminal_summary
          echo "" >&2
          echo "  (dry run: cannot confirm whether the conversion has happened)" >&2
          echo "  (dry run: once this prod-URL step completes, a real run would" >&2
          echo "   verify the prod bundle + in-scope operator indexes and" >&2
          echo "   auto-resolve the tracker if $VERSION shipped)" >&2
          break
        fi
        # Arm (b): a verifier-backed step chains optimistically (dry-run stays
        # offline — invoking the verifier would need oc login and defeat the quick
        # preview), labeled conditional so the numbered step never reads as a
        # promise. `gate ·` prefix only when NEXT_REASON=gate (upstreamRelease);
        # createBranches/ecFixes reach here as hint → plain label.
        if [ -n "${STEP_VERIFIER[$NEXT_STEP]:-}" ]; then
          n=$((n + 1))
          [ -z "$printed_header" ] && { echo "Would run next:" >&2; printed_header=1; }
          gate_prefix=""
          [ "$NEXT_REASON" = "gate" ] && gate_prefix="gate · "
          echo "  $n. ${STEP_TITLES[$NEXT_STEP]:-$NEXT_STEP}" >&2
          local _vdesc
          case "$NEXT_STEP" in
            createBranches)  _vdesc="release-${VERSION%.*} branches exist on all upstream repos" ;;
            upstreamRelease) _vdesc="v$VERSION tag exists on all upstream component repos (submariner-operator, submariner, lighthouse, shipyard, subctl)" ;;
            ecFixes)         _vdesc="EC passes on Konflux snapshot" ;;
            *)               _vdesc="${STEP_VERIFIER[$NEXT_STEP]}" ;;
          esac
          echo "       ${gate_prefix}auto-verifies: ${_vdesc} (${STEP_VERIFIER[$NEXT_STEP]}; chains if passes, breaks if preconditions unmet)" >&2
          local _hint="${STEP_SKILL_HINT[$NEXT_STEP]:-}"
          [ -n "$_hint" ] && echo "       hint: $_hint" >&2
          if [ -z "$first_gate" ]; then
            first_gate="$_vdesc"
            first_gate_title="${STEP_TITLES[$NEXT_STEP]:-$NEXT_STEP}"
          fi
          step_statuses[$NEXT_STEP]=complete
          # find_next_step sets NEXT_STEP and NEXT_REASON as side effects.
          find_next_step "$VERSION" "$RELEASE_TYPE" "$TRACKER"
          continue
        fi
        # Arm (c): no verifier → hard stop with the step's skill hint.
        stop="$NEXT_STEP"
        stop_title="${STEP_TITLES[$NEXT_STEP]:-$NEXT_STEP}"
        stop_reason="${STEP_SKILL_HINT[$NEXT_STEP]:-complete this step manually}"
        break
        ;;

      run)
        n=$((n + 1))
        [ -z "$printed_header" ] && { echo "Would run next:" >&2; printed_header=1; }
        script="${STEP_SCRIPT[$NEXT_STEP]:-}"
        args="${STEP_EXTRA_ARGS[$NEXT_STEP]:-}"
        level="${AUTOMATION_LEVEL[$NEXT_STEP]:-auto}"
        # Annotate in_progress steps so the numbered entry visually connects
        # to the upfront ⚠ warning — otherwise the operator must mentally
        # match the step name across two separate blocks.
        local _dr_note=""
        [ "${step_statuses[$NEXT_STEP]:-}" = "in_progress" ] && \
          _dr_note=" (in_progress)"
        echo "  $n. ${STEP_TITLES[$NEXT_STEP]:-$NEXT_STEP}${_dr_note}" >&2
        if [ -n "$args" ]; then
          echo "       run: $script $VERSION $args" >&2
        else
          echo "       run: $script $VERSION" >&2
        fi
        # Side effect, statically — four-way, matching classify_log_growth's
        # domain: RELEASE_YAML_STEPS write a release CR (apply/watch);
        # DIRECT_PUSH_STEPS push directly to main (no PR); other run scripts
        # push a PR/MR; releaseNotes edits notes in-repo and grows no push log.
        if [ -n "${RELEASE_YAML_STEPS[$NEXT_STEP]:-}" ]; then
          echo "       → then: make apply/watch (release CR)" >&2
        elif [ -n "${DIRECT_PUSH_STEPS[$NEXT_STEP]:-}" ]; then
          echo "       → then: git push (direct push, no PR; wait ~15-30 min for rebuild)" >&2
        elif [ "$NEXT_STEP" = "cveFixes" ]; then
          echo "       → then: per-repo fork-remote PRs (see each repo's PR command: block in the output)" >&2
        elif [ "$NEXT_STEP" != "releaseNotes" ]; then
          echo "       → then: git push (opens PR/MR)" >&2
        fi
        step_statuses[$NEXT_STEP]=complete
        # A review run step is the stop point: it runs, then the real loop breaks.
        if [ "$level" = "review" ]; then
          stop="$NEXT_STEP"
          stop_title="${STEP_TITLES[$NEXT_STEP]:-$NEXT_STEP}"
          stop_reason="runs the script then pauses for review — re-run /autorelease $VERSION to execute"
          break
        fi
        # find_next_step sets NEXT_STEP and NEXT_REASON as side effects.
        find_next_step "$VERSION" "$RELEASE_TYPE" "$TRACKER"
        continue
        ;;

      manual)
        stop="$NEXT_STEP"
        stop_title="${STEP_TITLES[$NEXT_STEP]:-$NEXT_STEP}"
        stop_reason="complete manually, then re-run /autorelease $VERSION"
        break
        ;;

      *)
        echo "❌ Unknown dispatch reason: $NEXT_REASON" >&2
        return 1
        ;;
    esac
  done

  # Epilogue: stop line + optimism footnote, only when the walk stopped AT a step.
  # The all_done / fbcProdUrls terminals carry their own wording and are gated out
  # here by the empty $stop.
  if [ -n "$stop" ]; then
    echo "" >&2
    if [ -n "$first_gate" ]; then
      # The path crossed a verifier gate — present the terminal as conditional so
      # it never reads as definitive (a passing gate would carry the walk further).
      echo "Earliest possible stop: $first_gate_title (verifier: $first_gate)" >&2
      echo "Otherwise stops at: $stop_title — $stop_reason" >&2
    else
      echo "Stops at: $stop_title — $stop_reason" >&2
    fi
    echo "Note: this offline preview is optimistic — verifier gates proceed only" >&2
    echo "      if their live check passes; run steps assume their inputs are" >&2
    echo "      already pushed/merged/rebuilt and that each script succeeds and" >&2
    echo "      self-completes; side effects are best-effort predictions." >&2
  fi
}

# --- Preflight: report tool/cred readiness before a full run ---
# Purely additive and read-only: it NEVER blocks. A failed probe prints a ⚠ with
# the fix and the run proceeds — a run may not reach the step that needs the
# missing tool, and oc-dependent verifiers already fail closed (the gate just
# won't chain). It exists to turn two bad failure modes into one up-front line:
# gh-unauthed (today a cryptic mid-run script failure) and oc-not-logged-in
# (today a *silent* verifier that stops at a gate that should have chained). Runs
# only on the full-run path (after the one-shot --flag dispatches), so --dry-run
# and the --complete/--refresh/--close modes stay fast and offline.
# Callable from tests (outside the _AUTORELEASE_TESTING guard).
run_preflight() {
  echo "Preflight:" >&2
  local tool oc_user

  # jq, git — required by the conductor itself; presence only (no auth). Proven
  # present by the time we reach here (tracker read + GIT_ROOT succeeded), so the
  # ⚠ arms are defensive; listing them keeps the readiness report complete.
  for tool in jq git; do
    if command -v "$tool" >/dev/null 2>&1; then
      echo "  ✓ $tool" >&2
    else
      echo "  ⚠ $tool not found — install it ($tool is required)" >&2
    fi
  done

  # acli — Jira reads drive step detection.  Exit-code-only probe: run
  # "acli jira auth status" and trust its exit code (0 = authenticated, non-zero
  # = not authenticated).  All output is discarded so substring matches in negation
  # messages (e.g., "Unauthenticated" contains "authenticated"; "You are not logged
  # in" contains "logged in") cannot produce false positives.  This is also a simple
  # command rather than a pipeline, so set -o pipefail does not interfere.
  if ! command -v acli >/dev/null 2>&1; then
    echo "  ⚠ acli not found — install it (Jira reads drive step detection)" >&2
  elif acli jira auth status </dev/null >/dev/null 2>&1; then
    echo "  ✓ acli — Jira authenticated" >&2
  else
    echo "  ⚠ acli — not authenticated to Jira; run: acli jira auth login --web" >&2
  fi

  # gh — push/PR steps (bundleShas, retest comments, …) call it. Unauthed today
  # surfaces as a cryptic mid-run failure deep inside a step script.
  if ! command -v gh >/dev/null 2>&1; then
    echo "  ⚠ gh not found — install it (needed for push/PR steps)" >&2
  elif gh auth status >/dev/null 2>&1; then
    echo "  ✓ gh — authenticated" >&2
  else
    echo "  ⚠ gh — not authenticated; run: gh auth login (needed for push/PR steps)" >&2
  fi

  # oc — verifiers `oc get` to confirm gate/hint steps. Not logged in means they
  # fail closed: the gate stops for manual completion instead of chaining, which
  # reads as a confusing early stop unless flagged here.
  if ! command -v oc >/dev/null 2>&1; then
    echo "  ⚠ oc not found — verifier gate steps can't self-confirm (they'll stop for manual completion)" >&2
  elif oc_user=$(oc whoami 2>/dev/null); then
    echo "  ✓ oc — logged in ($oc_user)" >&2
  else
    echo "  ⚠ oc — not logged in; verifier gate steps can't self-confirm until you run: oc login --web <cluster>" >&2
  fi

  # registry.redhat.io / ~/.docker/config.json — prod index probes (auto-close) use
  # "oc image extract" (reads ~/.docker/config.json) and "skopeo inspect" (reads
  # /run/containers/auth.json, then falls back to ~/.docker/config.json). Checking
  # ~/.docker/config.json covers both tools; podman users who ran "podman login"
  # without --authfile wrote to /run/containers/auth.json only, so the warning fires
  # for them — the fix includes the podman-compatible alternative below.
  # Warn-only: blocking on registry auth would prevent all pre-prod steps from running.
  # _PREFLIGHT_DOCKER_CFG may be set by tests to override the default path.
  local _docker_cfg="${_PREFLIGHT_DOCKER_CFG:-$HOME/.docker/config.json}"
  if [ ! -f "$_docker_cfg" ]; then
    echo "  ⚠ registry.redhat.io: $_docker_cfg not found — prod index probes will" >&2
    echo "    return unreachable. To fix: docker login registry.redhat.io" >&2
    echo "    (or podman: podman login --authfile ~/.docker/config.json registry.redhat.io)" >&2
  elif ! command -v jq >/dev/null 2>&1; then
    : # jq absent — jq-missing warning already emitted above; skip registry check
  elif ! jq -e '.auths["registry.redhat.io"]' "$_docker_cfg" >/dev/null 2>&1; then
    echo "  ⚠ registry.redhat.io: not in $_docker_cfg — prod index probes will" >&2
    echo "    return unreachable. To fix: docker login registry.redhat.io" >&2
    echo "    (or podman: podman login --authfile ~/.docker/config.json registry.redhat.io)" >&2
  elif ! jq -e '.auths["registry.redhat.io"] | (.auth // .identitytoken // "") | length > 0' \
         "$_docker_cfg" >/dev/null 2>&1; then
    echo "  ⚠ registry.redhat.io: credentials empty in $_docker_cfg — prod index probes will" >&2
    echo "    return unreachable. To fix: docker login registry.redhat.io" >&2
    echo "    (or podman: podman login --authfile ~/.docker/config.json registry.redhat.io)" >&2
  else
    echo "  ✓ registry.redhat.io — credentials in $_docker_cfg" >&2
  fi

  echo "" >&2
  return 0
}

# _print_step_hint: display a gate/hint stop line with its skill hint and
# the appropriate re-run or --complete instruction.
# Args: $1=step_key  $2=reason ("gate"|"hint")
# Reads globals: STEP_TITLES, STEP_SKILL_HINT, STEP_VERIFIER, VERSION.
# All output to stderr.
_print_step_hint() {
  local step="$1" reason="$2"
  if [ "$reason" = "gate" ]; then
    echo "⏸ ${STEP_TITLES[$step]:-$step}: GATE" >&2
  else
    echo "→ ${STEP_TITLES[$step]:-$step}" >&2
  fi
  echo "  ${STEP_SKILL_HINT[$step]:-Complete this step manually}" >&2
  # Verifier-backed steps can be re-detected on the next run; --complete is the
  # manual escape. Steps without verifiers ONLY advance via --complete.
  if [ -n "${STEP_VERIFIER[$step]:-}" ]; then
    echo "  Re-run once done: /autorelease $VERSION" >&2
    echo "  Or mark done manually: /autorelease $VERSION --complete $step" >&2
  else
    echo "  When done: /autorelease $VERSION --complete $step" >&2
  fi
}

# run_conductor: multi-step dispatch loop.
# Callable from tests (outside the _AUTORELEASE_TESTING guard).
# Caller must set globals: VERSION, RELEASE_TYPE, TRACKER, AUTORELEASE_PUSH_LOG,
#   ran_pr_step, ran_release_yaml_step, ran_direct_push_step.
# Caller must declare+initialize: step_statuses, verified_steps (assoc arrays).
run_conductor() {
  local prev_step="" _tav_rc=0
  local local_script="" local_args="" local_title="" local_level="" local_exit=0
  local _log_before=0 _log_after=0 _growth_flag="" _rstep_status=""

  while true; do
    # find_next_step sets NEXT_STEP and NEXT_REASON as side effects.
    find_next_step "$VERSION" "$RELEASE_TYPE" "$TRACKER"

    case "$NEXT_REASON" in
      all_done)
        # Item 9: every tracked step — including fbcProdUrls, the prod-URL FBC
        # conversion — is complete, so the prod-URL step always precedes the epic
        # close. Now, and only now, auto-resolve the tracker if the release is
        # provably live in production (bundle + every in-scope operator index) —
        # the automated equivalent of the manual --close. On any shortfall
        # (not-shipped/unreachable) try_auto_close prints why and we fall through
        # to the standard message, which never claims the release shipped.
        #
        # tracker_is_open gates this so re-runs on an already-resolved release
        # skip the registry probes and the (comment-adding) re-close entirely.
        if tracker_is_open "$VERSION" && try_auto_close "$VERSION"; then
          break
        fi
        echo "" >&2
        echo "✅ All steps complete for $VERSION" >&2
        break
        ;;

      gate|hint)
        # Chain past the step if an external verifier confirms it already happened.
        # Exit codes: 0=verified, 1=not done, 2=precondition failure, 3=work in progress.
        _tav_rc=0; try_auto_verify "$NEXT_STEP" || _tav_rc=$?
        if [ "$_tav_rc" -eq 0 ]; then
          step_statuses[$NEXT_STEP]='complete'
          _AUTORELEASE_NOFETCH=1
          continue
        fi
        if [ "$_tav_rc" -eq 2 ]; then
          echo "  ⚠ Cannot verify ${STEP_TITLES[$NEXT_STEP]:-$NEXT_STEP} — check preconditions above" >&2
          echo "  Re-run once done: /autorelease $VERSION" >&2
          break
        fi
        # Terminal-message special case: fbcProdUrls is last in STEP_ORDER and
        # its deps cover every other step, so reaching it here means every
        # release-shipping step is complete and only the prod-URL conversion
        # remains. verify_fbcProdUrls returns 1 until that conversion lands in the
        # FBC template — a real next action, not a blocker. The epic is NOT
        # auto-closed here: once the operator does the conversion and re-runs, the
        # verifier passes, the walk reaches all_done, and auto-close resolves the
        # tracker there. Print a distinct message (which points at the conversion
        # and says to re-run when done).
        if [ "$NEXT_STEP" = "${STEP_ORDER[-1]}" ]; then
          print_terminal_summary
          break
        fi

        # Verifier failed or doesn't exist — stop with hint
        echo "" >&2
        _print_step_hint "$NEXT_STEP" "$NEXT_REASON"
        break
        ;;

      run)
        # Same-step guard: the script ran (exit 0) but the tracker still shows the
        # step incomplete. First try the verifier — for review-level steps this
        # checks that PRs are merged and auto-advances if so. Only fall through
        # to the warning if the verifier says not done yet.
        if [ "$NEXT_STEP" = "$prev_step" ]; then
          _tav_rc=0; try_auto_verify "$NEXT_STEP" || _tav_rc=$?
          if [ "$_tav_rc" -eq 0 ]; then
            step_statuses[$NEXT_STEP]='complete'
            _AUTORELEASE_NOFETCH=1
            continue
          fi
          if [ "$_tav_rc" -eq 2 ]; then
            echo "  ⚠ Cannot verify ${STEP_TITLES[$NEXT_STEP]:-$NEXT_STEP} — check preconditions above" >&2
            echo "  Re-run once done: /autorelease $VERSION" >&2
            break
          fi
          if [ "$_tav_rc" -eq 3 ]; then
            echo "" >&2
            echo "⏳ ${STEP_TITLES[$NEXT_STEP]:-$NEXT_STEP}: PRs open, waiting for merge" >&2
            echo "  Re-run after PRs merge: /autorelease $VERSION" >&2
            break
          fi
          echo "" >&2
          echo "⚠️  ${STEP_TITLES[$NEXT_STEP]:-$NEXT_STEP}: ran, but isn't complete yet" >&2
          echo "  Its changes likely need to propagate first — push any commits," >&2
          echo "  merge the PR(s), and wait for the rebuild, then:" >&2
          echo "  Re-run: /autorelease $VERSION" >&2
          echo "  Or, if the step is actually done: /autorelease $VERSION --complete $NEXT_STEP" >&2
          break
        fi
        prev_step="$NEXT_STEP"

        # For in_progress steps with a verifier, check if the work is already
        # done (e.g. PRs merged) before re-running the script. This handles the
        # case where the conductor is re-invoked after a review-level step ran
        # on a prior run — prev_step starts empty each fresh invocation, so the
        # same-step guard above never fires, but we still must not re-run the
        # script if the external state shows the step is complete.
        local_status="${step_statuses[$NEXT_STEP]:-}"
        if [ "$local_status" = "in_progress" ] && [ -n "${STEP_VERIFIER[$NEXT_STEP]:-}" ]; then
          _tav_rc=0; try_auto_verify "$NEXT_STEP" || _tav_rc=$?
          if [ "$_tav_rc" -eq 0 ]; then
            step_statuses[$NEXT_STEP]='complete'
            _AUTORELEASE_NOFETCH=1
            continue
          fi
          if [ "$_tav_rc" -eq 2 ]; then
            echo "  ⚠ Cannot verify ${STEP_TITLES[$NEXT_STEP]:-$NEXT_STEP} — check preconditions above" >&2
            echo "  Re-run once done: /autorelease $VERSION" >&2
            break
          fi
          if [ "$_tav_rc" -eq 3 ]; then
            echo "" >&2
            echo "⏳ ${STEP_TITLES[$NEXT_STEP]:-$NEXT_STEP}: PRs open, waiting for merge" >&2
            echo "  Re-run after PRs merge: /autorelease $VERSION" >&2
            break
          fi
          # Verifier returned 1: no PRs found yet — fall through to run the script.
        fi

        local_script="${STEP_SCRIPT[$NEXT_STEP]:-}"
        local_args="${STEP_EXTRA_ARGS[$NEXT_STEP]:-}"
        local_title="${STEP_TITLES[$NEXT_STEP]:-$NEXT_STEP}"
        local_level="${AUTOMATION_LEVEL[$NEXT_STEP]:-auto}"

        echo "→ $local_title: running $local_script $VERSION $local_args..." >&2
        echo "" >&2

        _log_before=$(wc -c < "$AUTORELEASE_PUSH_LOG" 2>/dev/null || echo 0)
        local_exit=0
        if [ -n "$GIT_ROOT" ]; then
          # shellcheck disable=SC2086  # Intentional word splitting on local_args
          (cd "$GIT_ROOT" && AUTORELEASE_TRACKER_STEP="$NEXT_STEP" "$GIT_ROOT/$local_script" "$VERSION" $local_args) >&2 || local_exit=$?
        else
          # shellcheck disable=SC2086
          AUTORELEASE_TRACKER_STEP="$NEXT_STEP" "$local_script" "$VERSION" $local_args >&2 || local_exit=$?
        fi

        # Classify any push-log growth this step produced. Both kinds can occur
        # across one run (a PR block plus a release-YAML apply/watch block — the
        # retired bundleShas → componentStage auto-chain was the classic case),
        # so set whichever flag matches the step that actually grew the log.
        _log_after=$(wc -c < "$AUTORELEASE_PUSH_LOG" 2>/dev/null || echo 0)
        # classify_log_growth echoes the flag name to set (or "" for no growth);
        # printf -v sets it, so the mapping lives entirely in the tested helper.
        # ran_direct_push_step is in scope (set to "" above).
        _growth_flag=$(classify_log_growth "$NEXT_STEP" "$_log_before" "$_log_after")
        [ -n "$_growth_flag" ] && printf -v "$_growth_flag" '%s' 1

        echo "" >&2
        if [ "$local_exit" -eq 2 ]; then
          # rc=2 means the script ran successfully but has nothing to commit:
          # task versions and SHAs are already current, but EC is still failing.
          # The script has already emitted a Konflux UI URL + EC log guidance.
          # Stop the conductor here so we don't re-dispatch endlessly.
          echo "⏸ ${local_title}: NOTHING TO UPDATE" >&2
          echo "  Task versions and SHAs are already current." >&2
          echo "  EC is failing for a reason other than stale task refs." >&2
          echo "  See the Konflux UI URL above to download the EC log." >&2
          echo "  After downloading the log, re-run: /autorelease $VERSION" >&2
          break
        fi

        if [ "$local_exit" -ne 0 ]; then
          echo "❌ ${local_title} failed (exit $local_exit)" >&2
          echo "  Fix the issue, then re-run: /autorelease $VERSION" >&2
          # Most common cause of a downstream-step failure isn't a bug — it's an
          # earlier step's commits not yet pushed/merged/rebuilt. Name the dep so
          # the operator checks propagation first (no-op for dep-less steps).
          print_propagation_note "$NEXT_STEP" >&2
          exit 1
        fi

        if [ "$local_level" = "review" ]; then
          echo "⏸ ${local_title}: REVIEW" >&2
          print_review_stop "$AUTORELEASE_PUSH_LOG" "$VERSION" >&2
          # Verify the script self-marked the step complete. A silent Jira write
          # failure leaves it at in_progress, causing the next run to re-dispatch
          # instead of advancing. Only warn — don't block — since the script exit
          # 0 is the authoritative signal.
          _rstep_status=""
          _rstep_status=$(get_step "$VERSION" "$NEXT_STEP" "$TRACKER" 2>/dev/null \
            | jq -r '.status // empty' 2>/dev/null) || _rstep_status=""
          if [ "${_rstep_status:-}" = "in_progress" ]; then
            echo "  ⚠ Tracker still shows 'in_progress' — the write may have failed." >&2
            echo "    If work is already done: /autorelease $VERSION --complete $NEXT_STEP" >&2
          fi
          break
        fi

        # State only what we observed — the script exited 0. Whether it marked
        # itself complete is confirmed by the next find_next_step re-walk (which
        # either advances or trips the same-step guard above); claiming
        # "complete" here would pre-empt that check.
        echo "✓ ${local_title}: script succeeded" >&2
        # Quiet the next find_next_step: it re-fetches and would otherwise
        # reprint the whole completed-steps list on every chained iteration.
        _AUTORELEASE_QUIET=true
        # Clear NOFETCH so find_next_step re-fetches fresh Jira state on the
        # next iteration (NOFETCH may have been set by a prior gate-arm chain).
        _AUTORELEASE_NOFETCH=
        # Continue loop — find_next_step will re-fetch comments
        ;;

      manual)
        # A manual step has no script, hint, or verifier, so re-running just
        # stops here again — --complete is the only way to advance.
        echo "" >&2
        echo "→ ${STEP_TITLES[$NEXT_STEP]:-$NEXT_STEP}: manual step" >&2
        echo "  Complete this step manually, then mark it done:" >&2
        echo "  /autorelease $VERSION --complete $NEXT_STEP" >&2
        break
        ;;

      *)
        echo "❌ Unknown dispatch reason: $NEXT_REASON" >&2
        exit 1
        ;;
    esac
  done
}

# =================================================================
# Main execution — functions above are the testable unit; this block
# is the real entrypoint, skipped under _AUTORELEASE_TESTING=true.
# =================================================================

if [ "${_AUTORELEASE_TESTING:-}" != "true" ]; then

  # Arg handling
  COMPLETE_STEP=""
  REFRESH_STEP=""
  CLOSE=""
  DRY_RUN=""
  VERSION=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --help|-h) usage; exit 0 ;;
      --complete)
        [ $# -lt 2 ] && { echo "ERROR: --complete requires a STEP argument" >&2; exit 1; }
        COMPLETE_STEP="$2"; shift 2 ;;
      --refresh)
        [ $# -lt 2 ] && { echo "ERROR: --refresh requires a STEP argument" >&2; exit 1; }
        REFRESH_STEP="$2"; shift 2 ;;
      --close)
        CLOSE=true; shift ;;
      --dry-run)
        DRY_RUN=true; shift ;;
      -*)
        echo "ERROR: Unknown flag '$1'" >&2; usage >&2; exit 1 ;;
      *)
        [ -n "$VERSION" ] && { echo "ERROR: Too many arguments" >&2; usage >&2; exit 1; }
        VERSION="$1"; shift ;;
    esac
  done

  if [ -z "$VERSION" ]; then
    usage >&2
    exit 1
  fi

  # --complete / --refresh / --close / --dry-run are all mutually
  # exclusive one-shot actions.
  _action_count=0
  [ -n "$COMPLETE_STEP" ] && _action_count=$((_action_count + 1))
  [ -n "$REFRESH_STEP" ] && _action_count=$((_action_count + 1))
  [ -n "$CLOSE" ] && _action_count=$((_action_count + 1))
  [ -n "$DRY_RUN" ] && _action_count=$((_action_count + 1))
  if [ "$_action_count" -gt 1 ]; then
    echo "ERROR: --complete, --refresh, --close, and --dry-run are mutually exclusive" >&2
    exit 1
  fi

  # If 2-segment version, resolve to specific patch
  if [[ "$VERSION" =~ ^[0-9]+\.[0-9]+$ ]]; then
    ORIGINAL="$VERSION"
    RESOLVED=$(_resolve_version "$VERSION")
    VERSION="${RESOLVED%%:*}"
    RESOLVE_SOURCE="${RESOLVED#*:}"
    case "$RESOLVE_SOURCE" in
      tracker)     echo "Resolved $ORIGINAL → $VERSION (from Jira release tracker)" >&2 ;;
      in-progress) echo "Resolved $ORIGINAL → $VERSION (in-progress release)" >&2 ;;
      upstream)    echo "Resolved $ORIGINAL → $VERSION (released on GitHub, Konflux release pending)" >&2 ;;
      released)    echo "Resolved $ORIGINAL → $VERSION (next after ${ORIGINAL}.$(( ${VERSION##*.} - 1 )))" >&2 ;;
      default)     echo "Resolved $ORIGINAL → $VERSION (no prior releases, starting at .0)" >&2 ;;
    esac
  fi

  VERSION=$(_normalize_version "$VERSION")
  _validate_version "$VERSION" || exit 1

  RELEASE_TYPE=$(_detect_release_type "$VERSION")

  # Find tracker (required for completion detection). A Jira query failure
  # (auth/network) returns 2 — report it distinctly so a transient outage never
  # steers the user to create a tracker that may already exist. A genuinely
  # absent tracker (return 0, empty) keeps the "create one first" path.
  TRACKER=$(find_release_tracker "$VERSION") || {
    echo "❌ Could not reach Jira (auth/network) — cannot resolve tracker for $VERSION" >&2
    echo "   Check Jira auth/network, then re-run: /autorelease $VERSION" >&2
    exit 1
  }
  # Dispatch --dry-run BEFORE the tracker guard: a preview must work even when
  # no tracker exists yet (fresh release). run_dry_run handles the empty-TRACKER
  # case itself by treating it as all-steps-pending. Must still be BEFORE the
  # header echo and AUTORELEASE_PUSH_LOG mktemp/trap — a "nothing written"
  # preview must not create a temp file or arm the EXIT trap.
  if [ -n "$DRY_RUN" ]; then
    run_dry_run
    exit $?
  fi

  if [ -z "$TRACKER" ]; then
    echo "❌ No release tracker found for $VERSION" >&2
    echo "   Create one first: /create-release-tracker $VERSION" >&2
    exit 1
  fi

  # Validate --complete / --refresh step keys before use (fast-fail with helpful
  # error; handle_step_override would also reject unknown keys, but its message
  # comes after a Jira fetch — this surfaces the typo immediately).
  if [ -n "$COMPLETE_STEP" ]; then
    if ! printf '%s\n' "${STEP_ORDER[@]}" | grep -qxF "$COMPLETE_STEP"; then
      echo "❌ Unknown step: $COMPLETE_STEP" >&2
      echo "   Valid steps: ${STEP_ORDER[*]}" >&2
      exit 1
    fi
  fi
  if [ -n "$REFRESH_STEP" ]; then
    if ! printf '%s\n' "${STEP_ORDER[@]}" | grep -qxF "$REFRESH_STEP"; then
      echo "❌ Unknown step: $REFRESH_STEP" >&2
      echo "   Valid steps: ${STEP_ORDER[*]}" >&2
      exit 1
    fi
  fi

  # Handle step overrides (--complete / --refresh) before entering the loop
  if [ -n "$COMPLETE_STEP" ]; then
    handle_step_override "$VERSION" "$COMPLETE_STEP" "complete" "$TRACKER"
    exit 0
  fi
  if [ -n "$REFRESH_STEP" ]; then
    handle_step_override "$VERSION" "$REFRESH_STEP" "in_progress" "$TRACKER"
    exit 0
  fi
  if [ -n "$CLOSE" ]; then
    handle_close "$VERSION"
    exit $?
  fi

  echo "Submariner $VERSION ($RELEASE_TYPE)" >&2
  echo "Tracker: $TRACKER" >&2
  echo "" >&2

  # Readiness report (never blocks) — surfaces gh/oc cred gaps up front instead
  # of as a cryptic mid-run failure or a silently non-chaining verifier gate.
  run_preflight

  # --- Push summary: temp file for scripts to append push/PR commands ---
  AUTORELEASE_PUSH_LOG=$(mktemp "${TMPDIR:-/tmp}/autorelease-pushes-XXXXXX")
  export AUTORELEASE_PUSH_LOG

  # Track which kinds of pending work grew the push log this run (both can occur
  # in one run — see RELEASE_YAML_STEPS note). Drives the trailer line(s).
  ran_pr_step=""
  ran_release_yaml_step=""
  ran_direct_push_step=""

  _autorelease_cleanup() {
    local _exit_code=$?
    set +e
    if [ -s "$AUTORELEASE_PUSH_LOG" ]; then
      echo "" >&2
      echo "━━━ Pending Actions ━━━" >&2
      cat "$AUTORELEASE_PUSH_LOG" >&2
      echo "" >&2
      if [ "$_exit_code" -ne 0 ]; then
        echo "Note: the step above also failed — fix that error before re-running." >&2
      else
        print_pending_trailer "$ran_pr_step" "$ran_release_yaml_step" "$VERSION" "$ran_direct_push_step" >&2
      fi
    fi
    rm -f "$AUTORELEASE_PUSH_LOG"
  }
  trap _autorelease_cleanup EXIT

  # --- Multi-step loop with same-step guard ---
  declare -A step_statuses=()
  declare -A verified_steps=()
  run_conductor

fi
