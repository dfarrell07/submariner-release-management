#!/bin/bash
# Get FBC catalog URLs for QE sharing
#
# Usage: get-fbc-urls.sh <version> [--ocp 4.XX] [--raw-url] [--prod-index]
#
# Arguments:
#   version:     Submariner version (e.g., 0.24.0 or 0.24)
#
# Options:
#   --ocp 4.XX:    Single OCP version (default: all supported, see FBC_OCP_VERSIONS in lib/fbc-scope.sh)
#   --raw-url:     Print only URLs (one per line, for automation)
#   --prod-index:  Check prod operator index at registry.redhat.io (requires skopeo)
#
# Default mode: verifies exact successful stage Releases and their snapshot images.
# Missing live completion evidence fails; a snapshot is not publication proof.
#
# Prod-index mode: confirms bundle exists in prod registry via skopeo inspect,
# then outputs per-OCP operator index URLs.
#
# Exit codes:
#   0: Success (all requested applicable stage targets verified)
#   1: Failure (bad arguments, no releases found)
#   2: Not authenticated to OpenShift cluster

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ━━━ CONSTANTS ━━━

readonly NAMESPACE="submariner-tenant"
# ALL_OCP_VERSIONS is populated from FBC_OCP_VERSIONS (lib/fbc-scope.sh) after
# SCRIPT_DIR is set below — single source of truth for the supported OCP range.

# ━━━ GLOBAL VARIABLES ━━━

VERSION=""
RAW_URL=false
OCP_FILTER=""
PROD_INDEX=false
TMPDIR=""
# Per-OCP catalog fragment URLs captured by get_urls, used to populate the
# QE subtask description in main() (Phase 3).
QE_CATALOG_URLS=()

# ━━━ HELPERS ━━━

die() {
  echo "❌ ERROR: $1" >&2
  [ -n "${2:-}" ] && echo "$2" >&2
  exit 1
}

# ━━━ PREREQUISITES ━━━

check_prerequisites() {
  local MISSING_TOOLS=()

  command -v oc &>/dev/null || MISSING_TOOLS+=("oc")
  command -v jq &>/dev/null || MISSING_TOOLS+=("jq")

  if [ "${#MISSING_TOOLS[@]}" -gt 0 ]; then
    die "Missing required tools: ${MISSING_TOOLS[*]}"
  fi

  if ! $PROD_INDEX; then
    command -v yq &>/dev/null || die "yq is required to verify the released bundle"
    if ! oc whoami &>/dev/null; then
      echo "❌ ERROR: Not logged into OpenShift cluster" >&2
      echo "Run: oc login --web https://api.kflux-prd-rh02.0fk9.p1.openshiftapps.com:6443/" >&2
      exit 2
    fi

    if ! $RAW_URL; then
      echo "✓ Authenticated as: $(oc whoami)"
    fi
  fi

}

# ━━━ ARGUMENT PARSING ━━━

parse_arguments() {
  local VERSION_ARG=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --raw-url) RAW_URL=true; shift ;;
      --prod-index) PROD_INDEX=true; shift ;;
      --ocp)
        [ $# -lt 2 ] && die "--ocp requires a value (e.g., --ocp 4.21)"
        OCP_FILTER="$2"; shift 2 ;;
      -*)  die "Unknown option: $1" "Usage: $0 <version> [--ocp 4.XX] [--raw-url] [--prod-index]" ;;
      *)
        if [ -z "$VERSION_ARG" ]; then
          VERSION_ARG="$1"
        else
          die "Unexpected argument: $1" "Usage: $0 <version> [--ocp 4.XX] [--raw-url] [--prod-index]"
        fi
        shift
        ;;
    esac
  done

  if [ -z "$VERSION_ARG" ]; then
    echo "Usage: $0 <version> [--ocp 4.XX] [--raw-url] [--prod-index]"
    echo "Example: $0 0.24.0"
    echo "Example: $0 0.24.0 --ocp 4.21 --raw-url"
    echo "Example: $0 0.24.0 --prod-index"
    exit 1
  fi

  # Accept X.Y or X.Y.Z
  if [[ "$VERSION_ARG" =~ ^[0-9]+\.[0-9]+$ ]]; then
    VERSION="${VERSION_ARG}.0"
  elif [[ "$VERSION_ARG" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    VERSION="$VERSION_ARG"
  else
    die "Invalid version format: $VERSION_ARG" "Expected: X.Y or X.Y.Z (e.g., 0.24 or 0.24.0)"
  fi

  if [ -n "$OCP_FILTER" ]; then
    # Normalize complete identities, including major-version transitions.
    local V_NUM
    V_NUM=$(ocp_normalize "$OCP_FILTER") || exit 1
    # Explicit selection may inspect a newly onboarded version before activation.
    OCP_FILTER="$V_NUM"
  fi
}

# ━━━ PARALLEL JOB HELPERS (shared lib, relies on global TMPDIR) ━━━

# shellcheck source=lib/parallel-jobs.sh
source "$SCRIPT_DIR/lib/parallel-jobs.sh"
# shellcheck source=lib/fbc-scope.sh
source "$SCRIPT_DIR/lib/fbc-scope.sh"
# shellcheck source=lib/fbc-snapshot.sh
source "$SCRIPT_DIR/lib/fbc-snapshot.sh"
# Convert space-separated FBC_OCP_VERSIONS string to array for indexed access.
read -ra ALL_OCP_VERSIONS <<< "$FBC_OCP_VERSIONS"

setup_tmpdir() {
  if [ -z "$TMPDIR" ]; then
    TMPDIR=$(mktemp -d)
    trap 'rm -rf "$TMPDIR"' EXIT
  fi
}

# ━━━ PROD INDEX MODE ━━━

readonly BUNDLE_REGISTRY="registry.redhat.io/rhacm2/submariner-operator-bundle"
readonly INDEX_REGISTRY="registry.redhat.io/redhat/redhat-operator-index"

# Tag-scheme-aware prod-bundle check (new-scheme .0 releases have no vX.Y.0 tag).
# PROD_BUNDLE_REGISTRY is read by the sourced prod-bundle.sh.
# shellcheck disable=SC2034
PROD_BUNDLE_REGISTRY="$BUNDLE_REGISTRY"
# shellcheck source=lib/prod-bundle.sh
source "$SCRIPT_DIR/lib/prod-bundle.sh"

get_urls_from_prod_index() {
  local VERSIONS=("${ALL_OCP_VERSIONS[@]}")

  if [ -n "$OCP_FILTER" ]; then
    VERSIONS=("$OCP_FILTER")
  fi

  if ! $RAW_URL; then
    echo "Checking prod registry for Submariner $VERSION..."
  fi

  local count=0 verdict
  for V in "${VERSIONS[@]}"; do
    verdict=$(prod_index_has_bundle "$V" "$VERSION")
    case "$verdict" in
      present) count=$((count + 1)) ;;
      absent) echo "OCP ${V//-/.}: bundle $VERSION absent from index" >&2; continue ;;
      *) die "Cannot verify OCP ${V//-/.} index membership (auth/network failure)" ;;
    esac
    local INDEX_URL="${INDEX_REGISTRY}:v${V//-/.}"
    if $RAW_URL; then
      echo "$INDEX_URL"
    else
      echo "OCP ${V//-/.}: $INDEX_URL"
    fi
  done

  if ! $RAW_URL; then
    echo ""
    echo "Found $count OCP versions"
  fi
  [ "$count" -gt 0 ]
}

# ━━━ RELEASED CATALOG VERIFICATION ━━━

verify_snapshot_bundle() {
  local V="$1"
  local CATALOG_IMAGE="$2"
  local TARGET_VERSION="$3"
  local EXPECTED_DIGEST="$4"

  local EXTRACT_DIR="$TMPDIR/extract-${V}"
  mkdir -p "$EXTRACT_DIR"

  oc image extract "$CATALOG_IMAGE" \
    --path "/configs/submariner/bundles/:$EXTRACT_DIR/" \
    --confirm > /dev/null 2>&1

  local bundle_file="$EXTRACT_DIR/bundle-v${TARGET_VERSION}.yaml"
  [ -f "$bundle_file" ] || bundle_file="$EXTRACT_DIR/bundle-v${TARGET_VERSION}.json"
  if [ -f "$bundle_file" ] && yq -o=json '.' "$bundle_file" | jq -e --arg version "$TARGET_VERSION" --arg digest "$EXPECTED_DIGEST" '
    .name == ("submariner.v" + $version) and
    (.image | endswith("@sha256:" + $digest))
  ' >/dev/null; then
    echo "match" > "$EXTRACT_DIR/result.txt"
  else
    echo "no-match" > "$EXTRACT_DIR/result.txt"
  fi
}

# Read exact modern stage records; legacy names require retained completion evidence.
get_urls() {
  local VERSIONS=("${ALL_OCP_VERSIONS[@]}") applicable=() missing=()
  local releases selected v bundle fragment snapshot snapshot_json expected_name
  local -A bundle_digests
  if [ -n "$OCP_FILTER" ]; then VERSIONS=("$OCP_FILTER"); fi
  for v in "${VERSIONS[@]}"; do
    if ! bundle=$(fbc_catalog_bundle_digest "$v" "$VERSION"); then
      die "Cannot establish catalog applicability for OCP ${v//-/.}"
    fi
    if [ -n "$bundle" ]; then applicable+=("$v"); bundle_digests[$v]="$bundle"; fi
  done
  [ "${#applicable[@]}" -gt 0 ] || die "No applicable active catalog contains $VERSION"
  releases=$(oc get releases -n "$NAMESPACE" -o json) || die "Cannot query Release completion"
  jq -e '.items | type == "array"' <<< "$releases" >/dev/null || die "Malformed Release response"
  setup_tmpdir
  local -A selected_records
  for v in "${applicable[@]}"; do
    expected_name="submariner-fbc-${v}-${VERSION//./-}-stage-"
    selected=$(jq -c --arg prefix "$expected_name" --arg app "submariner-fbc-$v" \
      --arg plan "submariner-fbc-release-plan-stage-$v" --arg ocp "v${v//-/.}" '
      [.items[] | select(.metadata.name | startswith($prefix)) |
       select(.spec.releasePlan == $plan) |
       select([.status.conditions[]? | select(.type == "Released")] |
         length == 1 and .[0].status == "True" and .[0].reason == "Succeeded") |
       select(.status.artifacts.components | length == 1) |
       select(.status.artifacts.components[0].ocp_version == $ocp and
         .status.artifacts.components[0].target_index == "" and
         .status.artifacts.components[0].target_index_with_timestamp == "") |
       select(.status.artifacts.components[0].fbc_fragment |
         test("^quay[.]io/redhat-user-workloads/submariner-tenant/" + $app + "@sha256:[a-f0-9]{64}$"))]
      | sort_by(.metadata.creationTimestamp, .metadata.name) | last // empty
    ' <<< "$releases") || die "Cannot parse stage Release records"
    if [ -z "$selected" ]; then missing+=("${v//-/.}"); continue; fi
    snapshot=$(jq -r '.spec.snapshot' <<< "$selected")
    fragment=$(jq -r '.status.artifacts.components[0].fbc_fragment' <<< "$selected")
    snapshot_json=$(oc get snapshot "$snapshot" -n "$NAMESPACE" -o json) || die "Cannot verify snapshot $snapshot"
    jq -e --arg app "submariner-fbc-$v" --arg image "$fragment" '
      .spec.application == $app and (.spec.components | length == 1) and
      .spec.components[0].name == $app and .spec.components[0].containerImage == $image
    ' <<< "$snapshot_json" >/dev/null || die "Released fragment does not match snapshot $snapshot"
    fbc_tests_passed "$v" <<< "$snapshot_json" || die "Released snapshot $snapshot lacks completed successful integration evidence"
    verify_snapshot_bundle "$v" "$fragment" "$VERSION" "${bundle_digests[$v]}"
    [ "$(cat "$TMPDIR/extract-$v/result.txt")" = match ] || die "Released catalog lacks bundle $VERSION for OCP ${v//-/.}"
    selected_records[$v]="$selected"
  done
  [ "${#missing[@]}" -eq 0 ] || die "No verified $VERSION stage completion for OCP: ${missing[*]}. Use --ocp for an individual ready target; retain completed Release evidence when live records disappear."
  for v in "${applicable[@]}"; do
    selected="${selected_records[$v]}"
    fragment=$(jq -r '.status.artifacts.components[0].fbc_fragment' <<< "$selected")
    QE_CATALOG_URLS+=("OCP ${v//-/.}: $fragment")
    if $RAW_URL; then printf '%s\n' "$fragment"; else
      printf 'OCP %s: %s\n' "${v//-/.}" "$fragment"
      printf 'Release: %s; snapshot: %s\n\n' "$(jq -r '.metadata.name' <<< "$selected")" "$(jq -r '.spec.snapshot' <<< "$selected")"
    fi
  done
}

# ━━━ MAIN ━━━

main() {
  parse_arguments "$@"
  check_prerequisites

  # Tracker integration
  TRACKER_LIB="${TRACKER_LIB:-$(cd "$(dirname "$0")" && pwd)/lib/jira-tracker.sh}"
  # shellcheck source=lib/jira-tracker.sh
  [ -f "$TRACKER_LIB" ] && source "$TRACKER_LIB" 2>/dev/null || true
  TRACKER=$(find_release_tracker "$VERSION" 2>/dev/null || true)

  if $PROD_INDEX; then
    get_urls_from_prod_index
  else
    get_urls
  fi

  # Phase 3: populate QE subtask with the actual catalog URLs captured above.
  # Only write when we captured at least one URL — never a content-free
  # placeholder that claims to be populated while holding nothing.
  if [ -n "${TRACKER:-}" ] && ! $RAW_URL && ! $PROD_INDEX && [ "${#QE_CATALOG_URLS[@]}" -gt 0 ]; then
    local url_markdown
    url_markdown="## Stage Catalog URLs"$'\n\n'"$(printf -- '- %s\n' "${QE_CATALOG_URLS[@]}")"
    update_subtask_description "$VERSION" "qeValidation" "$url_markdown" "$TRACKER" 2>/dev/null || true
  fi
}

# Run main only when executed directly; sourcing exposes path resolution and
# functions to the offline test harness without querying the cluster.
if [ "${BASH_SOURCE[0]:-}" = "${0:-}" ]; then
  main "$@"
fi
