#!/bin/bash
# Validate bundle CSV image SHAs match snapshot component SHAs

set -euo pipefail

validate_file() {
  local file=$1
  echo "Validating bundle images in $file..."

  namespace=$(yq -e '.metadata.namespace' "$file")
  snapshot=$(yq -e '.spec.snapshot' "$file")

  # Get snapshot from cluster
  snapshot_json=$(oc get snapshot "$snapshot" -n "$namespace" -o json)

  # Find operator bundle component (exclude FBC)
  bundle_image=$(echo "$snapshot_json" | jq -r '.spec.components[] | select(.name | (contains("bundle") and (contains("fbc") | not))) | .containerImage' | head -1)

  if [[ -z "$bundle_image" ]]; then
    echo "WARNING: No operator bundle component found in snapshot"
    return
  fi

  echo "  Bundle: $bundle_image"

  # Create temp directory
  tmpdir=$(mktemp -d)
  trap "rm -rf $tmpdir" EXIT

  # Extract all snapshot component SHAs (excluding bundles)
  echo "$snapshot_json" | jq -r '.spec.components[] | select(.name | contains("bundle") | not) | .containerImage' | \
    grep -oP 'sha256:[a-f0-9]+' | sort -u > "$tmpdir/snapshot_shas.txt"

  snapshot_sha_count=$(wc -l < "$tmpdir/snapshot_shas.txt")
  echo "  Snapshot has $snapshot_sha_count component SHAs"

  # Extract bundle manifests
  mkdir -p "$tmpdir/manifests"
  if ! oc image extract "$bundle_image" --path=/manifests/:$tmpdir/manifests/ 2>/dev/null; then
    echo "ERROR: Failed to extract bundle image"
    exit 1
  fi

  # Find CSV file
  csv_file=$(find "$tmpdir/manifests" -type f -name '*.clusterserviceversion.yaml' | head -1)
  if [[ -z "$csv_file" ]]; then
    echo "ERROR: No ClusterServiceVersion found in bundle"
    exit 1
  fi

  echo "  CSV: $(basename "$csv_file")"

  # Extract all image SHAs from CSV
  yq -r '
    [.spec.relatedImages[]?.image,
     .spec.install.spec.deployments[]?.spec.template.spec.containers[]?.image,
     .spec.install.spec.deployments[]?.spec.template.spec.initContainers[]?.image
    ] | .[] | select(. != null)' "$csv_file" 2>/dev/null | \
    grep -oP 'sha256:[a-f0-9]+' | sort -u > "$tmpdir/csv_shas.txt"

  csv_sha_count=$(wc -l < "$tmpdir/csv_shas.txt")

  if [[ $csv_sha_count -eq 0 ]]; then
    echo "WARNING: No image SHAs found in CSV"
    return
  fi

  echo "  CSV has $csv_sha_count image SHAs"

  # Check for SHAs in CSV that are not in snapshot
  missing=$(comm -23 "$tmpdir/csv_shas.txt" "$tmpdir/snapshot_shas.txt")

  if [[ -n "$missing" ]]; then
    echo "ERROR: CSV references SHAs not found in snapshot:"
    while IFS= read -r sha; do
      # Find which CSV image has this SHA
      img=$(yq -r '
        [.spec.relatedImages[]?.image,
         .spec.install.spec.deployments[]?.spec.template.spec.containers[]?.image,
         .spec.install.spec.deployments[]?.spec.template.spec.initContainers[]?.image
        ] | .[] | select(. != null)' "$csv_file" 2>/dev/null | grep "$sha" | head -1)
      echo "    $sha"
      [[ -n "$img" ]] && echo "      from: $img"
    done <<< "$missing"
    exit 1
  fi

  echo "✓ All $csv_sha_count bundle image SHAs exist in snapshot"
}

# Main
find releases -name '*.yaml' -type f -print0 | \
  while IFS= read -r -d '' file; do
    validate_file "$file"
  done

echo ""
echo "All bundle image validations passed"
