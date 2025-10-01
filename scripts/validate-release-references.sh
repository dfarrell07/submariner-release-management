#!/bin/bash
# Validate Release CR references exist in cluster

set -euo pipefail

validate_file() {
  local file=$1
  echo "Validating references in $file..."

  # Extract values
  namespace=$(yq -e '.metadata.namespace' "$file")
  snapshot=$(yq -e '.spec.snapshot' "$file")
  releaseplan=$(yq -e '.spec.releasePlan' "$file")

  # Verify snapshot exists
  if ! oc get snapshot "$snapshot" -n "$namespace" &>/dev/null; then
    echo "ERROR: Snapshot '$snapshot' not found in namespace '$namespace'"
    exit 1
  fi

  # Verify releasePlan exists
  if ! oc get releaseplan "$releaseplan" -n "$namespace" &>/dev/null; then
    echo "ERROR: ReleasePlan '$releaseplan' not found in namespace '$namespace'"
    exit 1
  fi

  echo "✓ $file"
}

# Main
find releases -name '*.yaml' -type f -print0 | \
  while IFS= read -r -d '' file; do
    validate_file "$file"
  done

echo ""
echo "All release references validated successfully"
