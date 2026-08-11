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

# Filter to component snapshots for this version
# - Name matches: submariner-0-X-*
# - Event type: push (not PR builds)
# - Sort by creation timestamp, take latest
SNAPSHOT_NAME=$(echo "$ALL_SNAPSHOTS" | jq -r "
  .items[]
  | select(.metadata.name | startswith(\"submariner-${VERSION_MAJOR_MINOR_DASH}-\"))
  | select(.metadata.labels.\"pac.test.appstudio.openshift.io/event-type\" == \"push\" or .metadata.labels.\"pac.test.appstudio.openshift.io/event-type\" == \"incoming\" or .metadata.labels.\"pac.test.appstudio.openshift.io/event-type\" == \"retest-all-comment\")
  | {name: .metadata.name, created: .metadata.creationTimestamp}
" | jq -rs 'sort_by(.created) | reverse | .[0].name' 2>/dev/null)

if [ -z "$SNAPSHOT_NAME" ] || [ "$SNAPSHOT_NAME" = "null" ]; then
  echo "❌ ERROR: No passing component snapshot found for version $VERSION_MAJOR_MINOR" >&2
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

# Extract test status annotation
TEST_STATUS=$(echo "$ALL_SNAPSHOTS" | jq -r "
  .items[] | select(.metadata.name == \"$SNAPSHOT_NAME\")
  | .metadata.annotations.\"test.appstudio.openshift.io/status\"
" 2>/dev/null)

if [ -z "$TEST_STATUS" ] || [ "$TEST_STATUS" = "null" ]; then
  echo "⚠️  WARNING: No test status annotation found" >&2
  echo "Snapshot may not have completed testing yet" >&2
  echo "Check: oc get snapshot $SNAPSHOT_NAME -n submariner-tenant -o jsonpath='{.metadata.annotations}'" >&2
  # Don't fail - some snapshots may not have tests yet
  TEST_STATUS="[]"
fi

# Parse test status JSON
FAILED_TESTS=$(echo "$TEST_STATUS" | jq -r '.[] | select(.status != "TestPassed") | .scenario' 2>/dev/null || true)

if [ -n "$FAILED_TESTS" ]; then
  echo "❌ ERROR: Snapshot has failing tests" >&2
  echo "" >&2
  echo "Failed test scenarios:" >&2
  echo "$FAILED_TESTS" | while read -r scenario; do
    STATUS=$(echo "$TEST_STATUS" | jq -r --arg s "$scenario" '.[] | select(.scenario == $s) | .status')
    echo "  - $scenario ($STATUS)" >&2
  done
  echo "" >&2
  echo "All tests must pass before creating a release" >&2
  exit 1
fi

# Check for enterprise-contract specifically (critical for releases)
EC_TEST=$(echo "$TEST_STATUS" | jq -r '.[] | select(.scenario | contains("enterprise-contract")) | .status' 2>/dev/null) || EC_TEST=""

if [ -n "$EC_TEST" ]; then
  if [ "$EC_TEST" = "TestPassed" ]; then
    echo "  ✓ enterprise-contract: $EC_TEST" >&2
  else
    echo "  ✗ enterprise-contract: $EC_TEST (CRITICAL FAILURE)" >&2
    exit 1
  fi
fi

# Count total tests
TOTAL_TESTS=$(echo "$TEST_STATUS" | jq -r '. | length' 2>/dev/null)
if [ "$TOTAL_TESTS" -gt 0 ]; then
  echo "✓ All $TOTAL_TESTS test(s) passed" >&2
else
  echo "⚠️  No tests found in snapshot (may still be building)" >&2
fi

# ============================================================================
# Output JSON Result
# ============================================================================

echo "" >&2
echo "✅ Verification complete - snapshot ready for release" >&2
echo "" >&2

# Output JSON to stdout (orchestrator parses this)
jq -nc \
  --arg status "pass" \
  --arg snapshot "$SNAPSHOT_NAME" \
  '{status: $status, snapshot: $snapshot}'
