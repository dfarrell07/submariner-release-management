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
# Default mode: extracts quay.io catalog URLs from Release CRs on the cluster,
# falling back to local YAML files + snapshot lookup if Release CRs are GC'd.
#
# Prod-index mode: confirms bundle exists in prod registry via skopeo inspect,
# then outputs per-OCP operator index URLs.
#
# Exit codes:
#   0: Success (URLs extracted for at least one OCP version)
#   1: Failure (bad arguments, no releases found)
#   2: Not authenticated to OpenShift cluster

set -euo pipefail

# ━━━ CONSTANTS ━━━

readonly KONFLUX_UI="https://konflux-ui.apps.kflux-prd-rh02.0fk9.p1.openshiftapps.com"
readonly NAMESPACE="submariner-tenant"
# ALL_OCP_VERSIONS is populated from FBC_OCP_VERSIONS (lib/fbc-scope.sh) after
# SCRIPT_DIR is set below — single source of truth for the supported OCP range.

# ━━━ GLOBAL VARIABLES ━━━

VERSION=""
RAW_URL=false
OCP_FILTER=""
PROD_INDEX=false
GIT_ROOT=""
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

  if $PROD_INDEX; then
    command -v skopeo &>/dev/null || MISSING_TOOLS+=("skopeo")
    command -v jq &>/dev/null || MISSING_TOOLS+=("jq")
  else
    command -v oc &>/dev/null || MISSING_TOOLS+=("oc")
  fi

  if [ "${#MISSING_TOOLS[@]}" -gt 0 ]; then
    die "Missing required tools: ${MISSING_TOOLS[*]}"
  fi

  if ! $PROD_INDEX; then
    if ! oc whoami &>/dev/null; then
      echo "❌ ERROR: Not logged into OpenShift cluster" >&2
      echo "Run: oc login --web https://api.kflux-prd-rh02.0fk9.p1.openshiftapps.com:6443/" >&2
      exit 2
    fi

    if ! $RAW_URL; then
      echo "✓ Authenticated as: $(oc whoami)"
    fi
  fi

  GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || die "Not in a git repository"
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
    # Normalize: accept 4.21 or 4-21, store minor version number
    local V_NUM="${OCP_FILTER#4.}"
    V_NUM="${V_NUM#4-}"
    local VALID=false
    for V in "${ALL_OCP_VERSIONS[@]}"; do
      [ "$V_NUM" = "$V" ] && VALID=true
    done
    if ! $VALID; then
      # Derive the valid-versions list from ALL_OCP_VERSIONS so it never drifts.
      local valid_list
      valid_list=$(printf '4.%s, ' "${ALL_OCP_VERSIONS[@]}")
      die "Invalid OCP version: $OCP_FILTER" "Valid versions: ${valid_list%, }"
    fi
    OCP_FILTER="$V_NUM"
  fi
}

# ━━━ PARALLEL JOB HELPERS (shared lib, relies on global TMPDIR) ━━━

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/parallel-jobs.sh
source "$SCRIPT_DIR/lib/parallel-jobs.sh"
# shellcheck source=lib/fbc-scope.sh
source "$SCRIPT_DIR/lib/fbc-scope.sh"
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

  # Confirm the bundle shipped (tag-scheme-aware; sets PROD_BUNDLE_* on success)
  # before advertising index URLs, distinguishing genuine absence from an
  # unreachable registry so a flake doesn't read as "not released".
  prod_bundle_shipped "$VERSION"
  case "$PROD_BUNDLE_VERDICT" in
    shipped) ;;
    not-shipped) die "Submariner $VERSION not found in prod registry" \
        "No exact tag v${VERSION} and floating v${VERSION%.*} points to another patch" ;;
    *) die "Cannot verify Submariner $VERSION in prod registry" \
        "skopeo could not inspect ${BUNDLE_REGISTRY} (check auth/network)" ;;
  esac

  local BUNDLE_DIGEST="$PROD_BUNDLE_DIGEST" BUNDLE_CREATED="$PROD_BUNDLE_CREATED"

  if ! $RAW_URL; then
    echo "✓ Found bundle ${PROD_BUNDLE_TAG} (${BUNDLE_DIGEST:7:12}, built ${BUNDLE_CREATED})"
    echo ""
    echo "=== Prod Operator Index URLs for Submariner $VERSION ==="
    echo ""
  fi

  for V in "${VERSIONS[@]}"; do
    local INDEX_URL="${INDEX_REGISTRY}:v4.${V}"
    if $RAW_URL; then
      echo "$INDEX_URL"
    else
      echo "OCP 4.${V}: $INDEX_URL"
    fi
  done

  if ! $RAW_URL; then
    echo ""
    echo "Found ${#VERSIONS[@]} OCP versions"
  fi
}

# ━━━ SNAPSHOT FALLBACK ━━━

verify_snapshot_bundle() {
  local V="$1"
  local CATALOG_IMAGE="$2"
  local TARGET_VERSION="$3"

  local EXTRACT_DIR="$TMPDIR/extract-4-${V}"
  mkdir -p "$EXTRACT_DIR"

  oc image extract "$CATALOG_IMAGE" \
    --path "/configs/submariner/bundles/:$EXTRACT_DIR/" \
    --confirm > /dev/null 2>&1

  if [ -f "$EXTRACT_DIR/bundle-v${TARGET_VERSION}.yaml" ] || \
     [ -f "$EXTRACT_DIR/bundle-v${TARGET_VERSION}.json" ]; then
    echo "match" > "$EXTRACT_DIR/result.txt"
  else
    echo "no-match" > "$EXTRACT_DIR/result.txt"
  fi
}

get_urls_from_snapshots() {
  local FOUND=0
  local MISSING=()
  local VERSIONS=("${ALL_OCP_VERSIONS[@]}")

  if [ -n "$OCP_FILTER" ]; then
    VERSIONS=("$OCP_FILTER")
  fi

  if ! $RAW_URL; then
    echo "No Release CRs on Konflux cluster (normal — CRs are garbage-collected after completion)."
    echo "Falling back to snapshot lookup from local release YAML files..."
    echo ""
  fi

  setup_tmpdir
  export -f verify_snapshot_bundle
  export TMPDIR

  local -A SNAPSHOT_MAP
  local -A CATALOG_MAP

  for V in "${VERSIONS[@]}"; do
    # Pick newest YAML across both stage and prod (filenames sort by date)
    local YAML_FILE=""
    YAML_FILE=$(ls "$GIT_ROOT/releases/fbc/4-${V}"/{stage,prod}/*.yaml 2>/dev/null | sort | tail -1)

    if [ -z "$YAML_FILE" ]; then
      MISSING+=("4.$V")
      continue
    fi

    local SNAPSHOT
    SNAPSHOT=$(awk '/^  snapshot:/ {print $2}' "$YAML_FILE")
    if [ -z "$SNAPSHOT" ]; then
      MISSING+=("4.$V")
      continue
    fi

    local CATALOG_IMAGE
    CATALOG_IMAGE=$(oc get snapshot "$SNAPSHOT" -n "$NAMESPACE" \
      -o jsonpath='{.spec.components[0].containerImage}' 2>/dev/null)
    if [ -z "$CATALOG_IMAGE" ]; then
      MISSING+=("4.$V")
      continue
    fi

    SNAPSHOT_MAP[$V]="$SNAPSHOT"
    CATALOG_MAP[$V]="$CATALOG_IMAGE"

    run_parallel_job "verify-4-${V}" verify_snapshot_bundle "$V" "$CATALOG_IMAGE" "$VERSION"
  done

  if [ -f "$TMPDIR/pids.txt" ]; then
    if ! wait_parallel_jobs "snapshot verification"; then
      die "Failed to verify snapshot catalogs"
    fi
  fi

  if ! $RAW_URL; then
    echo "=== FBC Catalog URLs for Submariner $VERSION (from snapshots) ==="
    echo ""
  fi

  for V in "${VERSIONS[@]}"; do
    [ -z "${CATALOG_MAP[$V]:-}" ] && continue

    local RESULT_FILE="$TMPDIR/extract-4-${V}/result.txt"
    if [ ! -f "$RESULT_FILE" ] || [ "$(cat "$RESULT_FILE")" != "match" ]; then
      MISSING+=("4.$V")
      continue
    fi

    if $RAW_URL; then
      echo "${CATALOG_MAP[$V]}"
    else
      local SNAPSHOT="${SNAPSHOT_MAP[$V]}"
      echo "${KONFLUX_UI}/ns/${NAMESPACE}/applications/submariner-fbc-4-${V}/snapshots/${SNAPSHOT}"
      echo "${CATALOG_MAP[$V]}"
      echo ""
    fi

    # Populate QE_CATALOG_URLS so Phase 3 writes the snapshot URLs to the Jira
    # subtask even when the primary Release-CR path found nothing (CRs GC'd).
    QE_CATALOG_URLS+=("OCP 4.${V}: ${CATALOG_MAP[$V]} (pre-release snapshot)")

    FOUND=$((FOUND + 1))
  done

  if ! $RAW_URL; then
    if [ ${#MISSING[@]} -gt 0 ]; then
      echo "---"
      echo "⚠ No $VERSION catalog found for: ${MISSING[*]}"
      echo ""
    fi
    echo "Found $FOUND/${#VERSIONS[@]} OCP versions"
  fi

  [ "$FOUND" -gt 0 ] || return 1
}

# ━━━ VERSION MATCHING ━━━

# Check if a release was built from a commit that added the requested version.
# Uses the PaC sha-title annotation which contains the git commit title
# (e.g., "Add bundle v0.24.0 to catalog").
release_matches_version() {
  local RELEASE="$1"
  local SHA_TITLE
  SHA_TITLE=$(oc get release "$RELEASE" -n "$NAMESPACE" \
    -o jsonpath='{.metadata.annotations.pac\.test\.appstudio\.openshift\.io/sha-title}' 2>/dev/null)
  echo "$SHA_TITLE" | head -1 | grep -q "v${VERSION}"
}

# ━━━ URL EXTRACTION ━━━

get_urls() {
  local FOUND=0
  local MISSING=()
  local VERSIONS=("${ALL_OCP_VERSIONS[@]}")

  if [ -n "$OCP_FILTER" ]; then
    VERSIONS=("$OCP_FILTER")
  fi

  for V in "${VERSIONS[@]}"; do
    # Get all succeeded releases for this OCP version (newest last)
    local RELEASES
    RELEASES=$(oc get releases -n "$NAMESPACE" --no-headers 2>/dev/null \
      | grep "submariner-fbc-4-${V}-.*Succeeded" \
      | awk '{print $1}' || true)

    if [ -z "$RELEASES" ]; then
      MISSING+=("4.$V")
      continue
    fi

    # Walk backwards (newest first) to find matching release
    local MATCH=""
    while IFS= read -r REL; do
      if release_matches_version "$REL"; then
        MATCH="$REL"
        break
      fi
    done <<< "$(echo "$RELEASES" | tac)"

    if [ -z "$MATCH" ]; then
      MISSING+=("4.$V")
      continue
    fi

    local FBC_FRAG
    FBC_FRAG=$(oc get release "$MATCH" -n "$NAMESPACE" -o jsonpath='{.status.artifacts.components[0].fbc_fragment}') || true

    # Capture the catalog fragment for the QE subtask (populated in main).
    if [ -z "$FBC_FRAG" ]; then
      MISSING+=("4.$V")
      continue
    fi
    QE_CATALOG_URLS+=("OCP 4.${V}: ${FBC_FRAG}")

    if $RAW_URL; then
      echo "$FBC_FRAG"
    else
      local SNAPSHOT PLR_FULL PLR
      SNAPSHOT=$(oc get release "$MATCH" -n "$NAMESPACE" -o jsonpath='{.spec.snapshot}')
      PLR_FULL=$(oc get release "$MATCH" -n "$NAMESPACE" -o jsonpath='{.status.managedProcessing.pipelineRun}')
      PLR="${PLR_FULL##*/}"

      echo "${KONFLUX_UI}/ns/${NAMESPACE}/applications/submariner-fbc-4-${V}/snapshots/${SNAPSHOT}"
      echo "${KONFLUX_UI}/ns/rhtap-releng-tenant/applications/submariner-fbc-4-${V}/pipelineruns/${PLR}?releaseName=${MATCH}"
      echo "$FBC_FRAG"
      echo ""
    fi

    FOUND=$((FOUND + 1))
  done

  if [ "$FOUND" -gt 0 ]; then
    if ! $RAW_URL; then
      if [ ${#MISSING[@]} -gt 0 ]; then
        echo "---"
        echo "⚠ No $VERSION release found for: ${MISSING[*]}"
        echo ""
      fi
      echo "Found $FOUND/${#VERSIONS[@]} OCP versions"
    fi
    return 0
  fi

  # Fallback: try snapshot lookup from local YAML files
  get_urls_from_snapshots || die "No FBC releases found for Submariner $VERSION" \
    "Checked: Release CRs on cluster, snapshots from local YAML files"
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

main "$@"
