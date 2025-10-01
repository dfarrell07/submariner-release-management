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

  # Check snapshot test status
  test_status=$(oc get snapshot "$snapshot" -n "$namespace" -o jsonpath='{.metadata.annotations.test\.appstudio\.openshift\.io/status}' 2>/dev/null || echo "")
  if [[ -n "$test_status" ]]; then
    if echo "$test_status" | jq -e '.[] | select(.status != "TestPassed")' &>/dev/null; then
      echo "WARNING: Snapshot '$snapshot' has tests that did not pass"
    fi
  fi

  # Verify releasePlan application matches snapshot application
  rp_app=$(oc get releaseplan "$releaseplan" -n "$namespace" -o jsonpath='{.spec.application}')
  snap_app=$(oc get snapshot "$snapshot" -n "$namespace" -o jsonpath='{.metadata.labels.appstudio\.openshift\.io/application}')
  if [[ "$rp_app" != "$snap_app" ]]; then
    echo "ERROR: ReleasePlan application '$rp_app' does not match snapshot application '$snap_app'"
    exit 1
  fi

  # Verify target namespace exists
  target=$(oc get releaseplan "$releaseplan" -n "$namespace" -o jsonpath='{.spec.target}')
  if ! oc get namespace "$target" &>/dev/null; then
    echo "ERROR: Target namespace '$target' does not exist"
    exit 1
  fi

  # Verify ReleasePlanAdmission exists in target namespace
  rpa_name=$(oc get releaseplan "$releaseplan" -n "$namespace" -o jsonpath='{.metadata.labels.release\.appstudio\.openshift\.io/releasePlanAdmission}')
  if [[ -n "$rpa_name" ]]; then
    if ! oc get releaseplanadmission "$rpa_name" -n "$target" &>/dev/null; then
      echo "ERROR: ReleasePlanAdmission '$rpa_name' not found in namespace '$target'"
      exit 1
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
echo "All release references validated successfully"
