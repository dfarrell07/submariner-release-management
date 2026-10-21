#!/bin/bash
# Check Submariner release status across all workflow steps

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Release YAMLs are permanent records that land on origin/main, but this checkout may be
# on an unrelated branch (or behind) and would then report "No stage release YAML" for a
# release that is already running. Overlay the working tree's releases/ on top of
# origin/main's so both merged records and local not-yet-pushed YAMLs are seen.
# Set RELEASE_STATUS_LOCAL_ONLY=1 to read only the working tree.
if [ -z "${RELEASE_STATUS_LOCAL_ONLY:-}" ] \
  && git -C "$RELEASE_ROOT" rev-parse --verify -q origin/main >/dev/null 2>&1; then
  OVERLAY_DIR=$(mktemp -d)
  trap 'rm -rf "$OVERLAY_DIR"' EXIT
  if git -C "$RELEASE_ROOT" archive origin/main releases 2>/dev/null | tar -x -C "$OVERLAY_DIR" 2>/dev/null; then
    [ -d "$RELEASE_ROOT/releases" ] && cp -a "$RELEASE_ROOT/releases/." "$OVERLAY_DIR/releases/"
    RELEASE_ROOT="$OVERLAY_DIR"
  fi
fi

# Parse arguments
VERSION="${1:-}"

if [ "$VERSION" = "help" ] || [ -z "$VERSION" ]; then
  echo "Usage: scripts/release-status.sh <version>"
  echo ""
  echo "Examples:"
  echo "  scripts/release-status.sh 0.22.1    Check Z-stream release"
  echo "  scripts/release-status.sh 0.22      Check Y-stream release"
  exit 0
fi

# Validate format
if ! echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+(\.[0-9]+)?$'; then
  echo "Error: Invalid version format"
  echo "Expected: X.Y or X.Y.Z (e.g., 0.22 or 0.22.1)"
  exit 1
fi

# Extract version components
MAJOR_MINOR=$(echo "$VERSION" | grep -oE '^[0-9]+\.[0-9]+')
MAJOR_MINOR_DASH=$(echo "$MAJOR_MINOR" | tr '.' '-')
# A bare X.Y means the initial Y-stream release X.Y.0. Normalize VERSION to the
# full X.Y.Z form once, so every downstream use agrees: the artifact globs
# (FULL_VERSION_DASH), the upstream-tag / registry / label checks (v$VERSION),
# and the summary. Without it, `release-status.sh 0.22` reported the artifacts
# "complete" (globs are dash-derived) while Step 6 said "v0.22 tag not found"
# (the real tag is v0.22.0) — a self-contradicting board.
if [ "$VERSION" = "$MAJOR_MINOR" ]; then
  VERSION="$MAJOR_MINOR.0"
fi
FULL_VERSION_DASH=$(echo "$VERSION" | tr '.' '-')

# Detect stream type
# Y-stream: X.Y or X.Y.0 (initial release)
# Z-stream: X.Y.Z where Z>0 (patch releases)
IS_ZSTREAM=false
if echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[1-9][0-9]*$'; then
  IS_ZSTREAM=true
fi

# Constants
readonly BUNDLE_CLOCK_SKEW_SECS=300  # 5 minutes tolerance for clock skew

# Prod-bundle shipped check (tag-scheme-aware; used by check_component_release_status).
# shellcheck source=lib/prod-bundle.sh
source "$SCRIPT_DIR/lib/prod-bundle.sh"
# shellcheck source=lib/dockerfile-version.sh
source "$SCRIPT_DIR/lib/dockerfile-version.sh"

# FBC OCP scope and FBC_OCP_VERSIONS (canonical; single source of truth for OCP list).
# shellcheck source=lib/fbc-scope.sh
source "$SCRIPT_DIR/lib/fbc-scope.sh"

# FBC catalog/snapshot checks shared with the release gate (verify-fbc-release.sh).
# shellcheck source=lib/fbc-snapshot.sh
source "$SCRIPT_DIR/lib/fbc-snapshot.sh"

# Count derived from FBC_OCP_VERSIONS (sourced above) so status output can't drift
# behind the list.
read -ra _OCP_VERSION_ARR <<< "$FBC_OCP_VERSIONS"
readonly CURRENT_OCP_VERSION_COUNT=${#_OCP_VERSION_ARR[@]}

# Submariner component repos (for branch checks)
readonly SUBMARINER_REPOS="submariner-operator submariner lighthouse shipyard subctl admiral cloud-prepare"

# Step Metadata: number|name|phase|stream|workflow|check-numbers
# stream: Y=Y-stream only, Z=Z-stream only, B=both
# check-numbers: optional, for multi-step checks (e.g., "12-13")
declare -a RELEASE_STEPS=(
  # Phase 1: Upstream Preparation (Y-stream only)
  "1|Upstream Release Branch|upstream-prep|Y|create-release-branch.md|"
  "2|Konflux ReleasePlans|upstream-prep|Y|configure-downstream.md|"

  # Phase 2: Component Preparation
  "3|Component Tekton Config|component-prep|Y|fix-tekton-prs.md|"
  "3b|Bundle Tekton Config|component-prep|Y|fix-tekton-bundle.md|"
  "4|Enterprise Contract|component-prep|B|fix-ec-violations.md|"
  "5|CVE Scanning|component-prep|B|scan-cves.md|"
  "5b|Version Labels|component-prep|Z|update-version-labels.md|"

  # Phase 3: Upstream Release
  "6|Upstream Release|upstream-release|B|cut-upstream-release.md|"
  "7|Bundle SHAs|upstream-release|B|update-bundle-shas.md|"

  # Phase 4: Component Stage
  "8_10|Component Stage Release|component-stage|B|create-release.md|8-10"
  "10b|Check Stage Build|component-stage|B|check-component-release.md|"

  # Phase 5: FBC Stage
  "11|FBC Catalog Update|fbc-stage|B|update-fbc-stage.md|"
  "12_13|FBC Stage Releases|fbc-stage|B|create-fbc-stage-release.md|12-13"
  "13b|Check FBC Stage|fbc-stage|B|check-fbc-releases.md|"
  "14|QE Approval|fbc-stage|B|share-with-qe.md|"

  # Phase 6: Component Prod
  "15_16|Component Prod Release|component-prod|B|create-prod-release.md|15-16"
  "16b|Check Prod Build|component-prod|B|check-component-release.md|"

  # Phase 7: FBC Prod
  "17_18|FBC Prod Releases|fbc-prod|B|create-fbc-prod-release.md|17-18"
  "18b|Check FBC Prod|fbc-prod|B|check-fbc-releases.md|"
  "19|Share Prod with QE|fbc-prod|B|share-with-qe.md|"
  "20|Update FBC Templates|fbc-prod|B|update-fbc-templates-prod.md|"
)

# Phase display names (for section headers)
declare -A PHASE_NAMES=(
  ["upstream-prep"]="BRANCH & CONFIGURATION SETUP"
  ["component-prep"]="CI/CD & QUALITY CHECKS"
  ["upstream-release"]="UPSTREAM & BUILD PREPARATION"
  ["component-stage"]="STAGE RELEASE"
  ["fbc-stage"]="FBC STAGE RELEASE"
  ["component-prod"]="PRODUCTION RELEASE"
  ["fbc-prod"]="FBC PRODUCTION RELEASE"
)

# ============================================================================
# Common Helper Functions
# ============================================================================

# Get snapshot test status annotation
# Args: $1=snapshot_name
# Returns: JSON test status or empty string
get_snapshot_test_status() {
  local snapshot=$1
  if [ "$snapshot" = "${SNAPSHOT:-}" ] && [ -n "${SNAPSHOT_JSON:-}" ]; then
    jq -r '.metadata.annotations["test.appstudio.openshift.io/status"] // empty' <<< "$SNAPSHOT_JSON"
  else
    oc get snapshot "$snapshot" -n submariner-tenant \
      -o jsonpath='{.metadata.annotations.test\.appstudio\.openshift\.io/status}' 2>/dev/null || true
  fi
}

# shellcheck source=lib/integration-tests.sh
source "$SCRIPT_DIR/lib/integration-tests.sh"
get_snapshot_ec_status() {
  if [ "$1" = "${SNAPSHOT:-}" ] && [ -n "${SNAPSHOT_JSON:-}" ]; then
    ec_status_from_snapshot <<< "$SNAPSHOT_JSON"
  else
    oc get snapshot "$1" -n submariner-tenant -o json 2>/dev/null | ec_status_from_snapshot
  fi
}

# Pin status to the recorded candidate, or inspect the newest branch build before
# one is selected. Lookup failure is unknown, never evidence that no builds exist.
load_component_snapshot() {
  SNAPSHOT="" SNAPSHOT_JSON="" SNAPSHOT_READY=false SNAPSHOT_LOOKUP_FAILED=false
  local snapshots target="" record="${PROD_YAML:-${STAGE_YAML:-}}" data
  if [ "$OC_AVAILABLE" != true ]; then
    SNAPSHOT_LOOKUP_FAILED=true
    return
  fi
  if [ -n "$record" ]; then
    target=$(yq -r '.spec.snapshot // ""' "$record") || { SNAPSHOT_LOOKUP_FAILED=true; return; }
    [ -n "$target" ] || { SNAPSHOT_LOOKUP_FAILED=true; return; }
  elif [ -n "${TRACKER_KEY:-}" ]; then
    data=$(get_step "$VERSION" bundleShas "$TRACKER_KEY") || { SNAPSHOT_LOOKUP_FAILED=true; return; }
    target=$(jq -r '.data.snapshot // empty' <<< "$data") || { SNAPSHOT_LOOKUP_FAILED=true; return; }
  fi
  if ! snapshots=$(oc get snapshots -n submariner-tenant -o json --request-timeout=60s 2>/dev/null) ||
     ! jq -e '(.items | type) == "array"' >/dev/null 2>&1 <<< "$snapshots"; then
    SNAPSHOT_LOOKUP_FAILED=true
    return
  fi
  if [ -n "$target" ]; then
    SNAPSHOT_JSON=$(jq -c --arg name "$target" --arg app "submariner-$MAJOR_MINOR_DASH" \
      '.items[] | select(.metadata.name == $name and .spec.application == $app)' <<< "$snapshots")
    if [ -z "$SNAPSHOT_JSON" ]; then
      echo "⚠️  Recorded candidate $target is unavailable; not substituting another snapshot"
      SNAPSHOT_LOOKUP_FAILED=true
      return
    fi
  else
    SNAPSHOT_JSON=$(latest_component_snapshot "submariner-$MAJOR_MINOR_DASH" <<< "$snapshots") || SNAPSHOT_JSON=""
  fi
  [ -n "$SNAPSHOT_JSON" ] || return 0
  SNAPSHOT=$(jq -r '.metadata.name' <<< "$SNAPSHOT_JSON")
  if component_tests_passed <<< "$SNAPSHOT_JSON"; then SNAPSHOT_READY=true; fi
}

# Helper function: Read the container-image version label from a snapshot
# Args: $1=snapshot name
# Returns: the lighthouse-agent component's image version label (e.g. "v0.22.1"),
#          or empty if the snapshot, image, or label can't be resolved. All
#          failures are swallowed so callers can use it under set -e / $(...).
get_snapshot_image_version() {
  local snapshot=$1
  local image
  image=$(oc get snapshot "$snapshot" -n submariner-tenant \
    -o jsonpath="{.spec.components[?(@.name==\"lighthouse-agent-$MAJOR_MINOR_DASH\")].containerImage}" 2>/dev/null || true)
  [ -z "$image" ] && return 0
  skopeo inspect "docker://$image" 2>/dev/null | jq -r '.Labels.version // empty' 2>/dev/null || true
}

# Format date with fallback
# Args: $1=date_string $2=format (default: '%Y-%m-%d %H:%M')
# Returns: Formatted date or original string on error
format_date() {
  local date_str=$1
  local format=${2:-%Y-%m-%d %H:%M}
  date -d "$date_str" +"$format" 2>/dev/null || echo "$date_str"
}

# Count words in space-separated string (bash-native)
# Args: $1=space_separated_string
# Returns: word count
count_words() {
  local str=$1
  [ -z "$str" ] && { echo 0; return; }
  local -a arr
  read -ra arr <<< "$str"
  echo "${#arr[@]}"
}

# Helper function: Extract metadata field from step definition
# Args: $1=step_definition $2=field_index (1=num, 2=name, 3=phase, 4=stream, 5=workflow, 6=check-numbers)
get_step_field() {
  echo "$1" | cut -d'|' -f"$2"
}

# Helper function: Check if step applies to current release stream
# Args: $1=stream_code (Y/Z/B) $2=is_zstream_bool
step_applies_to_stream() {
  local stream=$1
  local is_z=$2

  case "$stream" in
    B) return 0 ;;  # Both streams
    Y) [ "$is_z" = "false" ] && return 0 ;;
    Z) [ "$is_z" = "true" ] && return 0 ;;
  esac
  return 1
}

# Source work fixed in a delivered candidate does not become stale with age.
# Keep snapshot-dependent warnings and any incomplete source work visible.
stale_step_titles() {
  jq -r --arg source_complete "${UPSTREAM_SOURCE_TAGS_COMPLETE:-false}" \
    --arg prod_verified "${COMPONENT_PROD_STATUS:-unknown}" '
    [.steps | to_entries[] | select(.value.freshness == "stale") |
      select(.key != "cveFixes" or .value.stepData.status != "complete" or
        ($source_complete != "true" and $prod_verified != "succeeded")) |
      select(.key != "rpmLockfiles" or .value.stepData.status != "complete" or $prod_verified != "succeeded") |
      .value.title] | join(", ")'
}

# Artifact records determine historical scope, not whether anything shipped.
detect_recorded_state() {
  if [ -n "$PROD_YAML" ]; then echo prod-recorded
  elif [ -n "$STAGE_YAML" ]; then echo stage-recorded
  else echo unrecorded; fi
}

# Helper function: Infer which OCP versions were in scope for this release
# Uses date heuristic to find FBC YAMLs created around component release time
# Args:
#   $1 - Environment type ("stage" or "prod")
# Returns: space-separated list (e.g., "16 17 18 19 20")
#
# This handles the case where new OCP versions are added over time.
# E.g., 0.22.0 released with OCP 4-16 through 4-20, then 4-21 support added later
#
# NOTE: FBC YAML filenames don't contain Submariner version (catalogs are cumulative),
# so we use date-matching to find FBC YAMLs created near the component release.
get_release_ocp_scope() {
  # Thin wrapper — delegates to the canonical fbc-scope.sh implementation.
  # Argument mapping: root=RELEASE_ROOT, mm=MAJOR_MINOR, fvd=FULL_VERSION_DASH,
  # env=$1, ocp_list=FBC_OCP_VERSIONS (single source of truth from fbc-scope.sh).
  local env="${1:-prod}"
  get_fbc_ocp_scope "$RELEASE_ROOT" "$MAJOR_MINOR" "$FULL_VERSION_DASH" "$env" "$FBC_OCP_VERSIONS"
}

# Helper function: Extract date from component release YAML filename
# Args: $1 = env ("stage" or "prod")
# Returns: YYYYMMDD date string or empty
# Uses globals: MAJOR_MINOR, FULL_VERSION_DASH
# Note: sort | tail -1 picks the latest attempt = the successful release (retries
# share the version but differ by date; the FBC releases follow the successful one).
get_component_yaml_date() {
  local env=$1
  local yaml_file
  yaml_file=$(find "$RELEASE_ROOT/releases/$MAJOR_MINOR/$env/" -name "submariner-$FULL_VERSION_DASH-$env-*.yaml" 2>/dev/null | sort | tail -1)

  [ -z "$yaml_file" ] && return

  # Extract date from filename: submariner-0-22-0-stage-20251203-01.yaml → 20251203
  basename "$yaml_file" | grep -oP '\d{8}' | head -1
}

# Helper function: Find FBC YAML closest to component release date
# Args:
#   $1 = OCP version (e.g., "16" for 4-16)
#   $2 = env ("stage" or "prod")
#   $3 = target date (YYYYMMDD)
# Returns: YAML filename or empty
#
# Matches FBC YAMLs by date proximity (within ±3 days) since FBC filenames
# don't contain Submariner version (catalogs are cumulative across versions).
find_fbc_yaml_by_date() {
  local ocp_version=$1
  local env=$2
  local target_date=$3
  local target_epoch

  local exact
  exact=$(find "$RELEASE_ROOT/releases/fbc/$ocp_version/$env" -name "submariner-fbc-$ocp_version-$FULL_VERSION_DASH-$env-*.yaml" 2>/dev/null | sort | tail -1) || true
  if [ -n "$exact" ]; then echo "$exact"; return; fi

  [ -z "$target_date" ] && return

  # Convert target date to epoch for math
  target_epoch=$(date -d "$target_date" +%s 2>/dev/null || echo 0)
  [ "$target_epoch" -eq 0 ] && return

  local best_yaml=""
  local best_diff=999999

  # Search all YAMLs in directory
  for yaml in "$RELEASE_ROOT"/releases/fbc/"$ocp_version"/"$env"/submariner-fbc-"$ocp_version"-"$env"-*.yaml; do
    [ ! -f "$yaml" ] && continue

    # Extract date from filename
    local yaml_date
    yaml_date=$(basename "$yaml" | grep -oP '\d{8}' | head -1)
    [ -z "$yaml_date" ] && continue

    local yaml_epoch
    yaml_epoch=$(date -d "$yaml_date" +%s 2>/dev/null || echo 0)
    [ "$yaml_epoch" -eq 0 ] && continue

    # Calculate absolute difference
    local diff=$((yaml_epoch - target_epoch))
    local abs_diff=${diff#-}  # Remove leading minus if negative (bash abs value)

    # Within 3 days (inclusive, matching get_fbc_ocp_scope -le boundary) and closer than previous best?
    if [ "$abs_diff" -le "$FBC_DATE_MATCH_WINDOW_SECS" ] && [ "$abs_diff" -lt "$best_diff" ]; then
      best_yaml="$yaml"
      best_diff="$abs_diff"
    fi
  done

  echo "$best_yaml"
}

# Helper function: Report FBC scope with context about OCP versions
# Args:
#   $1 - Environment (stage/prod)
#   $2 - YAML count
#   $3 - Scope (space-separated OCP versions)
#   $4 - Step number for "Next" messages
# Uses global: RELEASE_STATE, CURRENT_OCP_VERSION_COUNT
report_fbc_scope() {
  local env=$1
  local yaml_count=$2
  local scope=$3
  local step_num=$4
  # A running release targets the OCP versions whose catalog lists its bundle (Step 11);
  # only fall back to every active version when that isn't known.
  local current_total=${FBC_APPLICABLE_COUNT:-$CURRENT_OCP_VERSION_COUNT}

  if [ "$yaml_count" -lt "$current_total" ]; then
    if [ "$RELEASE_STATE" = "prod-recorded" ]; then
      # For completed releases, show which OCP catalogs were cut alongside it
      # (matched by release date). We can't infer *why* another OCP version is
      # absent from this set — a later-introduced version and a pre-existing one
      # simply not re-cut inside the date window look identical — so make no
      # causal claim about when support was added.
      echo "📄 FBC $env YAMLs: $yaml_count at release time (OCP $scope)"
    else
      # For in-progress releases, incomplete scope is a blocker
      echo "⚠️  Incomplete: $yaml_count/$current_total FBC $env YAMLs"
      echo "   ⮕ Next: Create missing FBC $env releases (Step $step_num)"
    fi
  else
    echo "✅ All $yaml_count FBC $env YAMLs"
  fi
}

# Helper function: Check component release status on cluster
# Args:
#   $1 - Release name from YAML
#   $2 - Environment type ("stage" or "prod") for error messages
# Uses global: RELEASE_STATE for conditional reporting
#
# Note: Release CRs are created in submariner-tenant namespace but get archived
# after completion (visible in Konflux UI but not via 'oc get'). For completed
# prod releases, we verify via registry.redhat.io instead.
# shellcheck disable=SC2034  # component_status is a nameref consumed by the summary.
check_component_release_status() {
  local release_name=$1 env_type="${2%% *}" record status reason
  local -n component_status="COMPONENT_${env_type^^}_STATUS"
  component_status=unknown
  record=""
  if [ "$OC_AVAILABLE" = true ]; then
    if ! record=$(oc get release "$release_name" -n submariner-tenant --ignore-not-found -o json 2>/dev/null); then
      echo "   ⚠️  Could not read Release $release_name; cluster status unknown"
      record=""
    fi
  fi
  if [ -z "$record" ]; then
    if [ "$env_type" = prod ]; then
      prod_bundle_shipped "$VERSION"
      if [ "$PROD_BUNDLE_VERDICT" = shipped ]; then
        component_status=succeeded
        echo "   ✅ Released to production (verified in registry)"
        return
      fi
    fi
    echo "   ℹ️  Release success unverified (cluster record unavailable or archived)"
    return
  fi
  status=$(jq -r '.status.conditions[]? | select(.type == "Released") | .status' <<< "$record") || return
  reason=$(jq -r '.status.conditions[]? | select(.type == "Released") | .reason' <<< "$record") || return
  if [ "$status:$reason" = True:Succeeded ]; then
    if [ "$env_type" = prod ]; then
      prod_bundle_shipped "$VERSION"
      if [ "$PROD_BUNDLE_VERDICT" != shipped ]; then
        echo "   ⚠️  Release succeeded; exact production bundle is not verified ($PROD_BUNDLE_VERDICT)"
        return
      fi
    fi
    component_status=succeeded
    echo "   ✅ Release succeeded"
  elif [ "$reason" = Progressing ] || [ -z "$reason" ]; then
    component_status=in-progress
    echo "   🔄 Release in progress"
  else
    component_status=failed
    echo "   ❌ Release failed: $reason"
    echo "   ⮕ Next: Debug failure"
  fi
}

# Check component image and binary versions from the release branch.
# Args:
#   $1 - GitHub repo name (e.g., "submariner-operator")
#   $2 - Dockerfile path in repo
#   $3 - Whether it builds Go binaries
# Uses globals: MAJOR_MINOR (for branch reference)
# Modifies globals: INCORRECT array (appends mismatches), FETCH_FAILED counter
#   (incremented when a Dockerfile can't be fetched — so a total GitHub outage is
#   not mistaken for "all labels correct")
check_component_version() {
  local repo=$1
  local file=$2
  local has_binary=$3
  local content

  content=$(gh api "repos/submariner-io/$repo/contents/$file?ref=release-$MAJOR_MINOR" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null || true)
  if [ -z "$content" ]; then
    echo "   ⚠️  Cannot fetch $repo/$file" >&2
    FETCH_FAILED=$((FETCH_FAILED + 1))
    return
  fi

  if ! component_version_matches "$content" "$VERSION" "$has_binary"; then
    INCORRECT+=("$repo/$file (image or compiled version)")
  fi
}

# Helper function: Detect current release phase based on workflow state
# Returns one of: upstream-prep, component-prep, upstream-release, fbc-stage,
#                 qe-approval, component-prod, complete
#
# Uses globals (set by step check functions):
#   RELEASE_STATE, IS_ZSTREAM, VERSION, SNAPSHOT
#   Y-stream: BRANCH_CHECK, STAGE_PLAN, PROD_PLAN, MISSING_TEKTON
#   Build: TAG_EXISTS, WRONG_COUNT, FETCH_FAILED, IMAGE_VERSION, IMAGE_VERSION_FETCHED
#   Stage: FBC_STAGE_YAML_COUNT, FBC_SUCCEEDED
#   Prod: FBC_PROD_YAML_COUNT
detect_current_phase() {
  # YAML records show intent; shipping requires successful releases or registry
  # evidence. Incomplete and unavailable evidence must not report Complete.
  if [ -n "$PROD_YAML" ]; then
    local ocp
    for ocp in ${FBC_STAGE_SCOPE:-}; do
      if [[ " ${FBC_PROD_SCOPE:-} " != *" $ocp "* ]]; then echo component-prod; return; fi
    done
    if [ "${COMPONENT_PROD_STATUS:-unknown}" != succeeded ] ||
       [ "$FBC_PROD_YAML_COUNT" -eq 0 ] ||
       [ "$FBC_PROD_YAML_COUNT" -lt "$FBC_STAGE_YAML_COUNT" ] ||
       [ "$FBC_PROD_SUCCEEDED" -lt "$FBC_PROD_YAML_COUNT" ]; then
      echo component-prod
    else
      echo complete
    fi
    return
  fi

  # For in-progress releases, check blockers in workflow order
  # Y-stream blockers first (early exit pattern)
  if [ "$IS_ZSTREAM" = "false" ]; then
    [ -z "$BRANCH_CHECK" ] && echo "upstream-prep" && return
    [ -z "$STAGE_PLAN" ] || [ -z "$PROD_PLAN" ] && echo "upstream-prep" && return
    [ "$MISSING_TEKTON" -gt 0 ] && echo "component-prep" && return
  fi

  # Common blockers (apply to both Y and Z streams)
  [ "${TAG_FETCH_FAILED:-0}" -gt 0 ] && echo upstream-release && return
  [ -z "$TAG_EXISTS" ] && echo "upstream-release" && return
  [ "$WRONG_COUNT" -gt 0 ] && echo "upstream-release" && return
  # Couldn't read the Dockerfiles (GitHub outage) — don't advance past the label
  # gate on unverified data; stay conservative until a re-run can confirm.
  [ "${FETCH_FAILED:-0}" -gt 0 ] && echo "upstream-release" && return
  [ -z "$SNAPSHOT" ] && echo "upstream-release" && return
  [ "${SNAPSHOT_READY:-false}" != true ] && echo upstream-release && return

  # Reuse IMAGE_VERSION from test verification if available, otherwise fetch
  local image_version_local="$IMAGE_VERSION"
  if [ "$IMAGE_VERSION_FETCHED" != "true" ]; then
    image_version_local=$(get_snapshot_image_version "$SNAPSHOT")
  fi

  [ "$image_version_local" != "v$VERSION" ] && echo "upstream-release" && return

  if [ -z "$STAGE_YAML" ] || [ "${COMPONENT_STAGE_STATUS:-unknown}" != succeeded ]; then
    echo component-stage
    return
  fi

  [ "$FBC_STAGE_YAML_COUNT" -eq 0 ] && echo "fbc-stage" && return
  [ "$FBC_SUCCEEDED" -lt "$FBC_STAGE_YAML_COUNT" ] && echo "fbc-stage" && return

  # Production intent and evidence are handled above; remaining stage work waits for QE.
  echo "qe-approval"
}

# Helper function: Check FBC release status across OCP versions in scope
# Args:
#   $1 = environment (stage/prod)
#   $2 = scope (space-separated OCP versions, e.g., "16 17 18 19 20") [optional, defaults to all]
# Sets globals: FBC_NOT_APPLIED, FBC_IN_PROGRESS, FBC_SUCCEEDED, FBC_FAILED (for stage)
#              FBC_PROD_NOT_APPLIED, FBC_PROD_IN_PROGRESS, FBC_PROD_SUCCEEDED, FBC_PROD_FAILED (for prod)
check_fbc_release_status() {
  local env=$1
  local scope="${2:-$FBC_OCP_VERSIONS}"  # Default to all if not specified

  # Determine variable prefix based on environment: FBC_* for stage, FBC_PROD_*
  # for prod. Bind namerefs to the prefixed globals so consumers (detect_current_phase
  # and the summary printers) read the same variables, without eval'ing dynamic names.
  local prefix=""
  [ "$env" = "prod" ] && prefix="PROD_"

  local -n not_applied="FBC_${prefix}NOT_APPLIED"
  local -n in_progress="FBC_${prefix}IN_PROGRESS"
  local -n succeeded="FBC_${prefix}SUCCEEDED"
  local -n failed="FBC_${prefix}FAILED"
  local -n unknown="FBC_${prefix}UNKNOWN"
  unknown=0
  not_applied=0
  in_progress=0
  succeeded=0
  failed=0

  # Loop through OCP versions in scope
  for ocp_version in $scope; do
    local record component_date fbc_release release_json fbc_status fbc_reason verdict
    component_date=$(get_component_yaml_date "$env")
    record=$(find_fbc_yaml_by_date "$ocp_version" "$env" "$component_date")
    if [ -z "$record" ]; then
      unknown=$((unknown + 1))
      continue
    fi
    fbc_release=$(yq -r '.metadata.name' "$record")
    release_json=""
    if [ "$OC_AVAILABLE" = true ]; then
      release_json=$(oc get release "$fbc_release" -n submariner-tenant --ignore-not-found -o json 2>/dev/null) || release_json=""
    fi
    if [ -z "$release_json" ]; then
      verdict=unreachable
      [ "$env" != prod ] || verdict=$(prod_index_has_bundle "$ocp_version" "$VERSION")
      case "$verdict" in
        present) succeeded=$((succeeded + 1)) ;;
        absent) not_applied=$((not_applied + 1)) ;;
        *) unknown=$((unknown + 1)) ;;
      esac
    else
      fbc_status=$(jq -r '.status.conditions[]? | select(.type == "Released") | .status' <<< "$release_json") || fbc_status=""
      fbc_reason=$(jq -r '.status.conditions[]? | select(.type == "Released") | .reason' <<< "$release_json") || fbc_reason=""
      if [ "$fbc_status:$fbc_reason" = True:Succeeded ]; then
        if [ "$env" = prod ]; then
          verdict=$(prod_index_has_bundle "$ocp_version" "$VERSION")
          case "$verdict" in
            present) succeeded=$((succeeded + 1)) ;;
            absent) not_applied=$((not_applied + 1)) ;;
            *) unknown=$((unknown + 1)) ;;
          esac
        else
          succeeded=$((succeeded + 1))
        fi
      elif [ "$fbc_reason" = Progressing ]; then
        in_progress=$((in_progress + 1))
      elif [ -n "$fbc_reason" ]; then
        failed=$((failed + 1))
      else
        unknown=$((unknown + 1))
      fi
    fi
  done
  local total
  total=$(count_words "$scope")
  if [ "$succeeded" -eq "$total" ]; then
    echo "   ✅ FBC $env success verified: $succeeded/$total"
  else
    echo "   ℹ️  FBC $env success verified: $succeeded/$total"
    [ "$unknown" -eq 0 ] || echo "   ⚠️  Success unverified: $unknown/$total"
    [ "$in_progress" -eq 0 ] || echo "   🔄 In progress: $in_progress/$total"
    [ "$failed" -eq 0 ] || echo "   ❌ Failed releases: $failed/$total — inspect release failures"
    [ "$not_applied" -eq 0 ] || echo "   ❌ Bundle absent from production indexes: $not_applied/$total"
  fi
  return 0
}

# ============================================================================
# Check Functions (one per workflow step)
# ============================================================================

# Step 1: Release Branch
check_step_1() {
  local missing_count=0
  local missing_repos=()

  for repo in $SUBMARINER_REPOS; do
    local branch_check ls_output
    # ls-remote exits 0 even when the ref is genuinely absent (empty output), and
    # non-zero only when GitHub is unreachable. Capture its exit directly (no pipe,
    # which pipefail+`|| true` would otherwise mask) so drift can tell "branch
    # missing" from "couldn't reach GitHub". Either way it still displays as missing.
    if ls_output=$(timeout 30 git ls-remote --heads "https://github.com/submariner-io/$repo" "refs/heads/release-$MAJOR_MINOR" 2>/dev/null); then
      branch_check=$(printf '%s' "$ls_output" | grep -o "refs/heads/release-$MAJOR_MINOR" || true)
      if [ -z "$branch_check" ]; then
        missing_repos+=("$repo")
        missing_count=$((missing_count + 1))
      fi
    else
      BRANCH_FETCH_FAILED=$((BRANCH_FETCH_FAILED + 1))
      missing_repos+=("$repo")
      missing_count=$((missing_count + 1))
    fi
  done

  local total_repos
  total_repos=$(count_words "$SUBMARINER_REPOS")

  if [ "$BRANCH_FETCH_FAILED" -gt 0 ]; then
    echo "⚠️  Branch checks inconclusive: $BRANCH_FETCH_FAILED GitHub lookup failure(s)"
    echo "   ⮕ Next: Restore GitHub access and re-run before creating branches"
  elif [ "$missing_count" -eq 0 ]; then
    echo "✅ release-$MAJOR_MINOR branches exist ($total_repos repos)"
  else
    echo "❌ Missing release-$MAJOR_MINOR: $missing_count/$total_repos repos"
    for repo in "${missing_repos[@]}"; do
      echo "   - $repo"
    done
    echo "   ⮕ Next: Create upstream release branches (Step 1)"
  fi

  BRANCH_CHECK=$( [ "$missing_count" -eq 0 ] && echo "all" || echo "" )
}

# Step 2: Konflux ReleasePlans
check_step_2() {
  if [ "$OC_AVAILABLE" = true ]; then
    local plans
    RELEASEPLANS_LOOKUP_FAILED=false
    if ! plans=$(oc get releaseplans -n submariner-tenant -o json 2>/dev/null) ||
       ! jq -e '(.items | type) == "array"' >/dev/null 2>&1 <<< "$plans"; then
      RELEASEPLANS_LOOKUP_FAILED=true
      echo "⚠️  ReleasePlans unverified (cluster access/query failure)"
      return
    fi
    STAGE_PLAN=$(jq -r --arg name "submariner-release-plan-stage-$MAJOR_MINOR_DASH" '.items[] | select(.metadata.name == $name) | .metadata.name' <<< "$plans")
    PROD_PLAN=$(jq -r --arg name "submariner-release-plan-prod-$MAJOR_MINOR_DASH" '.items[] | select(.metadata.name == $name) | .metadata.name' <<< "$plans")

    if [ -n "$STAGE_PLAN" ] && [ -n "$PROD_PLAN" ]; then
      echo "✅ ReleasePlans deployed"
    elif [ -n "$STAGE_PLAN" ] || [ -n "$PROD_PLAN" ]; then
      echo "⚠️  Partial: $([ -n "$STAGE_PLAN" ] && echo "stage" || echo "prod") only"
      echo "   ⮕ Next: Complete downstream configuration (Step 2)"
    else
      echo "❌ ReleasePlans not deployed to cluster"
      echo "   ⮕ Next: Wait for ArgoCD sync or configure downstream (Step 2)"
    fi
  else
    # Fallback: Check repo for configuration files
    OVERLAY_PATH="$KONFLUX_RELEASE_DATA_PATH/tenants-config/cluster/kflux-prd-rh02/tenants/submariner-tenant/overlay/application-submariner/$MAJOR_MINOR_DASH-overlay"

    if [ -d "$OVERLAY_PATH" ]; then
      # Check if release plan patches exist
      if ls "$OVERLAY_PATH"/*release-plan*.yaml &>/dev/null; then
        echo "✅ ReleasePlans configured in repo (cluster status unknown)"
      else
        echo "⚠️  Overlay exists but no release plan patches found"
        echo "   ⮕ Next: Complete downstream configuration (Step 2)"
      fi
    else
      echo "❌ ReleasePlans not configured"
      echo "   ⮕ Next: Configure downstream release (Step 2)"
    fi
  fi
}

# Step 3: Component Tekton Config
check_step_3() {
  local missing_repos=()
  local tekton_count gh_rc err_file
  err_file=$(mktemp)

  for repo in submariner-operator submariner lighthouse shipyard subctl; do
    # gh api 404s (non-zero) both when .tekton is genuinely absent AND when the
    # release branch doesn't exist yet — both mean "step 3 not done". Any OTHER
    # error (401/403/rate-limit/network) means "couldn't reach GitHub", which must
    # NOT be reported as drift. Distinguish a definitive HTTP 404 from everything
    # else; when unclear, count it a fetch failure (the safe, no-false-warning side).
    tekton_count=$(gh api "repos/submariner-io/$repo/contents/.tekton?ref=release-$MAJOR_MINOR" --jq 'length' 2>"$err_file") && gh_rc=0 || gh_rc=$?

    if [ "$gh_rc" -ne 0 ]; then
      grep -q 'HTTP 404' "$err_file" || TEKTON_FETCH_FAILED=$((TEKTON_FETCH_FAILED + 1))
      missing_repos+=("$repo")
      MISSING_TEKTON=$((MISSING_TEKTON + 1))
      continue
    fi

    if [ "$tekton_count" = "0" ] || ! echo "$tekton_count" | grep -qE '^[0-9]+$'; then
      missing_repos+=("$repo")
      MISSING_TEKTON=$((MISSING_TEKTON + 1))
    fi
  done
  rm -f "$err_file"

  if [ "$TEKTON_FETCH_FAILED" -gt 0 ]; then
    echo "⚠️  Tekton configuration unverified: $TEKTON_FETCH_FAILED GitHub lookup failure(s)"
    echo "   ⮕ Next: Restore access and re-run before preparing configuration changes"
  elif [ "$MISSING_TEKTON" -eq 0 ]; then
    echo "✅ All 5 repos configured"
  else
    echo "❌ Missing Tekton configs: $MISSING_TEKTON/5"
    for repo in "${missing_repos[@]}"; do
      echo "   - $repo"
    done
    echo "   ⮕ Next: Fix Tekton config PRs (Step 3)"
  fi
}

# Step 3b: Bundle Tekton Config
check_step_3b() {
  # Reuse snapshot from global scope (fetched before step checks)
  if [ -n "$SNAPSHOT" ]; then
    local bundle_in_snapshot
    bundle_in_snapshot=$(oc get snapshot "$SNAPSHOT" -n submariner-tenant \
      -o jsonpath="{.spec.components[?(@.name==\"submariner-bundle-$MAJOR_MINOR_DASH\")].name}" 2>/dev/null || true)

    if [ -n "$bundle_in_snapshot" ]; then
      local test_status
      test_status=$(get_snapshot_test_status "$SNAPSHOT")

      if [ -n "$test_status" ]; then
        local ec_passed
        ec_passed=$(get_snapshot_ec_status "$SNAPSHOT")

        if [[ "$ec_passed" == TestPassed || "$ec_passed" == TestWarning || "$ec_passed" == BuildPLRInProgress ]]; then
          echo "✅ Bundle configured and passing EC"
        else
          echo "⚠️  Bundle EC is not verified successful: $ec_passed"
          echo "   ⮕ Next: Inspect bundle integration results (Step 4)"
        fi
      else
        echo "⚠️  Bundle in snapshot, no test status"
      fi
    else
      echo "❌ Bundle not in snapshot"
      echo "   ⮕ Next: Fix bundle Tekton config (Step 3b)"
    fi
  else
    echo "⚠️  Bundle build unverified: no accessible branch-build snapshot"
  fi
}

# Step 4: Enterprise Contract Validation
check_step_4() {
  if [ -z "$SNAPSHOT" ]; then
    echo "⚠️  Unverified: no accessible component snapshot"
  else
    local test_status
    test_status=$(get_snapshot_test_status "$SNAPSHOT")

    if [ -n "$test_status" ]; then
      local ec_failed
      ec_failed=$(get_snapshot_ec_status "$SNAPSHOT")

      case "$ec_failed" in
        TestPassed|TestWarning|BuildPLRInProgress) echo "✅ EC validation finished successfully" ;;
        TestFail|TestFailed|TestError)
          echo "❌ EC violations detected: $ec_failed"
          echo "   ⮕ Next: Inspect the candidate's EC report and repair demonstrated failures" ;;
        *)
          echo "⚠️  EC unverified or unfinished: $ec_failed"
          echo "   ⮕ Next: Wait or restore access; inspect aggregate and scenario completion evidence" ;;
      esac
    else
      echo "⚠️  No test status available"
    fi
  fi
}

# Step 5: CVE Scanning
check_step_5() {
  UPSTREAM_SOURCE_TAGS_COMPLETE=false
  local repo tag_ls tag_rc all_tagged=true tag_unknown=false
  TAG_EXISTS="" TAG_FETCH_FAILED=0 MISSING_TAG_REPOS=""
  for repo in submariner-operator submariner lighthouse shipyard subctl; do
    tag_rc=0
    tag_ls=$(timeout 30 git ls-remote --tags "https://github.com/submariner-io/$repo" "refs/tags/v$VERSION" 2>/dev/null) || tag_rc=$?
    if [ "$tag_rc" -ne 0 ]; then
      tag_unknown=true
    elif [ -z "$tag_ls" ]; then
      all_tagged=false
      MISSING_TAG_REPOS+=" $repo"
    fi
  done
  if $tag_unknown; then
    TAG_FETCH_FAILED=1
    echo "⚠️  Could not verify v$VERSION tags on all five component repositories"
    echo "   Confirm completed upstream work before skipping it; do not move existing tags"
  elif $all_tagged; then
    UPSTREAM_SOURCE_TAGS_COMPLETE=true
    TAG_EXISTS="v$VERSION"
    echo "✅ Reuse completed upstream CVE work: v$VERSION exists on all five component repos"
  else
    echo "ℹ️  Upstream tag set is incomplete; review source CVE work and release completion"
  fi
  if [ -n "$SNAPSHOT" ]; then
    echo "   - Downstream: review scan evidence for the exact snapshot $SNAPSHOT"
  else
    echo "   - Downstream scan evidence is unverified without an accessible candidate"
  fi
  echo "   - Reuse approved evidence only when its source/image identities still match"
}

# Step 5b: Version Labels
check_step_5b() {
  # INCORRECT array and FETCH_FAILED counter are populated by check_component_version
  # (not local - shared with helper). FETCH_FAILED tracks Dockerfiles we couldn't
  # read, so a GitHub outage isn't misreported as "all labels correct".
  INCORRECT=()
  FETCH_FAILED=0

  if [ -n "${PROD_YAML:-${STAGE_YAML:-}}" ]; then
    echo "ℹ️  A recorded snapshot anchors this release; current branch versions may have advanced"
    echo "   Verify image labels and binary versions in the recorded candidate, not today's branch"
    return
  fi

  local repo file has_binary
  for repo in $COMPONENT_VERSION_REPOS; do
    has_binary=true
    [ "$repo" != shipyard ] || has_binary=false
    for file in ${COMPONENT_DOCKERFILES[$repo]}; do
      check_component_version "$repo" "$file" "$has_binary"
    done
  done

  WRONG_COUNT=${#INCORRECT[@]}
  if [ "$WRONG_COUNT" -gt 0 ]; then
    echo "❌ $WRONG_COUNT version label(s) need update:"
    for f in "${INCORRECT[@]}"; do
      echo "   - $f"
    done
    echo "   ⮕ Next: Update version labels (Step 5b)"
  elif [ "$FETCH_FAILED" -gt 0 ]; then
    echo "⚠️  Inconclusive: could not fetch $FETCH_FAILED Dockerfile(s) (GitHub auth/network)"
    echo "   ⮕ Next: Restore GitHub access, then re-run to verify version labels (Step 5b)"
  else
    echo "✅ All 8 component Dockerfiles have matching image and compiled versions"
    echo "   Bundle version is updated with its CSV in Step 7"
  fi
}

# Step 6: Upstream Release
check_step_6() {
  # Step 5 already checked all five exact refs, including lookup failures.
  if [ -n "$TAG_EXISTS" ]; then
    # Get tag object URL, fetch tag details, extract date
    local tag_date
    tag_date=$(gh api "repos/submariner-io/submariner-operator/git/refs/tags/v$VERSION" \
      --jq '.object.url' 2>/dev/null | xargs gh api 2>/dev/null | jq -r '.tagger.date // .committer.date // empty' || true)
    if [ -n "$tag_date" ]; then
      local formatted_date
      formatted_date=$(format_date "$tag_date" '%Y-%m-%d %H:%M UTC')
      echo "✅ v$VERSION tags exist on all five component repos (operator tag created $formatted_date)"
    else
      echo "✅ v$VERSION tags exist on all five component repos"
    fi
  elif [ "$TAG_FETCH_FAILED" -gt 0 ]; then
    echo "⚠️  Upstream tag set unverified (GitHub auth/network)"
    echo "   ⮕ Next: Restore access and verify all five refs; never move existing tags"
  else
    echo "❌ Missing v$VERSION tags:${MISSING_TAG_REPOS:- unknown}"
    echo "   ⮕ Next: Complete the missing upstream releases (Step 6); preserve existing tags"
  fi
}

# Step 7: Component Snapshots and Bundle SHAs
check_step_7() {
  # Reuse snapshot from global scope (fetched before step checks)
  if [ -z "$SNAPSHOT" ]; then
    if [ "$SNAPSHOT_LOOKUP_FAILED" = true ]; then
      echo "⚠️  Component snapshots unverified (cluster/Jira access or recorded candidate unavailable)"
      echo "   ⮕ Next: Restore access and re-run; do not infer missing builds"
    else
      echo "❌ No qualifying branch-build component snapshot found"
      echo "   ⮕ Next: Verify builds on release-$MAJOR_MINOR and wait for a snapshot"
    fi
  else
    local snapshot_age formatted_age
    snapshot_age=$(oc get snapshot "$SNAPSHOT" -n submariner-tenant -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null || true)
    if [ -n "$snapshot_age" ]; then
      formatted_age=$(format_date "$snapshot_age")
      echo "📸 Snapshot: $SNAPSHOT ($formatted_age)"
    else
      echo "📸 Snapshot: $SNAPSHOT"
    fi

    local test_status
    test_status=$(get_snapshot_test_status "$SNAPSHOT")

    if [ -n "$test_status" ]; then
      local all_passed total_tests
      all_passed=$(echo "$test_status" | jq '[.[] | select(.status == "TestPassed" or .status == "BuildPLRInProgress")] | length' 2>/dev/null || echo 0)
      total_tests=$(echo "$test_status" | jq '. | length' 2>/dev/null || echo 0)

      if [ "$SNAPSHOT_READY" = true ]; then
        echo "   ✅ All tests finished successfully ($total_tests scenarios)"

        IMAGE_VERSION=$(get_snapshot_image_version "$SNAPSHOT")
        IMAGE_VERSION_FETCHED=true

        if [ -z "$IMAGE_VERSION" ]; then
          :  # no lighthouse-agent image or unlabeled — can't verify labels here
        elif [ "$IMAGE_VERSION" = "v$VERSION" ]; then
          echo "   ✅ Lighthouse-agent image label: v$VERSION"
        else
          echo "   ⚠️  Lighthouse-agent image label: $IMAGE_VERSION (expected v$VERSION)"
          echo "      Snapshot built before label update - needs rebuild"
          echo "   ⮕ Next: Wait for rebuild after version label PRs merge (~15-30 min)"
        fi
      else
        echo "   ⚠️  Integration not ready: $all_passed/$total_tests passed markers"
        echo "   ⮕ Next: Inspect aggregate conditions and completed scenario results"
      fi
    else
      echo "   ⚠️  No test status available"
    fi
  fi

  # Sub-heading only — the top-level "[Step 7] Bundle SHAs" header is already
  # printed by the main loop (line ~1298). Reusing that exact format here made
  # the header appear twice per run and mislabeled the snapshot section above as
  # "Bundle SHAs". A distinct sub-heading separates the two sub-sections cleanly.
  echo ""
  echo "Bundle SHAs:"

  # For completed releases: check bundle against snapshot in release YAML
  # For pre-release: check bundle against latest snapshot
  local release_snapshot=""
  if [ -n "$STAGE_YAML" ]; then
    release_snapshot=$(awk '/^  snapshot:/ {print $2}' "$STAGE_YAML" 2>/dev/null || true)
  fi

  # Use release snapshot if exists, otherwise latest
  local check_snapshot="${release_snapshot:-$SNAPSHOT}"

  if [ -n "$check_snapshot" ]; then
    local snapshot_time
    snapshot_time=$(oc get snapshot "$check_snapshot" -n submariner-tenant -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null || true)

    if [ -n "$snapshot_time" ]; then
      local snapshot_epoch
      snapshot_epoch=$(date -d "$snapshot_time" +%s 2>/dev/null || echo 0)

      # Get bundle CSV last commit time
      local bundle_csv_date
      bundle_csv_date=$(gh api "repos/submariner-io/submariner-operator/commits?path=bundle/manifests/submariner.clusterserviceversion.yaml&sha=release-$MAJOR_MINOR" \
        --jq '.[0].commit.committer.date' 2>/dev/null || true)

      if [ -n "$bundle_csv_date" ] && [ "$snapshot_epoch" -gt 0 ]; then
        local bundle_epoch time_diff
        bundle_epoch=$(date -d "$bundle_csv_date" +%s 2>/dev/null || echo 0)

        # Bundle should be updated AFTER snapshot (allow small clock skew)
        time_diff=$((bundle_epoch - snapshot_epoch))
        if [ "$time_diff" -ge "-$BUNDLE_CLOCK_SKEW_SECS" ]; then
          local formatted_bundle_date
          formatted_bundle_date=$(format_date "$bundle_csv_date")
          if [ -n "$release_snapshot" ]; then
            echo "ℹ️  Bundle CSV committed after the recorded snapshot ($formatted_bundle_date)"
          else
            echo "ℹ️  Bundle CSV committed after the snapshot ($formatted_bundle_date)"
          fi
          echo "   Timing alone does not verify image digests; validate the rebuilt bundle before release"
        else
          local formatted_bundle_date
          formatted_bundle_date=$(format_date "$bundle_csv_date" '%Y-%m-%d')
          echo "❌ Bundle outdated ($formatted_bundle_date, older than snapshot)"
          echo "   ⮕ Next: Update bundle SHAs (Step 7)"
        fi
      else
        echo "⚠️  Cannot verify bundle age"
      fi
    else
      echo "⚠️  Cannot get snapshot timestamp"
    fi
  else
    echo "⚠️  Unverified: no accessible component snapshot"
  fi
}

# Step 8-10: Component Stage Release
check_step_8_10() {
  if [ -z "$STAGE_YAML" ]; then
    echo "❌ No stage release YAML"
    echo "   ⮕ Next: Create stage release (Step 8)"
  else
    echo "📄 Stage YAML: $(basename "$STAGE_YAML")"

    # Check if release notes present (Step 9)
    if grep -q "releaseNotes:" "$STAGE_YAML" 2>/dev/null; then
      echo "   ✅ Release notes present"
    else
      echo "   ⚠️  No release notes"
      echo "   ⮕ Next: Add release notes (Step 9)"
    fi

    # Check if applied to cluster (Step 10)
    local release_name
    release_name=$(awk '/^  name:/ {print $2}' "$STAGE_YAML" 2>/dev/null || true)
    check_component_release_status "$release_name" "stage (Step 10)"
  fi
}

# Step 10b: Check Stage Build
check_step_10b() {
  echo "⏭️  Skipped (status in Step 8-10)"
}

# Step 11 while the release is running: is this release's bundle in the FBC catalog, and
# does every OCP version it applies to have a passing push snapshot built from a revision
# that contains it? Mirrors the gate (verify-fbc-release.sh), so a ✅ here means Step 12
# will not refuse. The old check only looked at each OCP version's newest snapshot, so a
# green snapshot from the previous release read as "catalog updated".
#
# Applicability comes from the catalog itself: the bundle file exists only in the catalogs
# the release targets (0.23.x is not in 4-22/5-0), so the release's OCP set is not always
# FBC_OCP_VERSIONS.
# Sets: FBC_CATALOG_READY (true|false|unknown) and FBC_APPLICABLE_COUNT
check_fbc_catalog_live() {
  FBC_CATALOG_READY=false
  FBC_APPLICABLE_COUNT=""
  local ocp digest digests="" unreadable="" applicable=""

  for ocp in $FBC_OCP_VERSIONS; do
    if ! digest=$(fbc_catalog_bundle_digest "$ocp" "$VERSION"); then
      unreadable="$unreadable ${ocp//-/.}"
      continue
    fi
    [ -z "$digest" ] && continue
    applicable="$applicable $ocp"
    digests+="$digest"$'\n'
  done
  applicable=${applicable# }

  if [ -n "$unreadable" ]; then
    echo "⚠️  Could not read the FBC catalog for OCP${unreadable} (GitHub unreachable?)"
    echo "   Step 11 unverified — re-run when reachable"
    FBC_CATALOG_READY=unknown
    return
  fi
  if [ -z "$applicable" ]; then
    echo "❌ Bundle v$VERSION not in the FBC catalog on main"
    echo "   ⮕ Next: Update FBC catalog (Step 11)"
    return
  fi
  FBC_APPLICABLE_COUNT=$(count_words "$applicable")
  if [ "$(printf '%s' "$digests" | sort -u | wc -l)" -gt 1 ]; then
    echo "❌ FBC catalogs list different bundle digests for v$VERSION"
    echo "   ⮕ Next: Re-run the FBC catalog update (Step 11)"
    return
  fi
  local main_digest=${digests%%$'\n'*}

  local all_snapshots
  if ! all_snapshots=$(oc get snapshots -n submariner-tenant -o json 2>/dev/null) || [ -z "$all_snapshots" ]; then
    echo "⚠️  Could not list snapshots (oc login?) — FBC snapshots unverified"
    FBC_CATALOG_READY=unknown
    return
  fi

  local no_snapshot="" stale="" not_passing="" unknown_rev="" snap name revision tests rev_digest reason
  for ocp in $applicable; do
    # Push builds only (never PR retests), like the gate. Newest first pick.
    snap=$(jq -c --arg app "submariner-fbc-$ocp" '
      [.items[]
        | select(.spec.application == $app and (.spec.components | length) == 1 and .spec.components[0].name == $app)
        | select(.metadata.labels["pac.test.appstudio.openshift.io/original-prname"] == ($app + "-on-push"))
        | select(.metadata.labels["pac.test.appstudio.openshift.io/event-type"] as $e
            | $e == "push" or $e == "incoming" or $e == "retest-all-comment")]
      | sort_by(.metadata.creationTimestamp) | last // empty' <<< "$all_snapshots" 2>/dev/null || true)
    if [ -z "$snap" ]; then
      no_snapshot="$no_snapshot"$'\n'"   - OCP ${ocp//-/.}"
      continue
    fi
    name=$(jq -r '.metadata.name' <<< "$snap")
    revision=$(jq -r '.spec.components[0].source.git.revision // ""' <<< "$snap")
    tests=$(jq -r '.metadata.annotations["test.appstudio.openshift.io/status"] // ""' <<< "$snap")

    if [[ ! "$revision" =~ ^[0-9a-f]{40}$ ]]; then
      not_passing="$not_passing"$'\n'"   - OCP ${ocp//-/.}: snapshot $name has no valid source revision"
      continue
    fi
    # The snapshot must come from a revision whose catalog already lists this bundle;
    # otherwise it is a build from before the catalog update.
    if ! rev_digest=$(fbc_catalog_bundle_digest "$ocp" "$VERSION" "$revision"); then
      unknown_rev="$unknown_rev ${ocp//-/.}"
      continue
    fi
    if [ "$rev_digest" != "$main_digest" ]; then
      stale="$stale"$'\n'"   - OCP ${ocp//-/.}: $name"
      continue
    fi

    if ! printf '%s' "$snap" | fbc_tests_passed "$ocp"; then
      if [ -z "$tests" ]; then
        reason="no test status yet"
      else
        reason=$(printf '%s' "$tests" | jq -r '[.[] | select(.status != "TestPassed" and .status != "TestWarning" and .status != "BuildPLRInProgress")
          | "\(.scenario | sub("submariner-fbc-"; "")): \(.status)"] | join(", ")' 2>/dev/null || true)
        [ -n "$reason" ] || reason="tests are not finished and successful (check aggregate conditions and completed scenario results)"
      fi
      not_passing="$not_passing"$'\n'"   - OCP ${ocp//-/.}: $reason"
    fi
  done

  if [ -n "$unknown_rev" ]; then
    echo "⚠️  Could not read the FBC catalog at snapshot revisions for OCP${unknown_rev} (GitHub unreachable?)"
    echo "   Step 11 unverified — re-run when reachable"
    FBC_CATALOG_READY=unknown
    return
  fi
  if [ -n "$no_snapshot" ]; then
    echo "❌ No FBC push snapshot yet:${no_snapshot}"
    echo "   ⮕ Next: Wait for the FBC push build after the catalog update merges (~15-30 min)"
  fi
  if [ -n "$stale" ]; then
    echo "⏳ Newest FBC snapshot predates the catalog update:${stale}"
    echo "   ⮕ Next: Wait for the FBC rebuild after the catalog update merges (~15-30 min)"
  fi
  if [ -n "$not_passing" ]; then
    echo "❌ FBC snapshots with tests not passing:${not_passing}"
    echo "   ⮕ Next: Fix FBC tests and wait for rebuild"
  fi
  if [ -z "$no_snapshot$stale$not_passing" ]; then
    echo "✅ Bundle v$VERSION in FBC catalog; snapshots ready (OCP ${applicable//-/.})"
    FBC_CATALOG_READY=true
  fi
}

# Step 11: FBC Catalog Update
check_step_11() {
  if [ "$RELEASE_STATE" != "prod-recorded" ]; then
    check_fbc_catalog_live
    return
  fi

  # Completed releases: use historical snapshots (from YAMLs matched by date)
  FBC_MISSING=0
  FBC_FAILED=0

  # Get component YAML date for historical matching (completed releases only)
  local component_date=""
  if [ "$RELEASE_STATE" = "prod-recorded" ]; then
    component_date=$(get_component_yaml_date "stage")
  fi

  for ocp_version in $FBC_OCP_VERSIONS; do
    local fbc_snapshot=""

    # State-aware snapshot selection
    if [ "$RELEASE_STATE" = "prod-recorded" ] && [ -n "$component_date" ]; then
      # For completed releases: match FBC YAML by date proximity to component release
      local fbc_yaml
      fbc_yaml=$(find_fbc_yaml_by_date "$ocp_version" "stage" "$component_date")

      if [ -n "$fbc_yaml" ]; then
        fbc_snapshot=$(awk '/^  snapshot:/ {print $2}' "$fbc_yaml" 2>/dev/null || true)
      fi
    else
      # For in-progress or not-started: use latest snapshot (current verification)
      fbc_snapshot=$(oc get snapshots -n submariner-tenant --sort-by=.metadata.creationTimestamp 2>/dev/null \
        | grep "^submariner-fbc-$ocp_version" | tail -1 | awk '{print $1}' || true)
    fi

    if [ -z "$fbc_snapshot" ]; then
      if [ "$FBC_MISSING" -eq 0 ]; then
        if [ "$RELEASE_STATE" = "prod-recorded" ]; then
          # A missing dated FBC YAML only tells us this OCP version had no FBC
          # catalog cut in this release's date window — not *why*. Stay
          # descriptive; don't claim the version was unsupported at the time.
          echo "ℹ️  OCP versions with no FBC catalog in this release:"
        else
          echo "❌ Missing FBC snapshots:"
        fi
      fi
      echo "   - OCP ${ocp_version//-/.}"
      FBC_MISSING=$((FBC_MISSING + 1))
    else
      # Check test status
      local fbc_test_status
      fbc_test_status=$(get_snapshot_test_status "$fbc_snapshot")

      if [ -n "$fbc_test_status" ]; then
        local fbc_all_passed fbc_total
        fbc_all_passed=$(echo "$fbc_test_status" | jq '[.[] | select(.status == "TestPassed" or .status == "BuildPLRInProgress")] | length' 2>/dev/null || echo 0)
        fbc_total=$(echo "$fbc_test_status" | jq '. | length' 2>/dev/null || echo 0)

        if ! oc get snapshot "$fbc_snapshot" -n submariner-tenant -o json 2>/dev/null | fbc_tests_passed "$ocp_version"; then
          if [ "$FBC_FAILED" -eq 0 ]; then
            echo "❌ FBC snapshots with test failures:"
          fi
          echo "   - OCP ${ocp_version//-/.}: $fbc_all_passed/$fbc_total passed"
          FBC_FAILED=$((FBC_FAILED + 1))
        fi
      else
        FBC_FAILED=$((FBC_FAILED + 1))
        echo "⚠️  FBC snapshot $fbc_snapshot has no accessible test evidence"
      fi
    fi
  done

  # Completed releases: show historical verification results
  if [ "$FBC_MISSING" -eq 0 ] && [ "$FBC_FAILED" -eq 0 ]; then
    echo "✅ Recorded FBC snapshots have completed successful tests"
  elif [ "$FBC_FAILED" -gt 0 ]; then
    echo "⚠️  FBC stage snapshots had test failures at release time"
    echo "   ℹ️  Note: Current FBC snapshots may differ from the recorded candidate"
  fi
  # Don't show warning for missing OCP versions - already reported above with ℹ️
}

# Step 12-13: FBC Stage Releases
check_step_12_13() {
  # FBC releases follow component releases - check if component release exists first
  if [ -z "$STAGE_YAML" ]; then
    echo "ℹ️  Not released via Konflux (no component release)"
    echo "   FBC releases follow component releases"
    # Initialize counters for summary section
    FBC_NOT_APPLIED=0
    FBC_IN_PROGRESS=0
    FBC_SUCCEEDED=0
    FBC_FAILED=0
    return
  fi

  # Get OCP version scope for this release (inferred from YAMLs created near component release)
  local scope_stage
  scope_stage=$(get_release_ocp_scope "stage")
  FBC_STAGE_SCOPE="$scope_stage"
  FBC_STAGE_YAML_COUNT=$(count_words "$scope_stage")

  if [ "$FBC_STAGE_YAML_COUNT" -eq 0 ]; then
    echo "❌ No FBC stage YAMLs"
    echo "   ⮕ Next: Create FBC stage releases (Step 12)"
    # Initialize counters for summary section
    FBC_NOT_APPLIED=0
    FBC_IN_PROGRESS=0
    FBC_SUCCEEDED=0
    FBC_FAILED=0
    return
  fi

  # Report scope with context about OCP versions
  report_fbc_scope "stage" "$FBC_STAGE_YAML_COUNT" "$scope_stage" "12"

  # Check cluster status using helper function (only check versions in scope)
  check_fbc_release_status "stage" "$scope_stage"
}

# Step 13b: Check FBC Stage
check_step_13b() {
  echo "⏭️  Skipped (status in Step 12-13)"
}

# Step 14: QE Approval
check_step_14() {
  echo "⏸️  Manual checkpoint"
  echo "   ⮕ Next: Share with QE, wait for approval"
}

# Step 15-16: Component Prod Release
check_step_15_16() {
  if [ -z "$PROD_YAML" ]; then
    echo "❌ No prod release YAML"
    echo "   ⮕ Next: Create prod release (Step 15)"
  else
    echo "📄 Prod YAML: $(basename "$PROD_YAML")"

    # Check if applied to cluster (Step 16)
    local prod_release_name
    prod_release_name=$(awk '/^  name:/ {print $2}' "$PROD_YAML" 2>/dev/null || true)
    check_component_release_status "$prod_release_name" "prod (Step 16)"
  fi
}

# Step 16b: Check Prod Build
check_step_16b() {
  echo "⏭️  Skipped (status in Step 15-16)"
}

# Step 17-18: FBC Prod Releases
check_step_17_18() {
  # FBC releases follow component releases - check if component release exists first
  if [ -z "$PROD_YAML" ]; then
    echo "ℹ️  Not released via Konflux (no component release)"
    echo "   FBC releases follow component releases"
    # Initialize counters for summary section
    FBC_PROD_NOT_APPLIED=0
    FBC_PROD_IN_PROGRESS=0
    FBC_PROD_SUCCEEDED=0
    FBC_PROD_FAILED=0
    return
  fi

  # Get OCP version scope for this release (inferred from YAMLs created near component release)
  local scope_prod
  scope_prod=$(get_release_ocp_scope "prod")
  FBC_PROD_SCOPE="$scope_prod"
  FBC_PROD_YAML_COUNT=$(count_words "$scope_prod")

  if [ "$FBC_PROD_YAML_COUNT" -eq 0 ]; then
    echo "❌ No FBC prod YAMLs"
    echo "   ⮕ Next: Create FBC prod releases (Step 17)"
    # Initialize counters for summary section
    FBC_PROD_NOT_APPLIED=0
    FBC_PROD_IN_PROGRESS=0
    FBC_PROD_SUCCEEDED=0
    FBC_PROD_FAILED=0
    return
  fi

  # Report scope with context about OCP versions
  report_fbc_scope "prod" "$FBC_PROD_YAML_COUNT" "$scope_prod" "17"

  # Check cluster status using helper function (only check versions in scope)
  check_fbc_release_status "prod" "$scope_prod"
}

# Step 18b: Check FBC Prod
check_step_18b() {
  echo "⏭️  Skipped (status in Step 17-18)"
}

# Step 19: Share Prod with QE
check_step_19() {
  echo "ℹ️  Manual step - share prod URLs with QE"
}

# Step 20: Update FBC Templates
check_step_20() {
  echo "ℹ️  Workflow follow-up: convert temporary FBC bundle URLs to permanent production URLs"
  echo "   Check the Jira tracker and re-run autorelease after conversion to verify closure"
}

# ============================================================================
# Main Execution
# ============================================================================

# Header
echo "=== Submariner $VERSION Release Status ==="
echo ""

# ============================================================================
# Check Cluster Access
# ============================================================================

# Check if logged in to cluster
if oc whoami &>/dev/null; then
  OC_AVAILABLE=true
else
  OC_AVAILABLE=false
  echo "⚠️  Not logged in to cluster - using repository-based verification where possible"
  echo ""
fi

# Path to konflux-release-data repo (for fallback verification)
KONFLUX_RELEASE_DATA_PATH="${KONFLUX_RELEASE_DATA_PATH:-$HOME/konflux/konflux-release-data}"

# ============================================================================
# Jira Release Tracker (optional)
# ============================================================================

TRACKER_KEY=""
TRACKER_LIB="$(dirname "$0")/lib/jira-tracker.sh"

if [ -f "$TRACKER_LIB" ]; then
  # Source tracker library (best-effort, never fails)
  # shellcheck source=lib/jira-tracker.sh
  source "$TRACKER_LIB" 2>/dev/null || true

  # Drift detection reuses the tracker's per-step status vs the ground-truth
  # globals this script already computes (best-effort; never fails the run).
  DRIFT_LIB="$(dirname "$0")/lib/tracker-drift.sh"
  # shellcheck source=lib/tracker-drift.sh
  [ -f "$DRIFT_LIB" ] && source "$DRIFT_LIB" 2>/dev/null || true

  # VERSION is always X.Y.Z here (bare X.Y normalized above), so look up its tracker.
  TRACKER_KEY=$(find_release_tracker "$VERSION" 2>/dev/null || true)
  if [ -n "$TRACKER_KEY" ]; then
    echo "📋 Jira Tracker: $TRACKER_KEY (https://issues.redhat.com/browse/$TRACKER_KEY)"
    echo ""
  fi
fi

# ============================================================================
# Initialize Global Variables
# ============================================================================

# Find release YAMLs once (used across multiple steps and phase detection).
# sort | tail -1 = latest recorded attempt, chosen deterministically
# (find output order is unspecified); we read the snapshot/name from this file.
STAGE_YAML=$(find "$RELEASE_ROOT/releases/$MAJOR_MINOR/stage/" -name "submariner-$FULL_VERSION_DASH-stage-*.yaml" 2>/dev/null | sort | tail -1 || true)
PROD_YAML=$(find "$RELEASE_ROOT/releases/$MAJOR_MINOR/prod/" -name "submariner-$FULL_VERSION_DASH-prod-*.yaml" 2>/dev/null | sort | tail -1 || true)

load_component_snapshot

COMPONENT_STAGE_STATUS=unknown
COMPONENT_PROD_STATUS=unknown

# Step check results (used across multiple steps and phase detection)
BRANCH_CHECK=""              # Step 1: Branch existence check
BRANCH_FETCH_FAILED=0        # Step 1: repos whose ls-remote failed (unreachable, not proven absent)
STAGE_PLAN=""                # Step 2: Stage ReleasePlan
PROD_PLAN=""                 # Step 2: Prod ReleasePlan
MISSING_TEKTON=0             # Step 3: Missing Tekton configs count
TEKTON_FETCH_FAILED=0        # Step 3: repos whose gh probe failed for a non-404 reason (unreachable)
TAG_EXISTS=""                # Step 6: Upstream tag existence
# shellcheck disable=SC2034  # consumed cross-file by tracker-drift.sh (set to 1, never re-read here)
TAG_FETCH_FAILED=0           # Step 6: tag listing failed (unreachable, not proven absent)
WRONG_COUNT=0                # Step 5b: Incorrect version labels count
FETCH_FAILED=0               # Step 5b: Dockerfiles that couldn't be fetched
IMAGE_VERSION=""             # Step 7: Container image version label
IMAGE_VERSION_FETCHED=false  # Step 7: Whether IMAGE_VERSION was fetched

# FBC counters (set by check_fbc_release_status, used in phase detection)
# shellcheck disable=SC2034  # Counters are read through the FBC reporter namerefs.
declare FBC_NOT_APPLIED=0 FBC_IN_PROGRESS=0 FBC_SUCCEEDED=0 FBC_FAILED=0 FBC_UNKNOWN=0
# shellcheck disable=SC2034
declare FBC_PROD_NOT_APPLIED=0 FBC_PROD_IN_PROGRESS=0 FBC_PROD_SUCCEEDED=0 FBC_PROD_FAILED=0 FBC_PROD_UNKNOWN=0
FBC_STAGE_SCOPE="" FBC_PROD_SCOPE=""
FBC_STAGE_YAML_COUNT=0       # Step 12-13: Number of stage FBC YAMLs
FBC_PROD_YAML_COUNT=0        # Step 17-18: Number of prod FBC YAMLs
FBC_CATALOG_READY=""         # Step 11 (running release): true|false|unknown; "" = not checked
FBC_APPLICABLE_COUNT=""      # Step 11: OCP versions whose catalog lists this bundle ("" = unknown)

# Recorded prod YAMLs select historical scope; live success is checked separately.
RELEASE_STATE=$(detect_recorded_state)

# Main loop: Iterate through steps
CURRENT_PHASE=""

for step_def in "${RELEASE_STEPS[@]}"; do
  step_num=$(get_step_field "$step_def" 1)
  step_name=$(get_step_field "$step_def" 2)
  step_phase=$(get_step_field "$step_def" 3)
  step_stream=$(get_step_field "$step_def" 4)
  step_check_nums=$(get_step_field "$step_def" 6)

  # Print phase header when phase changes
  if [ "$step_phase" != "$CURRENT_PHASE" ]; then
    CURRENT_PHASE="$step_phase"
    echo "━━━ ${PHASE_NAMES[$step_phase]} ━━━"
    echo ""
  fi

  # Print step header
  display_num="$step_num"
  [ -n "$step_check_nums" ] && display_num="$step_check_nums"
  echo "[Step $display_num] $step_name"

  # Check if step applies to current stream
  if ! step_applies_to_stream "$step_stream" "$IS_ZSTREAM"; then
    stream_name=$([ "$step_stream" = "Y" ] && echo "Y-stream" || echo "Z-stream")
    echo "⏭️  N/A ($stream_name only)"
    echo ""
    continue
  fi

  # Call check function
  check_step_${step_num}

  echo ""
done

# Summary
echo "━━━ SUMMARY ━━━"
echo ""

if [ -n "$TRACKER_KEY" ]; then
  echo "Jira Tracker: $TRACKER_KEY"
else
  echo "Jira Tracker: (none — run /create-release-tracker $VERSION to create)"
fi

# Freshness warnings from Jira tracker
if [ -n "$TRACKER_KEY" ] && type get_release_summary &>/dev/null; then
  TRACKER_SUMMARY=$(get_release_summary "$VERSION" 2>/dev/null || true)
  if [ -n "$TRACKER_SUMMARY" ] && [ "$TRACKER_SUMMARY" != "{}" ]; then
    # get_release_summary only ever marks rule-bearing steps "stale" (every other
    # step defaults to "fresh"), so selecting stale steps needs no key list here —
    # this stays in sync with STALENESS_RULES automatically. Suppress only a completed
    # upstream source step with all five tags verified; downstream evidence is still required.
    STALE_STEPS=$(stale_step_titles <<< "$TRACKER_SUMMARY" 2>/dev/null || true)
    [ -n "$STALE_STEPS" ] && echo "⚠️  Stale steps: $STALE_STEPS"

    # Tracker-vs-reality drift: reuse TRACKER_SUMMARY (no extra Jira query);
    # ground truth comes from the globals the step checks already populated.
    if type print_tracker_drift &>/dev/null; then
      print_tracker_drift "$TRACKER_SUMMARY" || true
    fi
  fi
fi

if [ "$IS_ZSTREAM" = "true" ]; then
  echo "Release Type: Z-stream ($MAJOR_MINOR → $VERSION)"
else
  echo "Release Type: Y-stream ($VERSION)"
fi

# Print the next action from the same evidence used by the detailed checks.
print_current_phase() {
  local CURRENT_PHASE
  CURRENT_PHASE=$(detect_current_phase)
case "$CURRENT_PHASE" in
  upstream-prep)
    if [ "${BRANCH_FETCH_FAILED:-0}" -gt 0 ]; then
      echo "Current Phase: Branch Setup (verification unavailable)"
      echo "   ⮕ Next: Restore GitHub access and verify the existing branches"
    elif [ -z "$BRANCH_CHECK" ]; then
      echo "Current Phase: Branch Setup"
      echo "Blocking: Release branch not created"
      echo ""
      echo "NEXT STEPS:"
      echo "1. [Step 1] Create release-$MAJOR_MINOR branches in all repos"
    elif [ "$OC_AVAILABLE" != true ] || [ "${RELEASEPLANS_LOOKUP_FAILED:-false}" = true ]; then
      echo "Current Phase: Downstream Configuration (verification unavailable)"
      echo "   ⮕ Next: Restore cluster access and verify deployed ReleasePlans"
    elif [ -z "$STAGE_PLAN" ] || [ -z "$PROD_PLAN" ]; then
      echo "Current Phase: Downstream Configuration"
      if [ -z "$STAGE_PLAN" ] && [ -z "$PROD_PLAN" ]; then
        echo "Blocking: ReleasePlans not configured"
      elif [ -z "$STAGE_PLAN" ]; then
        echo "Blocking: Stage ReleasePlan missing"
      else
        echo "Blocking: Prod ReleasePlan missing"
      fi
      echo ""
      echo "NEXT STEPS:"
      echo "1. [Step 2] Configure Konflux ReleasePlans"
    fi
    ;;

  component-prep)
    echo "Current Phase: Tekton Configuration"
    if [ "${TEKTON_FETCH_FAILED:-0}" -gt 0 ]; then
      echo "Blocking: Tekton configuration unverified (GitHub auth/network)"
      echo "   ⮕ Next: Restore access and re-run configuration checks"
    else
      echo "Blocking: Component Tekton configs not set up"
      echo "   ⮕ Next: Fix Tekton config PRs for components"
    fi
    ;;

  upstream-release)
    echo "Current Phase: Build Preparation"
    if [ "$WRONG_COUNT" -gt 0 ]; then
      echo "Blocking: Version updates not complete on release-$MAJOR_MINOR ($WRONG_COUNT Dockerfiles)"
      echo "   ⮕ Next: Review existing version PRs; prepare only missing updates, then wait for rebuild"
    elif [ "$FETCH_FAILED" -gt 0 ] || [ "$TAG_FETCH_FAILED" -gt 0 ]; then
      echo "Blocking: Source verification unavailable (GitHub auth/network)"
      echo "   ⮕ Next: Restore access and verify versions/tags; preserve existing tags"
    elif [ -z "$TAG_EXISTS" ]; then
      echo "Blocking: Upstream tag set incomplete"
      echo "   ⮕ Next: Complete only missing v$VERSION tags; never move existing tags"
    elif [ "$SNAPSHOT_LOOKUP_FAILED" = true ]; then
      echo "Blocking: Candidate snapshot unverified"
      echo "   ⮕ Next: Restore cluster/Jira access or investigate the recorded candidate; re-run status"
    elif [ -z "$SNAPSHOT" ]; then
      echo "Blocking: No qualifying branch-build snapshot"
      echo "   ⮕ Next: Check release-$MAJOR_MINOR builds and wait for a snapshot"
    elif [ "$SNAPSHOT_READY" != true ]; then
      echo "Blocking: Candidate integration is not finished and successful ($SNAPSHOT)"
      echo "   ⮕ Next: Inspect completed tests and policy failures for this candidate; repair demonstrated failures"
    else
      echo "Blocking: Candidate image version is unverified or differs from v$VERSION"
      echo "   ⮕ Next: Verify rebuilt image labels and binary versions before updating bundle SHAs"
    fi
    ;;

  component-stage)
    echo "Current Phase: Component Stage"
    if [ -z "$STAGE_YAML" ]; then
      echo "Blocking: Component stage release not prepared"
      echo "   ⮕ Next: Verify rebuilt image/binary versions, bundle digests and release policy, then prepare stage"
    else
      echo "Blocking: Component stage release is ${COMPONENT_STAGE_STATUS:-unknown}"
      echo "   ⮕ Next: Verify/apply/monitor the recorded stage release before advancing to FBC"
    fi
    ;;

  fbc-stage)
    if [ "$FBC_STAGE_YAML_COUNT" -eq 0 ]; then
      echo "Current Phase: Stage Release"
      # Only name a count once Step 11 has established which OCP versions apply.
      fbc_count_note=""
      [ -n "$FBC_APPLICABLE_COUNT" ] && fbc_count_note=" ($FBC_APPLICABLE_COUNT OCP versions)"
      if [ "$FBC_CATALOG_READY" = "true" ]; then
        # Step 11 verified done: don't send the user back to it.
        echo "Blocking: FBC stage releases not created"
        echo ""
        echo "NEXT STEPS:"
        echo "1. [Step 12] Create FBC stage releases${fbc_count_note}"
      else
        echo "Blocking: FBC catalog update (Step 11) not complete"
        echo ""
        echo "NEXT STEPS:"
        echo "1. [Step 11] Update FBC catalog with stage bundle (see Step 11 above)"
        echo "2. [Step 12] Create FBC stage releases${fbc_count_note}"
      fi
    else
      echo "Current Phase: Stage Release"
      echo "Blocking: FBC stage releases incomplete"
      echo ""
      echo "NEXT STEPS:"
      echo "1. [Step 13] Apply/monitor FBC stage releases"
      echo "2. [Step 14] Share with QE for approval"
    fi
    ;;

  qe-approval)
    echo "Current Phase: QE Approval"
    echo "Blocking: Awaiting QE approval"
    echo ""
    echo "NEXT STEPS:"
    echo "1. [Step 14] Share stage with QE"
    echo "2. [Step 15] Create prod release after QE approval"
    ;;

  component-prod)
    echo "Current Phase: Production Release"
    if [ "${COMPONENT_PROD_STATUS:-unknown}" != succeeded ]; then
      echo "Blocking: Component production release is ${COMPONENT_PROD_STATUS:-unknown}"
      echo "   ⮕ Next: Verify/apply/monitor the recorded component release before FBC production"
    elif [ "$FBC_PROD_YAML_COUNT" -eq 0 ]; then
      echo "Status: Component shipped; FBC production scope/completion unverified"
      echo "   ⮕ Next: Check release scope and FBC production records before declaring completion"
    else
      echo "Blocking: FBC production not fully verified ($FBC_PROD_SUCCEEDED/$FBC_PROD_YAML_COUNT recorded releases succeeded)"
      echo "   ⮕ Next: Check missing records, failed releases and production index evidence for every in-scope OCP version"
    fi
    ;;

  complete)
    echo "Current Phase: Production Delivered"
    echo "Status: ✅ Release $VERSION deployed to production"
    echo ""

    # Show what was released
    prod_scope=$(get_release_ocp_scope "prod")
    prod_count=$(count_words "$prod_scope")

    echo "RELEASED:"
    echo "- Component: submariner-$VERSION"
    if [ "$prod_count" -eq 0 ]; then
      # No FBC prod releases means a pre-FBC release (it has no FBC stage YAMLs
      # either — an active release with FBC stage but not-yet-prod resolves to the
      # "component-prod" phase above, never here).
      echo "- FBC catalogs: None found"
    else
      echo "- FBC catalogs: $prod_count (OCP $prod_scope)"
    fi
    ;;

  *)
    echo "Current Phase: Unknown"
    echo "Status: Unable to determine release phase"
    ;;
esac
}

print_current_phase
