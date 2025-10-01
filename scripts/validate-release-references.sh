#!/bin/bash
# Validate Release CR references exist in cluster

set -euo pipefail

validate_file() {
  local file=$1
  echo "Validating references in $file..."

  # Extract values
  namespace=$(yq '.metadata.namespace' "$file")
  if [[ -z "$namespace" || "$namespace" == "null" ]]; then
    echo "ERROR: metadata.namespace is missing"
    exit 1
  fi

  snapshot=$(yq '.spec.snapshot' "$file")
  if [[ -z "$snapshot" || "$snapshot" == "null" ]]; then
    echo "ERROR: spec.snapshot is missing"
    exit 1
  fi

  releaseplan=$(yq '.spec.releasePlan' "$file")
  if [[ -z "$releaseplan" || "$releaseplan" == "null" ]]; then
    echo "ERROR: spec.releasePlan is missing"
    exit 1
  fi

  # Verify snapshot exists
  if ! oc get snapshot "$snapshot" -n "$namespace" &>/dev/null; then
    echo "ERROR: Snapshot '$snapshot' not found in namespace '$namespace'"
    exit 1
  fi
  echo "  ✓ Snapshot found: $snapshot"

  # Check snapshot test status
  test_status=$(oc get snapshot "$snapshot" -n "$namespace" -o jsonpath='{.metadata.annotations.test\.appstudio\.openshift\.io/status}' 2>/dev/null || echo "")
  if [[ -n "$test_status" ]]; then
    failed_count=$(echo "$test_status" | jq '[.[] | select(.status != "TestPassed")] | length' 2>/dev/null || echo "0")
    if [[ "$failed_count" -gt 0 ]]; then
      echo "  ⚠ Snapshot has $failed_count failed test(s)"
    else
      test_count=$(echo "$test_status" | jq '. | length' 2>/dev/null)
      echo "  ✓ Snapshot tests: $test_count passed"
    fi
  fi

  # Verify releasePlan exists
  if ! oc get releaseplan "$releaseplan" -n "$namespace" &>/dev/null; then
    echo "ERROR: ReleasePlan '$releaseplan' not found in namespace '$namespace'"
    exit 1
  fi
  echo "  ✓ ReleasePlan found: $releaseplan"

  # Verify releasePlan application matches snapshot application
  rp_app=$(oc get releaseplan "$releaseplan" -n "$namespace" -o jsonpath='{.spec.application}' 2>/dev/null)
  if [[ -z "$rp_app" ]]; then
    echo "ERROR: ReleasePlan '$releaseplan' missing spec.application field"
    exit 1
  fi

  snap_app=$(oc get snapshot "$snapshot" -n "$namespace" -o jsonpath='{.metadata.labels.appstudio\.openshift\.io/application}' 2>/dev/null)
  if [[ -z "$snap_app" ]]; then
    echo "ERROR: Snapshot '$snapshot' missing application label"
    exit 1
  fi

  if [[ "$rp_app" != "$snap_app" ]]; then
    echo "ERROR: ReleasePlan application '$rp_app' does not match snapshot application '$snap_app'"
    exit 1
  fi
  echo "  ✓ Application match: $rp_app"

  # Verify target namespace exists
  target=$(oc get releaseplan "$releaseplan" -n "$namespace" -o jsonpath='{.spec.target}' 2>/dev/null)
  if [[ -z "$target" ]]; then
    echo "ERROR: ReleasePlan '$releaseplan' missing spec.target field"
    exit 1
  fi

  if ! oc get namespace "$target" &>/dev/null; then
    echo "ERROR: Target namespace '$target' does not exist"
    exit 1
  fi
  echo "  ✓ Target namespace exists: $target"

  # Verify ReleasePlanAdmission exists in target namespace
  rpa_name=$(oc get releaseplan "$releaseplan" -n "$namespace" -o jsonpath='{.metadata.labels.release\.appstudio\.openshift\.io/releasePlanAdmission}' 2>/dev/null)
  if [[ -n "$rpa_name" ]]; then
    if ! oc get releaseplanadmission "$rpa_name" -n "$target" &>/dev/null; then
      echo "ERROR: ReleasePlanAdmission '$rpa_name' not found in namespace '$target'"
      exit 1
    fi
    echo "  ✓ ReleasePlanAdmission found: $rpa_name"
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
