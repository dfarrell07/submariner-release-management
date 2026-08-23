#!/bin/bash
# Verify FBC release readiness (combined snapshot + component SHA verification)
#
# Usage: verify-fbc-release.sh <version>
#
# Arguments:
#   version: Submariner version (e.g., 0.22.1 or 0.22)
#
# Output: JSON with combined verification results (stdout)
# Exit codes:
#   0: Success (all verifications passed)
#   1: Failure (any verification failed)
#
# Optimizations:
#   - Batched OC queries: 1 API call instead of 30
#   - Single-pass extraction: Extract each snapshot once (not twice)
#   - Parallel extraction: 7 simultaneous extracts (added in Phase 2)

set -euo pipefail

# ============================================================================
# Argument Parsing and Setup
# ============================================================================

# Validate arguments
if [ $# -ne 1 ]; then
  echo "❌ ERROR: Invalid number of arguments" >&2
  echo "Usage: $0 <version>" >&2
  echo "Example: $0 0.22.1" >&2
  exit 1
fi

VERSION_INPUT="$1"

# Extract major.minor (0.22.1 → 0.22)
if [[ "$VERSION_INPUT" =~ ^[0-9]+\.[0-9]+ ]]; then
  :  # Version format is valid
else
  echo "❌ ERROR: Invalid version format: $VERSION_INPUT" >&2
  echo "Expected: 0.Y or 0.Y.Z (e.g., 0.22 or 0.22.1)" >&2
  exit 1
fi

# Extract version components
MAJOR_MINOR=$(echo "$VERSION_INPUT" | grep -oP '^\d+\.\d+')
FULL_VERSION="$VERSION_INPUT"
MAJOR=$(echo "$MAJOR_MINOR" | cut -d. -f1)
MINOR=$(echo "$MAJOR_MINOR" | cut -d. -f2)
HYPHENATED="${MAJOR}-${MINOR}"  # 0-22

# Single tmpdir with trap cleanup
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

echo "=== FBC Release Verification ===" >&2
echo "Version: $FULL_VERSION (branch: release-$MAJOR_MINOR, components: *-$HYPHENATED)" >&2
echo "" >&2

# ============================================================================
# Parallel Job Execution Helpers (shared lib, relies on global TMPDIR)
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/parallel-jobs.sh
source "$SCRIPT_DIR/lib/parallel-jobs.sh"
# shellcheck source=lib/fbc-scope.sh
source "$SCRIPT_DIR/lib/fbc-scope.sh"

# ============================================================================
# Step 1: Verify GitHub Catalog Consistency
# ============================================================================

echo "Step 1: Verifying GitHub catalog consistency..." >&2

declare -A BUNDLE_SHAS
declare -a APPLICABLE_VERSIONS
SKIPPED=0

# Check all OCP versions that have ever been supported (including retired 4.14 and 4.15):
# bundles that no longer exist return 404 and are skipped gracefully, so over-including
# older versions is safe and prevents silently missing a catalog inconsistency.
for VERSION in 14 15 $FBC_OCP_VERSIONS; do
  CATALOG_URL="https://raw.githubusercontent.com/stolostron/submariner-operator-fbc/main/catalog-4-${VERSION}/bundles/bundle-v${FULL_VERSION}.yaml"

  # Fetch bundle by HTTP status, not curl's -f exit code: -f collapses 404
  # (bundle legitimately absent for this OCP version → skip) and 429/5xx
  # (transient CDN/rate-limit error) into the same exit 22. Treating a transient
  # error as "absent" would silently drop an OCP version we should release.
  CATALOG_FILE="$TMPDIR/catalog-4-${VERSION}.yaml"
  HTTP_CODE=$(curl -s -o "$CATALOG_FILE" -w '%{http_code}' "$CATALOG_URL") || HTTP_CODE="000"
  case "$HTTP_CODE" in
    200) BUNDLE_SHA=$(grep "^image:" "$CATALOG_FILE" | head -1 | grep -oP 'sha256:\K[a-f0-9]+' || true) ;;
    404) BUNDLE_SHA="" ;;
    *)   echo "✗ ERROR: unexpected HTTP $HTTP_CODE fetching catalog for 4-${VERSION}" >&2
         echo "  ($CATALOG_URL)" >&2
         echo "  Refusing to silently drop an OCP version on a transient error." >&2
         exit 1 ;;
  esac

  if [ -z "$BUNDLE_SHA" ]; then
    echo "  4-${VERSION}: - bundle not in catalog (skipped)" >&2
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  BUNDLE_SHAS["4-${VERSION}"]="$BUNDLE_SHA"
  APPLICABLE_VERSIONS+=("$VERSION")
  echo "  4-${VERSION}: ${BUNDLE_SHA:0:12}..." >&2
done

if [ ${#APPLICABLE_VERSIONS[@]} -eq 0 ]; then
  echo "" >&2
  echo "✗ ERROR: Bundle v${FULL_VERSION} not found in any OCP catalog" >&2
  exit 1
fi

# Check if all SHAs are the same
UNIQUE_SHAS=$(printf '%s\n' "${BUNDLE_SHAS[@]}" | sort -u | wc -l)

if [ "$UNIQUE_SHAS" -ne 1 ]; then
  echo "" >&2
  echo "✗ ERROR: FBC catalog bundle SHA mismatch:" >&2
  for VERSION in "${APPLICABLE_VERSIONS[@]}"; do
    echo "  4-${VERSION}: ${BUNDLE_SHAS[4-${VERSION}]}" >&2
  done
  echo "" >&2
  echo "Remediation:" >&2
  echo "1. Check if Step 11 (FBC catalog update) completed correctly" >&2
  echo "2. Verify all catalogs were updated with same bundle SHA" >&2
  echo "3. Re-run Step 11 if needed" >&2
  exit 1
fi

# Get the common SHA
EXPECTED_BUNDLE_SHA="${BUNDLE_SHAS[4-${APPLICABLE_VERSIONS[0]}]}"
echo "" >&2
echo "✓ Bundle SHA consistent across ${#APPLICABLE_VERSIONS[@]} GitHub catalogs (${SKIPPED} skipped): ${EXPECTED_BUNDLE_SHA:0:12}..." >&2

# ============================================================================
# Step 2: Batch Fetch All Snapshots (OPTIMIZATION: 1 query vs 30)
# ============================================================================

echo "" >&2
echo "Step 2: Fetching FBC snapshots (batched query)..." >&2

# ONE query for all snapshots (vs 6 list + 24 individual gets).
# Use `if ! VAR=$(...)` so a failed oc call surfaces a friendly error: a bare
# `VAR=$(cmd)` under set -e aborts the script silently at this line before any
# guard below could run. `|| [ -z ... ]` also catches an empty-but-rc0 result.
if ! ALL_SNAPSHOTS=$(oc get snapshots -n submariner-tenant -o json 2>/dev/null) \
   || [ -z "$ALL_SNAPSHOTS" ]; then
  echo "❌ ERROR: Failed to query snapshots from cluster (check oc login / network)" >&2
  exit 1
fi

# Save for debugging
echo "$ALL_SNAPSHOTS" > "$TMPDIR/snapshots.json"

# Extract data for each OCP version using jq (local filtering, no API calls)
declare -A SNAPSHOTS
declare -A CATALOG_IMAGES
declare -A EVENT_TYPES
declare -A TEST_STATUSES

declare -a RELEASABLE_VERSIONS
SKIPPED_SNAPSHOTS=0

for VERSION in "${APPLICABLE_VERSIONS[@]}"; do
  # Filter for this version, prefer push/incoming events (releasable), fall back to latest
  SNAPSHOT_DATA=""
  SNAPSHOT_DATA=$(echo "$ALL_SNAPSHOTS" | jq -r \
    ".items[] | select(.metadata.name | startswith(\"submariner-fbc-4-${VERSION}\")) |
    select(.metadata.creationTimestamp != null) |
    {name: .metadata.name,
     event: .metadata.labels[\"pac.test.appstudio.openshift.io/event-type\"],
     tests: .metadata.annotations[\"test.appstudio.openshift.io/status\"],
     image: .spec.components[0].containerImage,
     timestamp: .metadata.creationTimestamp} |
    @json" | jq -s 'sort_by(.timestamp) |
    (map(select(.event == "push" or .event == "incoming" or .event == "retest-all-comment")) | last) //
    last')

  if [ -z "$SNAPSHOT_DATA" ] || [ "$SNAPSHOT_DATA" = "null" ]; then
    echo "  4-${VERSION}: - no snapshot (skipped, no build pipeline)" >&2
    SKIPPED_SNAPSHOTS=$((SKIPPED_SNAPSHOTS + 1))
    continue
  fi

  # Parse JSON into associative arrays
  SNAPSHOTS["4-${VERSION}"]=$(echo "$SNAPSHOT_DATA" | jq -r '.name')
  CATALOG_IMAGES["4-${VERSION}"]=$(echo "$SNAPSHOT_DATA" | jq -r '.image')
  EVENT_TYPES["4-${VERSION}"]=$(echo "$SNAPSHOT_DATA" | jq -r '.event // "unknown"')
  TEST_STATUSES["4-${VERSION}"]=$(echo "$SNAPSHOT_DATA" | jq -r '.tests // "{}"')

  RELEASABLE_VERSIONS+=("$VERSION")
  echo "  4-${VERSION}: ${SNAPSHOTS[4-${VERSION}]}" >&2
done

if [ ${#RELEASABLE_VERSIONS[@]} -eq 0 ]; then
  echo "" >&2
  echo "✗ ERROR: No releasable FBC snapshots found" >&2
  exit 1
fi

echo "" >&2
echo "✓ Found ${#RELEASABLE_VERSIONS[@]} FBC snapshots (${SKIPPED_SNAPSHOTS} skipped)" >&2

# Narrow APPLICABLE_VERSIONS to only those with snapshots
APPLICABLE_VERSIONS=("${RELEASABLE_VERSIONS[@]}")

# ============================================================================
# Step 3: Single-Pass Bundle Extraction (OPTIMIZATION: Parallel + extract once)
# ============================================================================

echo "" >&2
echo "Step 3: Extracting bundles from snapshots (parallel, single-pass)..." >&2

# Extract each snapshot's bundle ONCE (not twice like old scripts)
# Use parallel execution for 7 simultaneous extractions
# Bundle YAMLs stay in tmpdir for both bundle SHA AND component SHA verification

# Define extraction function for parallel execution
extract_single_bundle() {
    local VERSION="$1"
    local SNAPSHOT="$2"
    local CATALOG_IMAGE="$3"
    local FULL_VERSION="$4"

    # Each version gets own directory
    local EXTRACT_DIR="$TMPDIR/extract-4-${VERSION}"
    mkdir -p "$EXTRACT_DIR"

    # Extract bundle YAML (suppress output)
    oc image extract "$CATALOG_IMAGE" \
        --path "/configs/submariner/bundles/bundle-v${FULL_VERSION}.yaml:$EXTRACT_DIR/" \
        --confirm > /dev/null 2>&1

    # Verify file exists and extract SHA
    local BUNDLE_YAML="$EXTRACT_DIR/bundle-v${FULL_VERSION}.yaml"
    if [ ! -f "$BUNDLE_YAML" ]; then
        echo "Failed to extract bundle from $SNAPSHOT" >&2
        return 1
    fi

    local SNAPSHOT_BUNDLE_SHA
    SNAPSHOT_BUNDLE_SHA=$(grep "^image:" "$BUNDLE_YAML" | head -1 | grep -oP 'sha256:\K[a-f0-9]+' || true)
    if [ -z "$SNAPSHOT_BUNDLE_SHA" ]; then
        echo "Failed to extract SHA from bundle" >&2
        return 1
    fi

    # Save SHA for later use
    echo "$SNAPSHOT_BUNDLE_SHA" > "$EXTRACT_DIR/bundle-sha.txt"

    echo "  4-${VERSION}: ✓ ${SNAPSHOT_BUNDLE_SHA:0:12}..." >&2
}

# Export function and variables for subshells
export -f extract_single_bundle
export TMPDIR FULL_VERSION

# Launch parallel extraction jobs
for VERSION in "${APPLICABLE_VERSIONS[@]}"; do
    run_parallel_job "extract-4-${VERSION}" extract_single_bundle \
        "$VERSION" "${SNAPSHOTS[4-${VERSION}]}" "${CATALOG_IMAGES[4-${VERSION}]}" "$FULL_VERSION"
done

# Wait for all extractions to complete and check for errors
if ! wait_parallel_jobs "bundle extraction"; then
    echo "" >&2
    echo "✗ ERROR: Bundle extraction failed" >&2
    exit 1
fi

echo "" >&2
echo "✓ Extracted all ${#APPLICABLE_VERSIONS[@]} bundles (parallel, single-pass)" >&2

# ============================================================================
# Step 4: Verify Snapshot Readiness
# ============================================================================

echo "" >&2
echo "Step 4: Verifying snapshot readiness..." >&2

declare -A VERIFIED_SNAPSHOTS
FAILED=0
FAILED_DETAILS=""

for VERSION in "${APPLICABLE_VERSIONS[@]}"; do
  SNAPSHOT="${SNAPSHOTS[4-${VERSION}]}"
  EVENT_TYPE="${EVENT_TYPES[4-${VERSION}]}"
  TESTS_JSON="${TEST_STATUSES[4-${VERSION}]}"
  SNAPSHOT_BUNDLE_SHA=$(cat "$TMPDIR/extract-4-${VERSION}/bundle-sha.txt")

  # Verify event type (push, incoming, and retest-all-comment are main-branch builds; reject PR)
  if [ "$EVENT_TYPE" != "push" ] && [ "$EVENT_TYPE" != "incoming" ] && [ "$EVENT_TYPE" != "retest-all-comment" ]; then
    echo "  4-${VERSION}: ✗ Event type '$EVENT_TYPE' (must be 'push', 'incoming', or 'retest-all-comment')" >&2
    FAILED_DETAILS="${FAILED_DETAILS}    4-${VERSION}: Event type '$EVENT_TYPE' (not a main-branch build)\n"
    FAILED=$((FAILED + 1))
    continue
  fi

  # Verify tests passed
  if [ -z "$TESTS_JSON" ] || [ "$TESTS_JSON" = "{}" ]; then
    echo "  4-${VERSION}: ✗ No test status" >&2
    FAILED_DETAILS="${FAILED_DETAILS}    4-${VERSION}: No test status\n"
    FAILED=$((FAILED + 1))
    continue
  fi

  # Check for any non-passing tests. Emit scenario:status so the operator can
  # distinguish a transient BuildPLRInProgress from a persistent failure.
  FAILED_TESTS=$(echo "$TESTS_JSON" | jq -r '.[] | select(.status != "TestPassed") | "\(.scenario): \(.status)"' 2>/dev/null || true)
  if [ -n "$FAILED_TESTS" ]; then
    echo "  4-${VERSION}: ✗ Tests failed: $FAILED_TESTS" >&2
    # If every failing test is BuildPLRInProgress and the snapshot is old, the
    # pipeline may be stuck rather than still building.
    if printf '%s\n' "$FAILED_TESTS" | grep -q "BuildPLRInProgress" && \
       ! printf '%s\n' "$FAILED_TESTS" | grep -qv "BuildPLRInProgress"; then
      SNAP_TS=$(oc get snapshot "$SNAPSHOT" -n submariner-tenant \
        -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null || true)
      if [ -n "$SNAP_TS" ]; then
        SNAP_EPOCH=$(date -d "$SNAP_TS" +%s 2>/dev/null || echo 0)
        NOW_EPOCH=$(date +%s)
        AGE_MIN=$(( (NOW_EPOCH - SNAP_EPOCH) / 60 ))
        if [ "$AGE_MIN" -gt 45 ]; then
          echo "    ⚠ Snapshot is ${AGE_MIN}m old — pipeline may be stuck." >&2
          echo "      Check: oc get pipelineruns -n submariner-tenant | grep fbc-4-${VERSION}" >&2
        fi
      fi
    fi
    FAILED_DETAILS="${FAILED_DETAILS}    4-${VERSION}: Tests failed: $FAILED_TESTS\n"
    FAILED=$((FAILED + 1))
    continue
  fi

  # Verify bundle SHA matches GitHub
  if [ "$SNAPSHOT_BUNDLE_SHA" != "$EXPECTED_BUNDLE_SHA" ]; then
    echo "  4-${VERSION}: ✗ Bundle SHA mismatch (snapshot: ${SNAPSHOT_BUNDLE_SHA:0:12}, expected: ${EXPECTED_BUNDLE_SHA:0:12})" >&2
    FAILED_DETAILS="${FAILED_DETAILS}    4-${VERSION}: Bundle SHA mismatch\n"
    FAILED=$((FAILED + 1))
    continue
  fi

  # All checks passed
  echo "  4-${VERSION}: ✓ $SNAPSHOT ($EVENT_TYPE, tests passed, bundle SHA verified)" >&2
  VERIFIED_SNAPSHOTS["4-${VERSION}"]="$SNAPSHOT"
done

if [ $FAILED -gt 0 ]; then
  echo "" >&2
  echo "✗ ERROR: Snapshot verification failed for $FAILED version(s):" >&2
  echo -e "$FAILED_DETAILS" >&2
  echo "Remediation:" >&2
  echo "1. Wait for FBC rebuild after Step 11 merge (~15-30 min)" >&2
  echo "2. Check: oc get snapshots -n submariner-tenant | grep fbc" >&2
  echo "3. Verify event type and test status" >&2
  exit 1
fi

echo "" >&2
echo "✓ All ${#APPLICABLE_VERSIONS[@]} FBC snapshots ready for release" >&2

# ============================================================================
# Step 5: Extract Bundle Metadata (Source Commit)
# ============================================================================

echo "" >&2
echo "Step 5: Extracting bundle source commit..." >&2

# Get bundle image URL from FBC catalog (using first applicable version as representative - all verified identical)
REPRESENTATIVE_VERSION="${APPLICABLE_VERSIONS[0]}"
BUNDLE_IMAGE=$(curl -sf "https://raw.githubusercontent.com/stolostron/submariner-operator-fbc/main/catalog-4-${REPRESENTATIVE_VERSION}/bundles/bundle-v${FULL_VERSION}.yaml" | grep "^image:" | head -1 | awk '{print $2}' || true)

if [ -z "$BUNDLE_IMAGE" ]; then
  echo "❌ ERROR: Failed to fetch bundle image URL from FBC catalog" >&2
  echo "URL: https://raw.githubusercontent.com/stolostron/submariner-operator-fbc/main/catalog-4-${REPRESENTATIVE_VERSION}/bundles/bundle-v${FULL_VERSION}.yaml" >&2
  exit 1
fi

# Verify bundle SHA matches expected
BUNDLE_IMAGE_SHA=$(echo "$BUNDLE_IMAGE" | grep -oP 'sha256:\K[a-f0-9]+' || true)
if [ "$BUNDLE_IMAGE_SHA" != "$EXPECTED_BUNDLE_SHA" ]; then
  echo "❌ ERROR: Bundle SHA mismatch" >&2
  echo "  Expected (from snapshots): ${EXPECTED_BUNDLE_SHA:0:12}" >&2
  echo "  Found (in FBC catalog):    ${BUNDLE_IMAGE_SHA:0:12}" >&2
  exit 1
fi

echo "  ✓ Bundle image: $BUNDLE_IMAGE" >&2

# Extract source commit from OCI labels (try registry.redhat.io first, fallback to quay.io)
SOURCE_COMMIT=$(skopeo inspect "docker://${BUNDLE_IMAGE}" 2>/dev/null | jq -r '.Labels."org.opencontainers.image.revision"' || true)

if [ -z "$SOURCE_COMMIT" ] || [ "$SOURCE_COMMIT" = "null" ]; then
  # Fallback: try quay.io workspace URL from template
  echo "  ⚠ Bundle not found at ${BUNDLE_IMAGE%%@*}, trying quay.io workspace..." >&2
  BUNDLE_IMAGE_QUAY=$(curl -sf "https://raw.githubusercontent.com/stolostron/submariner-operator-fbc/main/catalog-template.yaml" | grep -A1 "name: submariner.v${FULL_VERSION}" | grep "image:" | awk '{print $2}' || true)

  if [ -n "$BUNDLE_IMAGE_QUAY" ]; then
    SOURCE_COMMIT=$(skopeo inspect "docker://${BUNDLE_IMAGE_QUAY}" 2>/dev/null | jq -r '.Labels."org.opencontainers.image.revision"' || true)
    if [ -n "$SOURCE_COMMIT" ] && [ "$SOURCE_COMMIT" != "null" ]; then
      echo "  ✓ Using quay.io bundle: $BUNDLE_IMAGE_QUAY" >&2
      BUNDLE_IMAGE="$BUNDLE_IMAGE_QUAY"
    fi
  fi
fi

if [ -z "$SOURCE_COMMIT" ] || [ "$SOURCE_COMMIT" = "null" ]; then
  echo "❌ ERROR: Failed to extract source commit from bundle image" >&2
  echo "Image (registry.redhat.io): $BUNDLE_IMAGE" >&2
  echo "Image (quay.io fallback): ${BUNDLE_IMAGE_QUAY:-NOT FOUND}" >&2
  exit 1
fi

echo "  ✓ Source commit: $SOURCE_COMMIT" >&2

# ============================================================================
# Step 6: Fetch Operator CSV from Source Commit
# ============================================================================

echo "" >&2
echo "Step 6: Fetching operator CSV from commit ${SOURCE_COMMIT:0:7}..." >&2

# Fetch CSV from specific commit (not branch HEAD)
OP_CSV=$(curl -sf "https://raw.githubusercontent.com/submariner-io/submariner-operator/${SOURCE_COMMIT}/bundle/manifests/submariner.clusterserviceversion.yaml" || true)
if [ -z "$OP_CSV" ]; then
  echo "❌ ERROR: Failed to fetch operator CSV from source commit" >&2
  echo "URL: https://raw.githubusercontent.com/submariner-io/submariner-operator/${SOURCE_COMMIT}/bundle/manifests/submariner.clusterserviceversion.yaml" >&2
  exit 1
fi

echo "  ✓ Fetched operator CSV from commit ${SOURCE_COMMIT:0:7}" >&2

# Fetch FBC bundle for comparison (using first applicable version as representative - all verified identical)
FBC_BUNDLE=$(curl -sf "https://raw.githubusercontent.com/stolostron/submariner-operator-fbc/main/catalog-4-${REPRESENTATIVE_VERSION}/bundles/bundle-v${FULL_VERSION}.yaml" || true)
if [ -z "$FBC_BUNDLE" ]; then
  echo "❌ ERROR: Failed to fetch FBC bundle from GitHub" >&2
  echo "URL: https://raw.githubusercontent.com/stolostron/submariner-operator-fbc/main/catalog-4-${REPRESENTATIVE_VERSION}/bundles/bundle-v${FULL_VERSION}.yaml" >&2
  exit 1
fi

echo "  ✓ Fetched FBC GitHub bundle" >&2

# ============================================================================
# Step 7: Verify Component SHAs Across All Sources
# ============================================================================

echo "" >&2
echo "Step 7: Verifying component SHAs across all sources..." >&2

# Component list with CSV name mappings
declare -A CSV_NAMES
CSV_NAMES["submariner-operator"]="submariner-operator"
CSV_NAMES["submariner-gateway"]="submariner-gateway"
CSV_NAMES["submariner-globalnet"]="submariner-globalnet"
CSV_NAMES["submariner-route-agent"]="submariner-routeagent"  # Note: routeagent (no dash)
CSV_NAMES["lighthouse-agent"]="submariner-lighthouse-agent"
CSV_NAMES["lighthouse-coredns"]="submariner-lighthouse-coredns"
CSV_NAMES["nettest"]="submariner-nettest"

MISMATCH=0
declare -A COMPONENT_RESULTS

for COMP in submariner-operator submariner-gateway submariner-globalnet submariner-route-agent lighthouse-agent lighthouse-coredns nettest; do
  CSV="${CSV_NAMES[$COMP]}"

  # Extract SHA from operator repo and FBC catalog (GitHub)
  # Special case for nettest: it has no name field, match by image URL pattern
  if [ "$COMP" = "nettest" ]; then
    OP_SHA=$(echo "$OP_CSV" | awk '/relatedImages:/,/selector:/' | grep "nettest-rhel9" | grep -oP 'sha256:\K[a-f0-9]+' | head -1 || true)
    FBC_SHA=$(echo "$FBC_BUNDLE" | awk '/relatedImages:/,/schema:/' | grep "nettest-rhel9" | grep -oP 'sha256:\K[a-f0-9]+' | head -1 || true)
  else
    OP_SHA=$(echo "$OP_CSV" | awk '/relatedImages:/,/selector:/' | grep -B1 "name: $CSV" | grep -oP 'sha256:\K[a-f0-9]+' || true)
    FBC_SHA=$(echo "$FBC_BUNDLE" | awk '/relatedImages:/,/schema:/' | grep -B1 "name: $CSV" | grep -oP 'sha256:\K[a-f0-9]+' || true)
  fi

  # Check if extraction succeeded
  if [ -z "$OP_SHA" ] || [ -z "$FBC_SHA" ]; then
    echo "  $COMP: ✗ SHA extraction failed" >&2
    echo "    Operator CSV (commit ${SOURCE_COMMIT:0:7}): ${OP_SHA:-NOT FOUND}" >&2
    echo "    FBC bundle (v${FULL_VERSION}): ${FBC_SHA:-NOT FOUND}" >&2
    COMPONENT_RESULTS[$COMP]="fail"
    MISMATCH=$((MISMATCH + 1))
    continue
  fi

  # Verify all 7 FBC snapshots have same SHA as operator repo (using extracted bundles)
  SNAP_MISMATCH=0
  for VERSION in "${APPLICABLE_VERSIONS[@]}"; do
    SNAPSHOT="${SNAPSHOTS[4-${VERSION}]}"
    BUNDLE_YAML="$TMPDIR/extract-4-${VERSION}/bundle-v${FULL_VERSION}.yaml"

    # Special case for nettest: match by image URL pattern
    if [ "$COMP" = "nettest" ]; then
      SNAP_SHA=$(awk '/relatedImages:/,/schema:/' "$BUNDLE_YAML" | grep "nettest-rhel9" | grep -oP 'sha256:\K[a-f0-9]+' | head -1 || true)
    else
      SNAP_SHA=$(awk '/relatedImages:/,/schema:/' "$BUNDLE_YAML" | grep -B1 "name: $CSV" | grep -oP 'sha256:\K[a-f0-9]+' || true)
    fi

    if [ -z "$SNAP_SHA" ]; then
      echo "  $COMP: ✗ Failed to extract SHA from snapshot $SNAPSHOT" >&2
      SNAP_MISMATCH=$((SNAP_MISMATCH + 1))
    elif [ "$SNAP_SHA" != "$OP_SHA" ]; then
      echo "  $COMP: ✗ Snapshot $SNAPSHOT SHA mismatch (${SNAP_SHA:0:12} vs ${OP_SHA:0:12})" >&2
      SNAP_MISMATCH=$((SNAP_MISMATCH + 1))
    fi
  done

  if [ $SNAP_MISMATCH -gt 0 ]; then
    COMPONENT_RESULTS[$COMP]="fail"
    MISMATCH=$((MISMATCH + 1))
    continue
  fi

  # Verify operator repo and FBC GitHub match
  if [ "$OP_SHA" != "$FBC_SHA" ]; then
    echo "  $COMP: ✗ SHA mismatch" >&2
    echo "    Operator repo:  ${OP_SHA:0:12}" >&2
    echo "    FBC GitHub:     ${FBC_SHA:0:12}" >&2
    COMPONENT_RESULTS[$COMP]="fail"
    MISMATCH=$((MISMATCH + 1))
    continue
  fi

  echo "  $COMP: ✓ ${OP_SHA:0:12}... (verified across all sources)" >&2
  COMPONENT_RESULTS[$COMP]="pass:${OP_SHA}"
done

# Summary
if [ $MISMATCH -gt 0 ]; then
  echo "" >&2
  echo "✗ $MISMATCH component(s) failed verification" >&2
  echo "" >&2
  echo "Remediation:" >&2
  echo "1. Verify Step 7 (update bundle SHAs) completed at commit $SOURCE_COMMIT" >&2
  echo "2. Check bundle CSV: https://github.com/submariner-io/submariner-operator/blob/${SOURCE_COMMIT}/bundle/manifests/submariner.clusterserviceversion.yaml" >&2
  echo "3. If SHAs don't match, re-run Step 7 (bundle SHA update)" >&2
  echo "4. If SHAs don't match FBC catalog, re-run Step 11 (FBC catalog update)" >&2
  exit 1
fi

echo "" >&2
echo "✓ All 7 components verified (operator commit ${SOURCE_COMMIT:0:7}, FBC GitHub, ${#APPLICABLE_VERSIONS[@]} FBC snapshots)" >&2

# ============================================================================
# Step 8: Output Combined JSON
# ============================================================================

# Build snapshots and applicable_versions JSON dynamically
SNAPSHOTS_JSON="{"
FIRST=true
for VERSION in "${APPLICABLE_VERSIONS[@]}"; do
  $FIRST || SNAPSHOTS_JSON+=","
  SNAPSHOTS_JSON+="\"4-${VERSION}\":\"${VERIFIED_SNAPSHOTS[4-${VERSION}]}\""
  FIRST=false
done
SNAPSHOTS_JSON+="}"

VERSIONS_JSON="["
FIRST=true
for VERSION in "${APPLICABLE_VERSIONS[@]}"; do
  $FIRST || VERSIONS_JSON+=","
  VERSIONS_JSON+="\"${VERSION}\""
  FIRST=false
done
VERSIONS_JSON+="]"

# Build component results JSON
COMPONENTS_JSON="{"
FIRST=true
for COMP in submariner-operator submariner-gateway submariner-globalnet submariner-route-agent lighthouse-agent lighthouse-coredns nettest; do
  $FIRST || COMPONENTS_JSON+=","
  C_STATUS=$(echo "${COMPONENT_RESULTS[$COMP]}" | cut -d: -f1)
  C_SHA=$(echo "${COMPONENT_RESULTS[$COMP]}" | cut -d: -f2)
  COMPONENTS_JSON+="\"${COMP}\":{\"status\":\"${C_STATUS}\",\"sha\":\"${C_SHA}\"}"
  FIRST=false
done
COMPONENTS_JSON+="}"

# Output JSON to stdout (single line for easy parsing)
echo "{\"status\":\"pass\",\"bundle_sha\":\"${EXPECTED_BUNDLE_SHA}\",\"source_commit\":\"${SOURCE_COMMIT}\",\"applicable_versions\":${VERSIONS_JSON},\"snapshots\":${SNAPSHOTS_JSON},\"components\":${COMPONENTS_JSON}}"
