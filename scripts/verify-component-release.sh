#!/bin/bash
# Verify component release readiness
#
# Usage: verify-component-release.sh <version>
#
# Arguments:
#   version: Submariner version (e.g., 0.22.1 or 0.22)
#
# Output:
#   stderr: Diagnostic output (✓/✗ messages)
#   stdout: JSON result {"status": "pass|fail", "snapshot": "name"}
#
# Exit codes:
#   0: Success (verification passed)
#   1: Failure (no snapshot found or verification failed)

set -euo pipefail

# ============================================================================
# Argument Parsing and Version Detection
# ============================================================================

if [ $# -ne 1 ]; then
  echo "❌ ERROR: Invalid number of arguments" >&2
  echo "Usage: $0 <version>" >&2
  echo "Example: $0 0.22.1" >&2
  exit 1
fi

VERSION="$1"

# Validate version format (X.Y or X.Y.Z)
if [[ "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
  :  # Version format is valid
else
  echo "❌ ERROR: Invalid version format: $VERSION" >&2
  echo "Expected: X.Y or X.Y.Z (e.g., 0.22 or 0.22.1)" >&2
  exit 1
fi

# Extract major.minor version for snapshot filtering
# 0.22.1 → 0.22, 0.22 → 0.22
VERSION_MAJOR_MINOR=$(echo "$VERSION" | grep -oE '^[0-9]+\.[0-9]+')
VERSION_MAJOR_MINOR_DASH="${VERSION_MAJOR_MINOR//./-}"  # 0.22 → 0-22

echo "=== Verifying Component Release Readiness ===" >&2
echo "" >&2
echo "Version: $VERSION_MAJOR_MINOR (searching for submariner-${VERSION_MAJOR_MINOR_DASH}- snapshots)" >&2
echo "" >&2

# ============================================================================
# Find Latest Component Snapshot
# ============================================================================

echo "Querying Konflux for component snapshots..." >&2

# Batched query (1 API call instead of many)
# Use `if ! VAR=$(...)` so a failed oc call surfaces this error: a bare
# `VAR=$(cmd)` under set -e aborts the script silently before the guard runs.
# `|| [ -z ... ]` also catches an empty-but-rc0 result.
if ! ALL_SNAPSHOTS=$(oc get snapshots -n submariner-tenant -o json 2>/dev/null) \
   || [ -z "$ALL_SNAPSHOTS" ]; then
  echo "❌ ERROR: Failed to query snapshots from cluster" >&2
  echo "Check: oc login status and network connectivity" >&2
  exit 1
fi

# Use the same branch-build selector and completion contract as release status.
# shellcheck source=lib/integration-tests.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/integration-tests.sh"
SNAPSHOT_JSON=$(latest_component_snapshot "submariner-$VERSION_MAJOR_MINOR_DASH" <<< "$ALL_SNAPSHOTS") || SNAPSHOT_JSON=""
SNAPSHOT_NAME=$(jq -r '.metadata.name // empty' <<< "$SNAPSHOT_JSON")

if [ -z "$SNAPSHOT_NAME" ] || [ "$SNAPSHOT_NAME" = "null" ]; then
  echo "❌ ERROR: No qualifying branch-build component snapshot found for version $VERSION_MAJOR_MINOR" >&2
  echo "" >&2
  echo "Possible causes:" >&2
  echo "- Step 7 not complete (bundle not built)" >&2
  echo "- Latest snapshot is from PR (not push/incoming/retest event)" >&2
  echo "- Check: oc get snapshots -n submariner-tenant | grep submariner-${VERSION_MAJOR_MINOR_DASH}" >&2
  exit 1
fi

# Extract creation timestamp for display
SNAPSHOT_CREATED=$(echo "$ALL_SNAPSHOTS" | jq -r "
  .items[] | select(.metadata.name == \"$SNAPSHOT_NAME\") | .metadata.creationTimestamp
")

echo "✓ Found snapshot: $SNAPSHOT_NAME (created $SNAPSHOT_CREATED)" >&2

# ============================================================================
# Verify 9 Components Present
# ============================================================================

echo "" >&2
echo "Verifying snapshot has all 9 components..." >&2

# Expected components (must all be present)
EXPECTED_COMPONENTS=(
  "submariner-operator-${VERSION_MAJOR_MINOR_DASH}"
  "submariner-gateway-${VERSION_MAJOR_MINOR_DASH}"
  "submariner-globalnet-${VERSION_MAJOR_MINOR_DASH}"
  "submariner-route-agent-${VERSION_MAJOR_MINOR_DASH}"
  "lighthouse-agent-${VERSION_MAJOR_MINOR_DASH}"
  "lighthouse-coredns-${VERSION_MAJOR_MINOR_DASH}"
  "nettest-${VERSION_MAJOR_MINOR_DASH}"
  "subctl-${VERSION_MAJOR_MINOR_DASH}"
  "submariner-bundle-${VERSION_MAJOR_MINOR_DASH}"
)

# Extract actual components from snapshot
ACTUAL_COMPONENTS=$(echo "$ALL_SNAPSHOTS" | jq -r "
  .items[] | select(.metadata.name == \"$SNAPSHOT_NAME\") | .spec.components[].name
" | sort)

MISSING_COMPONENTS=()
for EXPECTED in "${EXPECTED_COMPONENTS[@]}"; do
  if echo "$ACTUAL_COMPONENTS" | grep -qx "$EXPECTED"; then
    echo "  ✓ $EXPECTED" >&2
  else
    echo "  ✗ $EXPECTED (MISSING)" >&2
    MISSING_COMPONENTS+=("$EXPECTED")
  fi
done

if [ ${#MISSING_COMPONENTS[@]} -gt 0 ]; then
  echo "" >&2
  echo "❌ ERROR: Snapshot missing ${#MISSING_COMPONENTS[@]} component(s)" >&2
  echo "Expected 9 components, found $((9 - ${#MISSING_COMPONENTS[@]}))" >&2
  echo "Missing: ${MISSING_COMPONENTS[*]}" >&2
  exit 1
fi

echo "✓ All 9 components present in snapshot" >&2

# ============================================================================
# Verify All Tests Passed
# ============================================================================

echo "" >&2
echo "Verifying all tests passed..." >&2

if ! component_tests_passed <<< "$SNAPSHOT_JSON"; then
  echo "❌ ERROR: Snapshot integration is not finished and successful" >&2
  echo "Missing, malformed, failed or incomplete results cannot establish release readiness" >&2
  echo "Check snapshot $SNAPSHOT_NAME aggregate conditions and completed scenario results" >&2
  exit 1
fi
TOTAL_TESTS=$(jq -r '.metadata.annotations["test.appstudio.openshift.io/status"] | fromjson | length' <<< "$SNAPSHOT_JSON")
echo "✓ All $TOTAL_TESTS test(s) finished successfully" >&2

# ============================================================================
# Output JSON Result
# ============================================================================

echo "" >&2
echo "✅ Snapshot components and completed integration verified" >&2
echo "" >&2

# Output JSON to stdout (orchestrator parses this)
jq -nc \
  --arg status "pass" \
  --arg snapshot "$SNAPSHOT_NAME" \
  '{status: $status, snapshot: $snapshot}'
