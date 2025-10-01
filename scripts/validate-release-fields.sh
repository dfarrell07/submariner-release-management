#!/bin/bash
# Validate Release CR required fields and structure

set -euo pipefail

validate_file() {
  local file=$1
  echo "Validating fields in $file..."

  # Required: apiVersion and kind
  yq -e '.apiVersion == "appstudio.redhat.com/v1alpha1"' "$file" >/dev/null
  yq -e '.kind == "Release"' "$file" >/dev/null

  # Required: metadata fields
  yq -e '.metadata.name | type == "!!str" and length > 0' "$file" >/dev/null
  yq -e '.metadata.namespace == "submariner-tenant"' "$file" >/dev/null
  yq -e '.metadata.labels."release.appstudio.openshift.io/author" | type == "!!str" and length > 0' "$file" >/dev/null

  # Required: spec fields
  yq -e '.spec.releasePlan | type == "!!str" and length > 0' "$file" >/dev/null
  yq -e '.spec.snapshot | type == "!!str" and length > 0' "$file" >/dev/null

  # Required: releaseNotes.type must be RHSA, RHBA, or RHEA
  type=$(yq -e '.spec.data.releaseNotes.type' "$file")
  if [[ ! "$type" =~ ^(RHSA|RHBA|RHEA)$ ]]; then
    echo "ERROR: Invalid type '$type' (must be RHSA, RHBA, or RHEA)"
    exit 1
  fi

  # If CVEs exist, validate structure
  if yq -e '.spec.data.releaseNotes.cves' "$file" &>/dev/null; then
    yq -e '.spec.data.releaseNotes.cves | type == "!!seq"' "$file" >/dev/null
    yq -e '.spec.data.releaseNotes.cves[] | has("key")' "$file" >/dev/null
    yq -e '.spec.data.releaseNotes.cves[] | has("component")' "$file" >/dev/null
  fi

  # If issues exist, validate structure
  if yq -e '.spec.data.releaseNotes.issues.fixed' "$file" &>/dev/null; then
    yq -e '.spec.data.releaseNotes.issues.fixed | type == "!!seq"' "$file" >/dev/null
    yq -e '.spec.data.releaseNotes.issues.fixed[] | has("id")' "$file" >/dev/null
    yq -e '.spec.data.releaseNotes.issues.fixed[] | has("source")' "$file" >/dev/null
  fi

  echo "✓ $file"
}

# Main
find releases -name '*.yaml' -type f -print0 | \
  while IFS= read -r -d '' file; do
    validate_file "$file"
  done

echo ""
echo "All release files validated successfully"
