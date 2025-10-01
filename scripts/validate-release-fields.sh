#!/bin/bash
# Validate Release CR required fields and structure

set -euo pipefail

validate_file() {
  local file=$1
  echo "Validating fields in $file..."

  # Required: apiVersion and kind
  api_version=$(yq '.apiVersion' "$file")
  if [[ -z "$api_version" || "$api_version" == "null" ]]; then
    echo "ERROR: apiVersion is missing"
    exit 1
  fi
  if [[ "$api_version" != "appstudio.redhat.com/v1alpha1" ]]; then
    echo "ERROR: Invalid apiVersion '$api_version'"
    exit 1
  fi
  echo "  ✓ apiVersion: $api_version"

  kind=$(yq '.kind' "$file")
  if [[ -z "$kind" || "$kind" == "null" ]]; then
    echo "ERROR: kind is missing"
    exit 1
  fi
  if [[ "$kind" != "Release" ]]; then
    echo "ERROR: Invalid kind '$kind'"
    exit 1
  fi
  echo "  ✓ kind: $kind"

  # Required: metadata fields
  name=$(yq '.metadata.name' "$file")
  if [[ -z "$name" || "$name" == "null" ]]; then
    echo "ERROR: metadata.name is missing"
    exit 1
  fi
  echo "  ✓ metadata.name: $name"

  namespace=$(yq '.metadata.namespace' "$file")
  if [[ -z "$namespace" || "$namespace" == "null" ]]; then
    echo "ERROR: metadata.namespace is missing"
    exit 1
  fi
  if [[ "$namespace" != "submariner-tenant" ]]; then
    echo "ERROR: Invalid namespace '$namespace' (must be submariner-tenant)"
    exit 1
  fi
  echo "  ✓ metadata.namespace: $namespace"

  author=$(yq '.metadata.labels."release.appstudio.openshift.io/author"' "$file")
  if [[ -z "$author" || "$author" == "null" ]]; then
    echo "ERROR: author label is missing"
    exit 1
  fi
  echo "  ✓ metadata.labels.author: $author"

  # Required: spec fields
  snapshot=$(yq '.spec.snapshot' "$file")
  if [[ -z "$snapshot" || "$snapshot" == "null" ]]; then
    echo "ERROR: spec.snapshot is missing"
    exit 1
  fi
  echo "  ✓ spec.snapshot: $snapshot"

  release_plan=$(yq '.spec.releasePlan' "$file")
  if [[ -z "$release_plan" || "$release_plan" == "null" ]]; then
    echo "ERROR: spec.releasePlan is missing"
    exit 1
  fi
  echo "  ✓ spec.releasePlan: $release_plan"

  # Required: releaseNotes.type must be RHSA, RHBA, or RHEA
  advisory_type=$(yq '.spec.data.releaseNotes.type' "$file")
  if [[ -z "$advisory_type" || "$advisory_type" == "null" ]]; then
    echo "ERROR: releaseNotes.type is missing"
    exit 1
  fi
  if [[ ! "$advisory_type" =~ ^(RHSA|RHBA|RHEA)$ ]]; then
    echo "ERROR: Invalid type '$advisory_type' (must be RHSA, RHBA, or RHEA)"
    exit 1
  fi
  echo "  ✓ releaseNotes.type: $advisory_type"

  # If CVEs exist, validate structure
  if yq -e '.spec.data.releaseNotes.cves' "$file" &>/dev/null; then
    cve_type=$(yq '.spec.data.releaseNotes.cves | type' "$file")
    if [[ "$cve_type" != "!!seq" ]]; then
      echo "ERROR: CVEs must be an array, got $cve_type"
      exit 1
    fi

    cve_count=$(yq '.spec.data.releaseNotes.cves | length' "$file")
    for i in $(seq 0 $((cve_count - 1))); do
      has_key=$(yq ".spec.data.releaseNotes.cves[$i] | has(\"key\")" "$file")
      if [[ "$has_key" != "true" ]]; then
        echo "ERROR: CVE at index $i missing 'key' field"
        exit 1
      fi
      has_component=$(yq ".spec.data.releaseNotes.cves[$i] | has(\"component\")" "$file")
      if [[ "$has_component" != "true" ]]; then
        echo "ERROR: CVE at index $i missing 'component' field"
        exit 1
      fi
    done
    if [[ $cve_count -eq 0 ]]; then
      echo "  ✓ CVEs: empty array (valid)"
    else
      echo "  ✓ CVEs: $cve_count found with required fields"
    fi
  fi

  # If issues exist, validate structure
  if yq -e '.spec.data.releaseNotes.issues.fixed' "$file" &>/dev/null; then
    issue_type=$(yq '.spec.data.releaseNotes.issues.fixed | type' "$file")
    if [[ "$issue_type" != "!!seq" ]]; then
      echo "ERROR: Issues must be an array, got $issue_type"
      exit 1
    fi

    issue_count=$(yq '.spec.data.releaseNotes.issues.fixed | length' "$file")
    for i in $(seq 0 $((issue_count - 1))); do
      has_id=$(yq ".spec.data.releaseNotes.issues.fixed[$i] | has(\"id\")" "$file")
      if [[ "$has_id" != "true" ]]; then
        echo "ERROR: Issue at index $i missing 'id' field"
        exit 1
      fi
      has_source=$(yq ".spec.data.releaseNotes.issues.fixed[$i] | has(\"source\")" "$file")
      if [[ "$has_source" != "true" ]]; then
        echo "ERROR: Issue at index $i missing 'source' field"
        exit 1
      fi
    done
    if [[ $issue_count -eq 0 ]]; then
      echo "  ✓ Issues: empty array (valid)"
    else
      echo "  ✓ Issues: $issue_count found with required fields"
    fi
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
