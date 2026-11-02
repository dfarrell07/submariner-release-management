#!/usr/bin/env bash
# Verify component release readiness
#
# Usage: verify-component-release.sh <version> [snapshot | --list]
#
# Arguments:
#   version:  Submariner version (e.g., 0.22.1 or 0.22)
#   snapshot: verify this snapshot instead of the newest one
#   --list:   print the newest 20 qualifying snapshots, newest
#             first, as "<name> <bundle digest>" lines, and verify nothing
#
# Output:
#   stderr: Diagnostic output (✓/✗ messages)
#   stdout: JSON result {"status": "pass|fail", "snapshot": "name"}
#
# Exit codes:
#   0: Success (verification passed)
#   1: Failure (no snapshot found or verification failed)
#   2: Snapshots could not be read (retry)

set -euo pipefail

# ============================================================================
# Argument Parsing and Version Detection
# ============================================================================

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
  echo "❌ ERROR: Invalid number of arguments" >&2
  echo "Usage: $0 <version> [snapshot | --list]" >&2
  echo "Example: $0 0.22.1" >&2
  exit 1
fi

VERSION="$1"
SNAPSHOT_ARG="${2:-}"
# The same window bundle-image-update.sh searches for a passing snapshot.
SNAPSHOT_WINDOW=20

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

# Batched query (1 API call instead of many); a named snapshot is read alone.
# Use `if ! VAR=$(...)` so a failed oc call surfaces this error: a bare
# `VAR=$(cmd)` under set -e aborts the script silently before the guard runs.
# `|| [ -z ... ]` also catches an empty-but-rc0 result.
if [ -n "$SNAPSHOT_ARG" ] && [ "$SNAPSHOT_ARG" != "--list" ]; then
  QUERY=(oc get snapshot "$SNAPSHOT_ARG" -n submariner-tenant -o json)
else
  QUERY=(oc get snapshots -n submariner-tenant -o json)
fi
if ! ALL_SNAPSHOTS=$("${QUERY[@]}" 2>/dev/null | jq 'if .items then . else {items: [.]} end') \
   || [ -z "$ALL_SNAPSHOTS" ]; then
  echo "❌ ERROR: Failed to query snapshots from cluster" >&2
  echo "Check: oc login status and network connectivity" >&2
  exit 2
fi

# shellcheck source=lib/integration-tests.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/integration-tests.sh"

# Filter to component snapshots for this version
# - Name matches: submariner-0-X-*
# - Event type: push (not PR builds)
# - Sort by creation timestamp, newest first
CANDIDATES=$(component_snapshot_candidates "submariner-${VERSION_MAJOR_MINOR_DASH}" <<< "$ALL_SNAPSHOTS" | jq -r \
  --arg bundle "submariner-bundle-${VERSION_MAJOR_MINOR_DASH}" \
  --argjson n "$SNAPSHOT_WINDOW" '
  .[:$n][] |
  "\(.metadata.name) \([.spec.components[]? | select(.name == $bundle)
      | (.containerImage // "" | try capture("(?<d>sha256:[a-f0-9]+)").d catch empty)][0] // "-")"
') || { echo "❌ ERROR: Invalid snapshot evidence" >&2; exit 2; }

if [ "$SNAPSHOT_ARG" = "--list" ]; then
  [ -z "$CANDIDATES" ] || printf '%s\n' "$CANDIDATES"
  exit 0
fi
SNAPSHOT_NAME=$(echo "$CANDIDATES" | head -1 | cut -d' ' -f1)

if [ -z "$SNAPSHOT_NAME" ] && [ -n "$SNAPSHOT_ARG" ]; then
  echo "❌ ERROR: $SNAPSHOT_ARG is not a push snapshot for version $VERSION_MAJOR_MINOR" >&2
  exit 1
fi
if [ -z "$SNAPSHOT_NAME" ]; then
  echo "❌ ERROR: No passing component snapshot found for version $VERSION_MAJOR_MINOR" >&2
  echo "" >&2
  echo "Possible causes:" >&2
  echo "- Step 7 not complete (bundle not built)" >&2
  echo "- Latest snapshot is from PR (not push/incoming/retest event)" >&2
  echo "- Check: oc get snapshots -n submariner-tenant | grep submariner-${VERSION_MAJOR_MINOR_DASH}" >&2
  exit 1
fi

SNAPSHOT_JSON=$(jq -c --arg name "$SNAPSHOT_NAME" ' .items[] | select(.metadata.name == $name)' <<< "$ALL_SNAPSHOTS")

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

# Names and immutable images identify the candidate payload; successful tests
# cannot certify a malformed, duplicated or incomplete component set.
if ! component_payload_valid "submariner-${VERSION_MAJOR_MINOR_DASH}" <<< "$SNAPSHOT_JSON"; then
  echo "❌ ERROR: Invalid component payload: require exactly nine expected components, each with an immutable SHA256 image" >&2
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
