#!/bin/bash
# Generate single component Release YAML
#
# Usage: generate-component-release.sh <version> <snapshot> <release-type> <release-date>
#
# Arguments:
#   version:       Submariner version (e.g., 0.22.1)
#   snapshot:      Snapshot name (e.g., submariner-0-22-xxxxx)
#   release-type:  stage or prod
#   release-date:  Release date in YYYYMMDD format
#
# Output: Path to created YAML file (stdout)
# Exit codes:
#   0: Success
#   1: Failure (invalid arguments, directory creation failed, write failed)

set -euo pipefail

# ============================================================================
# Argument Parsing
# ============================================================================

if [ $# -ne 4 ]; then
  echo "❌ ERROR: Invalid number of arguments" >&2
  echo "Usage: $0 <version> <snapshot> <release-type> <release-date>" >&2
  echo "Example: $0 0.22.1 submariner-0-22-abc123 stage 20260312" >&2
  exit 1
fi

VERSION="$1"
SNAPSHOT="$2"
RELEASE_TYPE="$3"
RELEASE_DATE="$4"

# ============================================================================
# Validation
# ============================================================================

# Validate version format (X.Y.Z)
if [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  :  # Version format is valid
else
  echo "❌ ERROR: Invalid version format: $VERSION" >&2
  echo "Expected: X.Y.Z (e.g., 0.22.1)" >&2
  echo "Note: This script requires full version including patch" >&2
  exit 1
fi

# Extract major.minor for directory structure (VERSION is validated X.Y.Z above,
# so %.* strips only the trailing patch segment — no subshell needed)
VERSION_MAJOR_MINOR="${VERSION%.*}"
VERSION_MAJOR_MINOR_DASH="${VERSION_MAJOR_MINOR//./-}"  # 0.22 → 0-22

# Version with dashes for naming (0.22.1 → 0-22-1)
VERSION_DASH="${VERSION//./-}"

# Validate release type
if [[ "$RELEASE_TYPE" != "stage" && "$RELEASE_TYPE" != "prod" ]]; then
  echo "❌ ERROR: Invalid release type: $RELEASE_TYPE" >&2
  echo "Expected: stage or prod" >&2
  exit 1
fi

# Validate release date format (YYYYMMDD)
if [[ "$RELEASE_DATE" =~ ^[0-9]{8}$ ]]; then
  :  # Release date format is valid
else
  echo "❌ ERROR: Invalid release date format: $RELEASE_DATE" >&2
  echo "Expected: YYYYMMDD (e.g., 20260312)" >&2
  exit 1
fi

# Validate snapshot name format
if [[ "$SNAPSHOT" =~ ^submariner-${VERSION_MAJOR_MINOR_DASH}- ]]; then
  :  # Snapshot name format is valid
else
  echo "❌ ERROR: Snapshot name doesn't match version" >&2
  echo "Expected: submariner-${VERSION_MAJOR_MINOR_DASH}-..." >&2
  echo "Got: $SNAPSHOT" >&2
  exit 1
fi

# ============================================================================
# Production Mode: Copy from Stage
# ============================================================================

if [ "$RELEASE_TYPE" = "prod" ]; then
  # Find stage YAML to copy from
  STAGE_DIR="releases/${VERSION_MAJOR_MINOR}/stage"

  if [ ! -d "$STAGE_DIR" ]; then
    echo "❌ ERROR: Stage directory not found: $STAGE_DIR" >&2
    echo "Run stage creation first: create-component-release.sh $VERSION ... stage ..." >&2
    exit 1
  fi

  # Find latest stage YAML for this version
  STAGE_YAML=$(find "$STAGE_DIR" -name "submariner-${VERSION_DASH}-stage-*.yaml" -type f | sort | tail -1)

  if [ -z "$STAGE_YAML" ] || [ ! -f "$STAGE_YAML" ]; then
    echo "❌ ERROR: No stage YAML found for version $VERSION" >&2
    echo "Expected: $STAGE_DIR/submariner-${VERSION_DASH}-stage-*.yaml" >&2
    echo "Run stage creation first" >&2
    exit 1
  fi

  echo "Reading stage YAML: $STAGE_YAML" >&2

  # Create prod directory
  PROD_DIR="releases/${VERSION_MAJOR_MINOR}/prod"
  mkdir -p "$PROD_DIR" || {
    echo "❌ ERROR: Failed to create directory: $PROD_DIR" >&2
    exit 1
  }

  # Determine sequence number for prod
  SEQUENCE=1
  while [ -f "${PROD_DIR}/submariner-${VERSION_DASH}-prod-${RELEASE_DATE}-$(printf '%02d' $SEQUENCE).yaml" ]; do
    ((SEQUENCE++))
  done

  PROD_FILENAME="submariner-${VERSION_DASH}-prod-${RELEASE_DATE}-$(printf '%02d' $SEQUENCE).yaml"
  PROD_FILE="${PROD_DIR}/${PROD_FILENAME}"

  # Copy stage YAML and modify
  # Change metadata.name: stage → prod, update date
  # Change spec.releasePlan: stage-0-X → prod-0-X
  # Keep spec.snapshot and spec.data.releaseNotes identical

  sed -e "s/name: submariner-${VERSION_DASH}-stage-[0-9]\{8\}-[0-9]\{2\}/name: submariner-${VERSION_DASH}-prod-${RELEASE_DATE}-$(printf '%02d' $SEQUENCE)/" \
      -e "s/releasePlan: submariner-release-plan-stage-${VERSION_MAJOR_MINOR_DASH}/releasePlan: submariner-release-plan-prod-${VERSION_MAJOR_MINOR_DASH}/" \
      "$STAGE_YAML" > "$PROD_FILE"

  if [ ! -f "$PROD_FILE" ]; then
    echo "❌ ERROR: Failed to create prod YAML: $PROD_FILE" >&2
    exit 1
  fi

  # Verify file has expected content
  if ! grep -q "snapshot: ${SNAPSHOT}" "$PROD_FILE"; then
    echo "❌ ERROR: Prod YAML missing expected snapshot: $SNAPSHOT" >&2
    echo "Check that stage YAML uses the same snapshot" >&2
    exit 1
  fi

  if ! grep -q "releasePlan: submariner-release-plan-prod-${VERSION_MAJOR_MINOR_DASH}" "$PROD_FILE"; then
    echo "❌ ERROR: Prod YAML has incorrect releasePlan" >&2
    exit 1
  fi

  echo "✓ Created prod YAML: $PROD_FILE" >&2
  echo "$PROD_FILE"
  exit 0
fi

# ============================================================================
# Stage Mode: Generate YAML
# ============================================================================

# Create stage directory
STAGE_DIR="releases/${VERSION_MAJOR_MINOR}/stage"
mkdir -p "$STAGE_DIR" || {
  echo "❌ ERROR: Failed to create directory: $STAGE_DIR" >&2
  exit 1
}

# Determine sequence number (support retries)
SEQUENCE=1
while [ -f "${STAGE_DIR}/submariner-${VERSION_DASH}-stage-${RELEASE_DATE}-$(printf '%02d' $SEQUENCE).yaml" ]; do
  ((SEQUENCE++))
done

# Generate filename
STAGE_FILENAME="submariner-${VERSION_DASH}-stage-${RELEASE_DATE}-$(printf '%02d' $SEQUENCE).yaml"
STAGE_FILE="${STAGE_DIR}/${STAGE_FILENAME}"

# Generate YAML with release notes placeholder (user fills via Step 9 workflow)
cat > "$STAGE_FILE" <<EOF
---
apiVersion: appstudio.redhat.com/v1alpha1
kind: Release
metadata:
  name: submariner-${VERSION_DASH}-stage-${RELEASE_DATE}-$(printf '%02d' $SEQUENCE)
  namespace: submariner-tenant
  labels:
    release.appstudio.openshift.io/author: 'dfarrell07'
spec:
  releasePlan: submariner-release-plan-stage-${VERSION_MAJOR_MINOR_DASH}
  snapshot: ${SNAPSHOT}
  data:
    releaseNotes:
      type: RHBA  # Change to RHSA if adding CVEs, RHEA for enhancements
      issues:
        fixed: []  # Fill with Step 9 workflow
      cves: []     # Fill with Step 9 workflow (required if type=RHSA)
EOF

# Verify file was created
if [ ! -f "$STAGE_FILE" ]; then
  echo "❌ ERROR: Failed to create YAML file: $STAGE_FILE" >&2
  exit 1
fi

# Verify file has expected content
if ! grep -q "snapshot: ${SNAPSHOT}" "$STAGE_FILE"; then
  echo "❌ ERROR: YAML file missing expected content" >&2
  exit 1
fi

# Output the file path to stdout
echo "$STAGE_FILE"
