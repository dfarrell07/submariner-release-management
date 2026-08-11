# Share FBC with QE

Provide FBC catalog/index URLs to QE for testing in stage and production environments.

**Repo:** `~/konflux/submariner-release-management`

## Share Stage FBC with QE

**When:** After FBC stage releases applied and verified (Step 13b complete)

### Extract Stage Catalog URLs

Use the automation — it extracts stage catalog URLs for every supported OCP
version from the Release CRs (falling back to local YAMLs + snapshot lookup if
the CRs are garbage-collected), and populates the QE subtask description:

```bash
/get-fbc-urls 0.X.Y            # full output for all OCP versions
/get-fbc-urls 0.X.Y --raw-url  # URLs only (one per line)
```

**Manual fallback** (equivalent to the default mode, minus the GC fallback):

```bash
echo "=== FBC Stage Catalog URLs for QE ==="
for VERSION in 16 17 18 19 20 21 22; do
  STAGE_YAML=$(ls releases/fbc/4-$VERSION/stage/*.yaml | tail -1)
  SNAPSHOT=$(awk '/^  snapshot:/ {print $2}' "$STAGE_YAML")
  CATALOG=$(oc get snapshot "$SNAPSHOT" -n submariner-tenant \
    -o jsonpath='{.spec.components[0].containerImage}')
  echo "OCP 4.$VERSION: $CATALOG"
done
```

Example output (7 catalog URLs):

```text
OCP 4.16: quay.io/redhat-user-workloads/submariner-tenant/submariner-fbc-4-16@sha256:...
OCP 4.17: quay.io/redhat-user-workloads/submariner-tenant/submariner-fbc-4-17@sha256:...
OCP 4.18: quay.io/redhat-user-workloads/submariner-tenant/submariner-fbc-4-18@sha256:...
OCP 4.19: quay.io/redhat-user-workloads/submariner-tenant/submariner-fbc-4-19@sha256:...
OCP 4.20: quay.io/redhat-user-workloads/submariner-tenant/submariner-fbc-4-20@sha256:...
OCP 4.21: quay.io/redhat-user-workloads/submariner-tenant/submariner-fbc-4-21@sha256:...
OCP 4.22: quay.io/redhat-user-workloads/submariner-tenant/submariner-fbc-4-22@sha256:...
```

### Verify Stage Catalog Content

Verify one catalog contains the expected bundle version:

```bash
# Pick one catalog to verify (e.g., 4-21)
CATALOG="quay.io/redhat-user-workloads/submariner-tenant/submariner-fbc-4-21@sha256:..."

# Extract and list bundles
TMPDIR=$(mktemp -d)
oc image extract "$CATALOG" --path /configs/submariner/bundles/:$TMPDIR/ --confirm
ls $TMPDIR/bundle-v*.yaml
# Should show: bundle-v0.21.0.yaml, bundle-v0.21.2.yaml (or current version)

# Verify bundle accessible
BUNDLE_IMAGE=$(grep "^image:" "$TMPDIR/bundle-v0.21.2.yaml" | head -1 | awk '{print $2}')
skopeo inspect "docker://$BUNDLE_IMAGE"
# Should succeed (bundle mirrored to registry.redhat.io)

rm -rf $TMPDIR
```

### Share Stage with QE

**Communication method:** Jira ticket in ACM QE project

Create ticket with:

- **Summary:** "Submariner 0.X.Y FBC Stage Ready for Testing"
- **Description:** Include all 7 catalog URLs
- **Installation:** Point to FBC installation docs (CatalogSource creation)

**Key concept:** Catalog contains operator bundle with registry.redhat.io URLs. ImageDigestMirrors in
cluster redirect to quay.io for actual image pulls.

### Stage Done When

- QE ticket created with catalog URLs
- QE confirms receipt and begins testing
- Waiting for QE approval to proceed to prod releases

**Next:** Wait for QE approval, then proceed to Step 15 (Component Prod Release) and Step 17 (FBC Prod Releases)

## Share Prod FBC with QE

**When:** When all 7 FBC prod releases show Succeeded status

### Check Release Status

Verify all 7 FBC prod releases completed:

```bash
oc get releases -n submariner-tenant --no-headers | \
  grep "submariner-fbc-4-.*-prod.*Succeeded" | wc -l
# Should show: 7
```

If not all completed, wait for remaining releases to finish.

### Generate QE Message

Use the automation — `--prod-index` confirms the bundle is live in the Red Hat
operator index (via skopeo) and prints the per-OCP `registry.redhat.io` index URLs:

```bash
/get-fbc-urls 0.X.Y --prod-index            # full output
/get-fbc-urls 0.X.Y --prod-index --raw-url  # URLs only
```

**Manual fallback** — extract index URLs from the prod Release CRs and format for QE:

```bash
echo "Submariner 0.X.Y Prod FBC Released"
echo ""
for VERSION in 16 17 18 19 20 21 22; do
  RELEASE=$(oc get releases -n submariner-tenant --no-headers | \
    grep "submariner-fbc-4-$VERSION-prod.*Succeeded" | tail -1 | awk '{print $1}')

  if [ -n "$RELEASE" ]; then
    INDEX=$(oc get release "$RELEASE" -n submariner-tenant -o yaml | \
      grep "index_image_resolved:" | head -1 | awk '{print $2}')
    PUBLIC_INDEX=$(echo "$INDEX" | \
      sed 's|registry-proxy.engineering.redhat.com/rh-osbs/iib-pub|registry.redhat.io/redhat/redhat-operator-index|')
    echo "OCP 4.$VERSION: $PUBLIC_INDEX"
  fi
done
```

Replace `0.X.Y` with actual version. Copy the output and share with QE.

### Verify Index Images (Optional)

**TODO:** Implement verification that all 7 index images contain the expected Submariner 0.X.Y bundle SHA.

**What to verify:**

- Extract bundle SHA from prod release YAML files
- Check each of 7 index images contains that bundle SHA
- Verify bundle version matches expected release (0.X.Y)

**Why optional:** QE testing will catch issues if bundle missing/wrong. This verification adds confidence but isn't blocking.

### Share with QE

**Communication:** Jira ticket OR Slack notification with the message generated above.

**Note:** QE typically uses OperatorHub (automatic), but may want URLs for verification or custom CatalogSource testing.

### Prod Done When

- All 7 FBC prod releases succeeded
- QE message shared with index URLs
- **Submariner 0.X.Y production release COMPLETE**

Once the release has shipped, close out its Jira tracker (resolves the parent
and any still-open subtasks):

```bash
/autorelease 0.X.Y --close
```
