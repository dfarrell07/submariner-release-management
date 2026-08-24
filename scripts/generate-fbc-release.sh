#!/bin/bash
# Generate single FBC Release YAML
#
# Usage: generate-fbc-release.sh <ocp-version> <version> <snapshot-name> <release-type> <release-date>
#
# Arguments:
#   ocp-version:    OCP version (e.g., 4-18)
#   version:        Submariner version (e.g., 0.22.2)
#   snapshot-name:  Snapshot name (e.g., submariner-fbc-4-18-abc123)
#   release-type:   stage or prod
#   release-date:   Release date in YYYYMMDD format
#
# Output: Path to created YAML file (stdout)
# Exit codes:
#   0: Success
#   1: Failure (invalid arguments, directory creation failed, write failed)

set -euo pipefail

# Validate arguments
if [ $# -ne 5 ]; then
  echo "❌ ERROR: Invalid number of arguments" >&2
  echo "Usage: $0 <ocp-version> <version> <snapshot-name> <release-type> <release-date>" >&2
  echo "Example: $0 4-18 0.22.2 submariner-fbc-4-18-abc123 stage 20260303" >&2
  exit 1
fi

OCP_VERSION="$1"
VERSION="$2"
SNAPSHOT="$3"
RELEASE_TYPE="$4"
RELEASE_DATE="$5"
VERSION_DASH="${VERSION//./-}"

# Validate OCP version format. Regex is deliberately permissive (4-14 through
# 4-29) so add-fbc-ocp-version can introduce new OCP versions without editing
# this generator; the actively-shipped set is 4-16 through 4-22.
if [[ "$OCP_VERSION" =~ ^4-(1[4-9]|2[0-9])$ ]]; then
  :  # OCP version is valid
else
  echo "❌ ERROR: Invalid OCP version: $OCP_VERSION" >&2
  echo "Expected: 4-14 through 4-29" >&2
  exit 1
fi

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
  echo "Expected: YYYYMMDD (e.g., 20260303)" >&2
  exit 1
fi

# Validate snapshot name format
if [[ "$SNAPSHOT" =~ ^submariner-fbc-${OCP_VERSION}- ]]; then
  :  # Snapshot name format is valid
else
  echo "❌ ERROR: Snapshot name doesn't match OCP version" >&2
  echo "Expected: submariner-fbc-${OCP_VERSION}-..." >&2
  echo "Got: $SNAPSHOT" >&2
  exit 1
fi

# Create directory if needed
OUTPUT_DIR="releases/fbc/${OCP_VERSION}/${RELEASE_TYPE}"
mkdir -p "$OUTPUT_DIR" || {
  echo "❌ ERROR: Failed to create directory: $OUTPUT_DIR" >&2
  exit 1
}

# Determine sequence number (check for existing files)
SEQUENCE=1
while [ -f "${OUTPUT_DIR}/submariner-fbc-${OCP_VERSION}-${VERSION_DASH}-${RELEASE_TYPE}-${RELEASE_DATE}-$(printf '%02d' $SEQUENCE).yaml" ]; do
  ((SEQUENCE++))
done

# Generate filename
FILENAME="submariner-fbc-${OCP_VERSION}-${VERSION_DASH}-${RELEASE_TYPE}-${RELEASE_DATE}-$(printf '%02d' $SEQUENCE).yaml"
OUTPUT_FILE="${OUTPUT_DIR}/${FILENAME}"

# Generate YAML content
cat > "$OUTPUT_FILE" <<EOF
---
apiVersion: appstudio.redhat.com/v1alpha1
kind: Release
metadata:
  name: submariner-fbc-${OCP_VERSION}-${VERSION_DASH}-${RELEASE_TYPE}-${RELEASE_DATE}-$(printf '%02d' $SEQUENCE)
  namespace: submariner-tenant
  labels:
    release.appstudio.openshift.io/author: 'dfarrell07'
spec:
  releasePlan: submariner-fbc-release-plan-${RELEASE_TYPE}-${OCP_VERSION}
  snapshot: ${SNAPSHOT}
EOF

# Verify file was created
if [ ! -f "$OUTPUT_FILE" ]; then
  echo "❌ ERROR: Failed to create YAML file: $OUTPUT_FILE" >&2
  exit 1
fi

# Verify file has expected content
if ! grep -q "snapshot: ${SNAPSHOT}" "$OUTPUT_FILE"; then
  echo "❌ ERROR: YAML file missing expected content" >&2
  exit 1
fi

# Output the file path to stdout
echo "$OUTPUT_FILE"
