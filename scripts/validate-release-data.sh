#!/bin/bash
# Validate Release CR data formats

set -euo pipefail

validate_file() {
  local file=$1
  echo "Validating data formats in $file..."

  # Get advisory type
  type=$(yq -e '.spec.data.releaseNotes.type' "$file")

  # If CVEs exist, validate format
  if yq -e '.spec.data.releaseNotes.cves | length > 0' "$file" &>/dev/null; then
    # Validate CVE format: CVE-YYYY-NNNNN
    cves=$(yq -e '.spec.data.releaseNotes.cves[].key' "$file")
    for cve in $cves; do
      if ! [[ "$cve" =~ ^CVE-[0-9]{4}-[0-9]{4,}$ ]]; then
        echo "ERROR: Invalid CVE format '$cve' (expected CVE-YYYY-NNNNN)"
        exit 1
      fi
    done

    # Validate components have version suffix: -X-Y
    components=$(yq -e '.spec.data.releaseNotes.cves[].component' "$file")
    for comp in $components; do
      if ! [[ "$comp" =~ -[0-9]+-[0-9]+$ ]]; then
        echo "ERROR: Component '$comp' missing version suffix (expected -X-Y)"
        exit 1
      fi
    done
  fi

  # RHSA must have at least one CVE
  if [[ "$type" == "RHSA" ]]; then
    if ! yq -e '.spec.data.releaseNotes.cves | length > 0' "$file" &>/dev/null; then
      echo "ERROR: RHSA advisory must have at least one CVE"
      exit 1
    fi
  fi

  # If issues exist, validate format
  if yq -e '.spec.data.releaseNotes.issues.fixed | length > 0' "$file" &>/dev/null; then
    count=$(yq -e '.spec.data.releaseNotes.issues.fixed | length' "$file")
    for i in $(seq 0 $((count - 1))); do
      id=$(yq -e ".spec.data.releaseNotes.issues.fixed[$i].id" "$file")
      source=$(yq -e ".spec.data.releaseNotes.issues.fixed[$i].source" "$file")

      if [[ "$source" == "issues.redhat.com" ]]; then
        # Jira format: PROJECT-NNNNN
        if ! [[ "$id" =~ ^[A-Z]+-[0-9]+$ ]]; then
          echo "ERROR: Invalid Jira ID '$id' (expected PROJECT-NNNNN)"
          exit 1
        fi
      elif [[ "$source" == "bugzilla.redhat.com" ]]; then
        # Bugzilla format: numeric only
        if ! [[ "$id" =~ ^[0-9]+$ ]]; then
          echo "ERROR: Invalid Bugzilla ID '$id' (expected numeric)"
          exit 1
        fi
      else
        echo "ERROR: Unknown issue source '$source' (expected issues.redhat.com or bugzilla.redhat.com)"
        exit 1
      fi
    done
  fi

  echo "✓ $file"
}

# Main
find releases -name '*.yaml' -type f -print0 | \
  while IFS= read -r -d '' file; do
    validate_file "$file"
  done

echo ""
echo "All data formats validated successfully"
