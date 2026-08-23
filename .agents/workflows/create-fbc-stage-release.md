# Create FBC Stage Releases

**When:** After FBC catalog updated (Step 11) and FBC snapshots rebuilt

> **Automated:** `/autorelease` handles this step automatically. Follow the manual
> steps below only if debugging or running without the conductor.

**Prerequisites:**

- Step 10: Component stage release completed (bundle now in registry.redhat.io)
- Step 11: FBC catalog updated with bundle SHA from registry.redhat.io
- FBC snapshots rebuilt (automatic after catalog update, takes ~15-30 min)

## Process

Create Release CRs for each OCP version using FBC snapshots built after Step 11.

**Repo:** `~/konflux/submariner-release-management`

**Output:** `releases/fbc/4-XX/stage/`

**Note:** FBC releases omit `spec.data.releaseNotes` (inherited from ReleasePlan).

**Placeholders to replace:**

- `0.X` = Y-stream version with dot (e.g., `0.21` for all 0.21.x releases)
- `0.X.Y` = Full version with dots (e.g., `0.21.2`)
- `0-X` = Y-stream version with dash (e.g., `0-21` for component names)
- `0-X-Y` = Full version with dashes (e.g., `0-21-2` for YAML names)

## Creating Release YAMLs

Find recent passing FBC snapshots (built automatically after Step 11):

```bash
# Verify FBC snapshots (built after catalog update) are ready for release
echo "=== FBC Snapshot Verification ==="

# First verify all 7 GitHub catalogs have the same bundle SHA (catalog consistency)
echo "Verifying GitHub catalog consistency..."
BUNDLE_SHAS=$(for VERSION in 16 17 18 19 20 21 22; do
  curl -sf "https://raw.githubusercontent.com/stolostron/submariner-operator-fbc/main/catalog-4-$VERSION/bundles/bundle-v0.X.Y.yaml" | grep "^image:" | head -1 | grep -oP 'sha256:\K[a-f0-9]+'
done | sort -u)
SHA_COUNT=$(echo "$BUNDLE_SHAS" | grep -c . || echo 0)
[ "$SHA_COUNT" != "1" ] && { echo "✗ ERROR: FBC catalogs have $SHA_COUNT unique bundle SHAs (expected 1 across all 7 OCP versions)"; exit 1; }
EXPECTED_BUNDLE_SHA="$BUNDLE_SHAS"
echo "✓ Bundle SHA consistent across all 7 GitHub catalogs: ${EXPECTED_BUNDLE_SHA:0:12}"

# Verify snapshot for each OCP version (4-16 through 4-22)
FAILED=0
for VERSION in 16 17 18 19 20 21 22; do
  SNAPSHOT=$(oc get snapshots -n submariner-tenant --sort-by=.metadata.creationTimestamp | grep "^submariner-fbc-4-$VERSION" | tail -1 | awk '{print $1}')
  [ -z "$SNAPSHOT" ] && { echo "4-$VERSION: ✗ No snapshot found"; ((FAILED++)); continue; }

  # Get FBC catalog container image from snapshot
  CATALOG_IMAGE=$(oc get snapshot $SNAPSHOT -n submariner-tenant -o jsonpath='{.spec.components[0].containerImage}')
  [ -z "$CATALOG_IMAGE" ] && { echo "4-$VERSION: ✗ No catalog image in snapshot"; ((FAILED++)); continue; }

  # Extract bundle SHA from snapshot's catalog
  SNAPSHOT_BUNDLE_SHA=$(oc image extract "$CATALOG_IMAGE" --path "/configs/submariner/bundles/bundle-v0.X.Y.yaml:-" --confirm 2>/dev/null | grep "^image:" | head -1 | grep -oP 'sha256:\K[a-f0-9]+')
  [ -z "$SNAPSHOT_BUNDLE_SHA" ] && { echo "4-$VERSION: ✗ Failed to extract bundle SHA from snapshot"; ((FAILED++)); continue; }

  # Verify snapshot has the correct bundle SHA
  if [ "$SNAPSHOT_BUNDLE_SHA" != "$EXPECTED_BUNDLE_SHA" ]; then
    echo "4-$VERSION: ✗ Bundle SHA mismatch (snapshot: ${SNAPSHOT_BUNDLE_SHA:0:12}, expected: ${EXPECTED_BUNDLE_SHA:0:12})"
    ((FAILED++)); continue
  fi

  # Verify event type (push/incoming/retest-all-comment are main-branch builds; reject PR)
  EVENT_TYPE=$(oc get snapshot $SNAPSHOT -n submariner-tenant -o jsonpath='{.metadata.labels.pac\.test\.appstudio\.openshift\.io/event-type}')
  [ "$EVENT_TYPE" != "push" ] && [ "$EVENT_TYPE" != "incoming" ] && [ "$EVENT_TYPE" != "retest-all-comment" ] && { echo "4-$VERSION: ✗ Event '$EVENT_TYPE' (not a main-branch build)"; ((FAILED++)); continue; }

  # Verify all tests passed
  TESTS=$(oc get snapshot $SNAPSHOT -n submariner-tenant -o jsonpath='{.metadata.annotations.test\.appstudio\.openshift\.io/status}')
  [ -z "$TESTS" ] && { echo "4-$VERSION: ✗ No test status"; ((FAILED++)); continue; }
  echo "$TESTS" | jq empty 2>/dev/null || { echo "4-$VERSION: ✗ Invalid test JSON"; ((FAILED++)); continue; }
  echo "$TESTS" | jq -e '.[] | select(.status != "TestPassed")' >/dev/null 2>&1 && { echo "4-$VERSION: ✗ Tests failed"; ((FAILED++)); continue; }

  echo "4-$VERSION: ✓ $SNAPSHOT (push, bundle: ${SNAPSHOT_BUNDLE_SHA:0:12})"
done

[ $FAILED -gt 0 ] && { echo "✗ $FAILED snapshot(s) failed verification"; exit 1; }
echo "✓ All 7 FBC snapshots ready for release"
```

Agent creates YAML for each OCP version (4-16 through 4-22) with passing snapshot:

```yaml
---
apiVersion: appstudio.redhat.com/v1alpha1
kind: Release
metadata:
  name: submariner-fbc-4-XX-stage-YYYYMMDD-01
  namespace: submariner-tenant
  labels:
    release.appstudio.openshift.io/author: 'dfarrell07'
spec:
  releasePlan: submariner-fbc-release-plan-stage-4-XX
  snapshot: submariner-fbc-4-XX-xxxxx  # From snapshot verification above
```

Replace `4-XX` with OCP version (4-16, 4-17, 4-18, 4-19, 4-20, 4-21, 4-22), `YYYYMMDD` with today's date,
`xxxxx` with verified snapshot name for that version (from verification output above).

Save to: `releases/fbc/4-XX/stage/submariner-fbc-4-XX-stage-YYYYMMDD-01.yaml`

## Bundle SHA Verification

**Verifies:** Component SHAs (7 components × 4 sources: operator repo, registry bundle, FBC catalogs on GitHub, FBC snapshots on
cluster). Ensures complete chain: operator repo → registry bundle → GitHub catalogs → cluster snapshots.

```bash
# 1. Fetch sources for component SHA verification
OP_CSV=$(curl -sf https://raw.githubusercontent.com/submariner-io/submariner-operator/release-0.X/bundle/manifests/submariner.clusterserviceversion.yaml)
[ -z "$OP_CSV" ] && { echo "✗ ERROR: Failed to fetch operator CSV from GitHub"; exit 1; }

# Fetch FBC bundle (using 4-21 as representative - Section 1 verified all 7 catalogs identical)
FBC_BUNDLE=$(curl -sf https://raw.githubusercontent.com/stolostron/submariner-operator-fbc/main/catalog-4-21/bundles/bundle-v0.X.Y.yaml)
[ -z "$FBC_BUNDLE" ] && { echo "✗ ERROR: Failed to fetch FBC bundle from GitHub"; exit 1; }

# Get bundle image from component snapshot (bundle not in registry.redhat.io until Step 13 prod release)
COMPONENT_RELEASE=$(ls releases/0.X/stage/*.yaml 2>/dev/null | tail -1)
[ -z "$COMPONENT_RELEASE" ] && { echo "✗ ERROR: No component stage release found in releases/0.X/stage/"; exit 1; }

COMPONENT_SNAPSHOT=$(awk '/^  snapshot:/ {print $2}' "$COMPONENT_RELEASE")
[ -z "$COMPONENT_SNAPSHOT" ] && { echo "✗ ERROR: Failed to extract snapshot from $COMPONENT_RELEASE"; exit 1; }

BUNDLE_IMAGE=$(oc get snapshot "$COMPONENT_SNAPSHOT" -n submariner-tenant -o jsonpath='{.spec.components[?(@.name=="submariner-bundle-0-X")].containerImage}')
[ -z "$BUNDLE_IMAGE" ] && { echo "✗ ERROR: Failed to get bundle image from snapshot $COMPONENT_SNAPSHOT"; exit 1; }

# Extract CSV from bundle (in Konflux workspace at quay.io/redhat-user-workloads)
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT
oc image extract "$BUNDLE_IMAGE" --path /manifests/:$TMPDIR/ --confirm 2>/dev/null >/dev/null
[ ! -f "$TMPDIR/submariner.clusterserviceversion.yaml" ] && { echo "✗ ERROR: Failed to extract CSV from bundle ($BUNDLE_IMAGE)"; exit 1; }
REG_CSV=$(cat "$TMPDIR/submariner.clusterserviceversion.yaml")

# 2. Get FBC snapshots (extract from YAMLs created in Section 1 - verify what we're releasing!)
SNAPSHOTS=()
for VERSION in 16 17 18 19 20 21 22; do
  YAML_FILE=$(ls releases/fbc/4-$VERSION/stage/*.yaml 2>/dev/null | tail -1)
  [ -z "$YAML_FILE" ] && { echo "✗ ERROR: No stage YAML found for 4-$VERSION"; exit 1; }
  SNAPSHOT=$(awk '/^  snapshot:/ {print $2}' "$YAML_FILE")
  [ -z "$SNAPSHOT" ] && { echo "✗ ERROR: No snapshot in YAML $YAML_FILE"; exit 1; }
  SNAPSHOTS+=("$SNAPSHOT")
done
[ ${#SNAPSHOTS[@]} != 7 ] && { echo "✗ ERROR: Expected 7 FBC snapshots, found ${#SNAPSHOTS[@]}"; exit 1; }

# 3. Pre-fetch bundle YAMLs from all snapshots (avoid re-fetching same YAML 7 times per snapshot)
declare -A SNAPSHOT_BUNDLES
for SNAPSHOT in "${SNAPSHOTS[@]}"; do
  CATALOG_IMAGE=$(oc get snapshot $SNAPSHOT -n submariner-tenant -o jsonpath='{.spec.components[0].containerImage}')
  SNAPSHOT_BUNDLES[$SNAPSHOT]=$(oc image extract "$CATALOG_IMAGE" --path "/configs/submariner/bundles/bundle-v0.X.Y.yaml:-" --confirm 2>/dev/null)
  [ -z "${SNAPSHOT_BUNDLES[$SNAPSHOT]}" ] && { echo "✗ ERROR: Failed to extract bundle from snapshot $SNAPSHOT"; exit 1; }
done

# 4. Verify component SHAs (7 components × 4 sources + all 7 snapshots)
echo "=== Verifying component SHAs across 4 sources (+ all 7 snapshots) ==="
MISMATCH=0
for COMP in submariner-operator submariner-gateway submariner-globalnet submariner-route-agent lighthouse-agent lighthouse-coredns nettest; do
  case $COMP in submariner-route-agent) CSV=submariner-routeagent;; lighthouse-*|nettest) CSV=submariner-$COMP;; *) CSV=$COMP;; esac

  # Extract from operator repo, registry bundle, FBC catalog (GitHub)
  OP_SHA=$(echo "$OP_CSV" | awk '/relatedImages:/,/selector:/' | grep -B1 "name: $CSV" | grep -oP 'sha256:\K[a-f0-9]+')
  REG_SHA=$(echo "$REG_CSV" | awk '/relatedImages:/,/selector:/' | grep -B1 "name: $CSV" | grep -oP 'sha256:\K[a-f0-9]+')
  FBC_SHA=$(echo "$FBC_BUNDLE" | awk '/relatedImages:/,/schema:/' | grep -B1 "name: $CSV" | grep -oP 'sha256:\K[a-f0-9]+')

  [ -z "$OP_SHA" ] || [ -z "$REG_SHA" ] || [ -z "$FBC_SHA" ] && {
    echo "$COMP: ✗ SHA extraction failed (Op:${OP_SHA:+OK} Reg:${REG_SHA:+OK} FBC-GitHub:${FBC_SHA:+OK})"
    ((MISMATCH++)); continue
  }

  # Verify all 7 FBC snapshots have same SHA as operator repo (using pre-fetched bundles)
  SNAP_MISMATCH=0
  for SNAPSHOT in "${SNAPSHOTS[@]}"; do
    SNAP_SHA=$(echo "${SNAPSHOT_BUNDLES[$SNAPSHOT]}" | awk '/relatedImages:/,/schema:/' | grep -B1 "name: $CSV" | grep -oP 'sha256:\K[a-f0-9]+')

    if [ -z "$SNAP_SHA" ]; then
      echo "$COMP: ✗ Failed to extract SHA from snapshot $SNAPSHOT"
      ((SNAP_MISMATCH++))
    elif [ "$SNAP_SHA" != "$OP_SHA" ]; then
      echo "$COMP: ✗ Snapshot $SNAPSHOT SHA mismatch (${SNAP_SHA:0:12} vs ${OP_SHA:0:12})"
      ((SNAP_MISMATCH++))
    fi
  done

  if [ $SNAP_MISMATCH -gt 0 ]; then
    ((MISMATCH++)); continue
  fi

  # Verify operator repo, registry bundle, FBC GitHub all match
  if [ "$OP_SHA" != "$REG_SHA" ] || [ "$OP_SHA" != "$FBC_SHA" ]; then
    echo "$COMP: ✗ SHA mismatch"
    echo "  Operator repo: ${OP_SHA:0:12}"
    echo "  Registry bundle: ${REG_SHA:0:12}"
    echo "  FBC GitHub: ${FBC_SHA:0:12}"
    ((MISMATCH++))
    continue
  fi

  echo "$COMP: ✓ ${OP_SHA:0:12} (verified across all 4 sources + all 7 snapshots)"
done

[ $MISMATCH -gt 0 ] && { echo "✗ $MISMATCH component(s) failed"; exit 1; }
echo "✓ All 7 components verified across 4 sources + all 7 snapshots"
```

If SHAs don't match, **STOP** - Step 8, Step 11, or snapshot builds incomplete/incorrect.

## Commit

```bash
git add releases/fbc/
git commit -s -m "Add FBC stage releases"
```

User reviews commit, then pushes.

## Done When

FBC stage YAMLs created, committed, and pushed. Ready for Step 13 to apply to cluster.

```bash
# Verify files pushed to remote (expect: 4-16 through 4-22)
git ls-tree -r --name-only origin/main releases/fbc/*/stage/*.yaml
```
