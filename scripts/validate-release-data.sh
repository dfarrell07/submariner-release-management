#!/usr/bin/env bash
# Validate Release CR data formats

set -euo pipefail

validate_file() {
  local file=$1
  echo "Validating data formats in $file..."

  # Check if this is an FBC release (which omit releaseNotes, inherited from ReleasePlan)
  # FBC releasePlans contain "fbc" in the name (e.g., submariner-fbc-release-plan-stage-4-16)
  release_plan=$(yq '.spec.releasePlan' "$file")
  if [[ "$release_plan" =~ fbc ]]; then
    echo "  ✓ FBC release (releaseNotes inherited from ReleasePlan, skipping data validation)"
    echo "✓ $file"
    return 0
  fi

  # Get advisory type
  advisory_type=$(yq '.spec.data.releaseNotes.type' "$file")
  if [[ -z "$advisory_type" || "$advisory_type" == "null" ]]; then
    echo "ERROR: releaseNotes.type is missing"
    exit 1
  fi

  # If CVEs exist, validate format
  if yq -e '.spec.data.releaseNotes.cves | length > 0' "$file" &>/dev/null; then
    cve_count=$(yq '.spec.data.releaseNotes.cves | length' "$file")

    for i in $(seq 0 $((cve_count - 1))); do
      cve=$(yq ".spec.data.releaseNotes.cves[$i].key" "$file")
      if [[ -z "$cve" || "$cve" == "null" ]]; then
        echo "ERROR: CVE at index $i is missing 'key' field"
        exit 1
      fi

      component=$(yq ".spec.data.releaseNotes.cves[$i].component" "$file")
      if [[ -z "$component" || "$component" == "null" ]]; then
        echo "ERROR: CVE at index $i is missing 'component' field"
        exit 1
      fi

      # Validate CVE format: CVE-YYYY-NNNNN
      if [[ "$cve" =~ ^CVE-[0-9]{4}-[0-9]{4,}$ ]]; then
        :  # CVE format is valid
      else
        echo "ERROR: Invalid CVE format '$cve' (expected CVE-YYYY-NNNNN)"
        exit 1
      fi

      # Validate component has version suffix: -X-Y
      if [[ "$component" =~ -[0-9]+-[0-9]+$ ]]; then
        :  # Component version suffix is valid
      else
        echo "ERROR: Component '$component' missing version suffix (expected -X-Y)"
        exit 1
      fi

      # Extract version suffix for display
      version_suffix=$(echo "$component" | grep -oP -- '-[0-9]+-[0-9]+$')
      echo "  ✓ $cve ($component with suffix $version_suffix)"
    done
  fi

  # RHSA must have at least one CVE
  if [[ "$advisory_type" == "RHSA" ]]; then
    if ! yq -e '.spec.data.releaseNotes.cves | length > 0' "$file" &>/dev/null; then
      echo "ERROR: RHSA advisory must have at least one CVE"
      exit 1
    fi
    echo "  ✓ RHSA has required CVE(s)"
  fi

  # If issues exist, validate format
  if yq -e '.spec.data.releaseNotes.issues.fixed | length > 0' "$file" &>/dev/null; then
    issue_count=$(yq '.spec.data.releaseNotes.issues.fixed | length' "$file")

    for i in $(seq 0 $((issue_count - 1))); do
      id=$(yq ".spec.data.releaseNotes.issues.fixed[$i].id" "$file")
      if [[ -z "$id" || "$id" == "null" ]]; then
        echo "ERROR: Issue at index $i is missing 'id' field"
        exit 1
      fi

      source=$(yq ".spec.data.releaseNotes.issues.fixed[$i].source" "$file")
      if [[ -z "$source" || "$source" == "null" ]]; then
        echo "ERROR: Issue at index $i is missing 'source' field"
        exit 1
      fi

      if [[ "$source" == "issues.redhat.com" ]]; then
        # Jira format: PROJECT-NNNNN
        if [[ "$id" =~ ^[A-Z]+-[0-9]+$ ]]; then
          :  # Jira ID format is valid
        else
          echo "ERROR: Invalid Jira ID '$id' (expected PROJECT-NNNNN)"
          exit 1
        fi
        echo "  ✓ $id (Jira format valid)"
      elif [[ "$source" == "bugzilla.redhat.com" ]]; then
        # Bugzilla format: numeric only
        if [[ "$id" =~ ^[0-9]+$ ]]; then
          :  # Bugzilla ID format is valid
        else
          echo "ERROR: Invalid Bugzilla ID '$id' (expected numeric)"
          exit 1
        fi
        echo "  ✓ $id (Bugzilla format valid)"
      else
        echo "ERROR: Unknown issue source '$source' (expected issues.redhat.com or bugzilla.redhat.com)"
        exit 1
      fi
    done
  fi

  echo "✓ $file"
}

# Main - support both single-file and all-files modes
if [[ $# -gt 0 && -n "$1" ]]; then
  # Single file mode - validate the provided file
  file="$1"
  if [[ ! -f "$file" ]]; then
    echo "ERROR: File '$file' not found"
    exit 1
  fi
  validate_file "$file"
  echo ""
  echo "File validation passed"
else
  # All files mode - find and validate all release YAMLs
  find releases -name '*.yaml' -type f -print0 | \
    while IFS= read -r -d '' file; do
      validate_file "$file"
    done
  echo ""
  echo "All data formats validated successfully"
fi
