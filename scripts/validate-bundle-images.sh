#!/bin/bash
# Validate bundle CSV image SHAs match snapshot component SHAs

set -euo pipefail

validate_file() {
  local file=$1
  echo "Validating bundle images in $file..."

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

  # Get snapshot from cluster
  if ! snapshot_json=$(oc get snapshot "$snapshot" -n "$namespace" -o json 2>/dev/null); then
    echo "ERROR: Failed to get snapshot '$snapshot' from namespace '$namespace'"
    exit 1
  fi

  if [[ -z "$snapshot_json" ]]; then
    echo "ERROR: Snapshot query returned empty result"
    exit 1
  fi

  # Create temp directory
  tmpdir=$(mktemp -d)
  trap "rm -rf $tmpdir" EXIT

  # Find operator bundle component (exclude FBC)
  bundle_image=$(echo "$snapshot_json" | jq -r '.spec.components[] | select(.name | (contains("bundle") and (contains("fbc") | not))) | .containerImage' | head -1)

  if [[ -z "$bundle_image" ]]; then
    echo "WARNING: No operator bundle component found in snapshot"
    rm -rf "$tmpdir"
    return
  fi

  echo "  Bundle: $bundle_image"

  # Extract snapshot component name->SHA mapping (excluding bundles)
  echo "$snapshot_json" | jq -r '.spec.components[] | select(.name | contains("bundle") | not) | "\(.name)|\(.containerImage)"' > "$tmpdir/snapshot_components.txt"

  snapshot_count=$(wc -l < "$tmpdir/snapshot_components.txt")
  echo "  Snapshot has $snapshot_count components"

  # Extract bundle manifests
  mkdir -p "$tmpdir/manifests"
  if ! oc image extract "$bundle_image" --path=/manifests/:$tmpdir/manifests/ 2>/dev/null; then
    echo "ERROR: Failed to extract bundle image"
    rm -rf "$tmpdir"
    exit 1
  fi

  # Find CSV file
  csv_file=$(find "$tmpdir/manifests" -type f -name '*.clusterserviceversion.yaml' | head -1)
  if [[ -z "$csv_file" ]]; then
    echo "ERROR: No ClusterServiceVersion found in bundle"
    rm -rf "$tmpdir"
    exit 1
  fi

  echo "  CSV: $(basename "$csv_file")"

  # Extract all images from CSV
  {
    yq '.spec.relatedImages[].image' "$csv_file" 2>/dev/null
    yq '.spec.install.spec.deployments[].spec.template.spec.containers[].image' "$csv_file" 2>/dev/null
    yq '.spec.install.spec.deployments[].spec.template.spec.initContainers[].image' "$csv_file" 2>/dev/null
  } | grep -v '^null$' | grep -v '^$' | sort -u > "$tmpdir/csv_images.txt"

  csv_image_count=$(wc -l < "$tmpdir/csv_images.txt")

  if [[ $csv_image_count -eq 0 ]]; then
    echo "WARNING: No images found in CSV"
    rm -rf "$tmpdir"
    return
  fi

  echo "  CSV has $csv_image_count images"

  # Validate each CSV image matches a snapshot component
  errors=0
  matched=0
  skipped=0
  while IFS= read -r csv_image; do
    # Skip empty or null lines
    if [[ -z "$csv_image" || "$csv_image" == "null" ]]; then
      continue
    fi

    # Extract SHA from CSV image
    csv_sha=$(echo "$csv_image" | grep -oP 'sha256:[a-f0-9]+' || echo "")

    if [[ -z "$csv_sha" ]]; then
      echo "  ⚠ CSV image has no SHA digest: $csv_image"
      skipped=$((skipped + 1))
      continue
    fi

    # Extract component identifier from CSV image path
    # Match common patterns: lighthouse-*, submariner-*, route-agent, nettest, subctl
    csv_component=$(echo "$csv_image" | grep -oP '(lighthouse-coredns|lighthouse-agent|submariner-gateway|submariner-globalnet|submariner-route-agent|submariner-networkplugin-syncer|submariner-rhel9-operator|nettest|subctl)' | head -1)

    if [[ -z "$csv_component" ]]; then
      echo "  ⚠ Cannot identify component from CSV image: $csv_image"
      skipped=$((skipped + 1))
      continue
    fi

    # Normalize component name for matching
    # CSV: "submariner-rhel9-operator" -> snapshot: "submariner-operator-0-20"
    # CSV: "submariner-route-agent" -> snapshot: "submariner-route-agent-0-20"
    normalized_component=$(echo "$csv_component" | sed 's/-rhel9-operator/-operator/' | sed 's/-rhel9//')

    # Find matching snapshot component
    snapshot_match=$(grep -i "$normalized_component" "$tmpdir/snapshot_components.txt" | grep "$csv_sha" || echo "")

    if [[ -z "$snapshot_match" ]]; then
      echo "ERROR: CSV image SHA mismatch for component '$csv_component'"
      echo "  CSV:      $csv_image"
      echo "  Expected: Component '$csv_component' with SHA $csv_sha"

      # Show what snapshot has for this component
      component_in_snapshot=$(grep -i "$normalized_component" "$tmpdir/snapshot_components.txt" || echo "")
      if [[ -n "$component_in_snapshot" ]]; then
        snapshot_name=$(echo "$component_in_snapshot" | cut -d'|' -f1)
        snapshot_image=$(echo "$component_in_snapshot" | cut -d'|' -f2)
        snapshot_sha=$(echo "$snapshot_image" | grep -oP 'sha256:[a-f0-9]+' || echo "")
        if [[ -n "$snapshot_sha" ]]; then
          echo "  Snapshot: $snapshot_name has SHA $snapshot_sha"
        else
          echo "  Snapshot: $snapshot_name (no SHA found)"
        fi
      else
        echo "  Snapshot: No component matching '$normalized_component' found"
      fi

      errors=$((errors + 1))
    else
      # Extract snapshot component name for display
      snapshot_name=$(echo "$snapshot_match" | cut -d'|' -f1)
      short_sha=$(echo "$csv_sha" | cut -c1-15)
      echo "  ✓ $normalized_component: $short_sha matches $snapshot_name"
      matched=$((matched + 1))
    fi
  done < "$tmpdir/csv_images.txt"

  if [[ $errors -gt 0 ]]; then
    echo ""
    echo "ERROR: Found $errors image mismatches between CSV and snapshot"
    rm -rf "$tmpdir"
    exit 1
  fi

  if [[ $skipped -gt 0 ]]; then
    echo "✓ Validated $matched images ($skipped skipped)"
  else
    echo "✓ All $matched CSV images match snapshot components"
  fi
  rm -rf "$tmpdir"
}

# Main
find releases -name '*.yaml' -type f -print0 | \
  while IFS= read -r -d '' file; do
    validate_file "$file"
  done

echo ""
echo "All bundle image validations passed"
