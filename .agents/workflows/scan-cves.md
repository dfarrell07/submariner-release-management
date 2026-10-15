# Scan for CVEs

**When:** Y-stream (0.20 → 0.21) and Z-stream (0.20.1 → 0.20.2), before cutting release

> **Reuse completed upstream source work if `v$VERSION` exists on all five component repos** (retarget, re-release,
retry). CVE fixes must land before the tag; after it
> exists, source changes require a new version. Verify scan evidence for the exact downstream candidate separately. See
`skip-completed-steps.md`.

## Process

Fix CVEs in upstream source (Go mods and RPM lockfiles). Verify fixes by scanning downstream images.

**Repos:** <https://github.com/submariner-io>
With components (9 total): submariner-operator (2), submariner (3), lighthouse (2), shipyard (1), subctl (1)
Libraries only: admiral, cloud-prepare

**Local:** `~/go/src/submariner-io/`

### Go Dependencies

Run CVE workflow (from each repo's CLAUDE.md on devel) on release-0.X branch for all 7 repos (including libraries) to
fix Go dependency CVEs.

### RPM Dependencies

Update RPM lockfiles to fix RPM package CVEs:

```bash
/rpm-lockfile-update <branch>
```

This updates lockfiles in submariner (3 components) and shipyard (1 component) repos.

### Addon Go Toolchain

**Repo:** <https://github.com/stolostron/submariner-addon>
**Local:** `~/go/src/stolostron/submariner-addon`

Identify the affected build paths: Konflux uses `Dockerfile.konflux`, OpenShift CI uses ordinary
`Dockerfile`, and ART may override source, builder and runtime through its image/stream configuration.
Confirm the selected source before editing.

```bash
skopeo list-tags docker://registry.redhat.io/openshift/golang-builder
```

Use the floating `golang-builder-v<Go-minor>-rhel<major>` family documented in
[ACM-45149](https://redhat.atlassian.net/browse/ACM-45149). Select a compiler satisfying the compiled
modules and required security fixes while preserving the build path's compiler lineage, OS/CPU and
crypto requirements. Preserve runtime bases, CGO/strict-FIPS settings and hermetic prefetch/build flags.
Explicit `-mod=mod` overrides the builder's `GOFLAGS=-mod=vendor` default.

Verify internal registry entitlement in the actual OpenShift build or Konflux remote worker. Run the ordinary **images**
check for changed ordinary Dockerfiles and the required Konflux checks for changed Konflux paths;
source/unit tests alone do not exercise those image builds. Use normal review/merge gates and verify
merged-source push results for the required platforms against the output index's child digests.

Keep source SHA, resolved builder/runtime digests, pipeline/task revisions and effective compiler evidence
with the change. [Go can select another toolchain](https://go.dev/doc/toolchain); inspect `GOTOOLCHAIN`
and the extracted binary's `go version -m` output. Apply existing runtime/FIPS checks to changed paths:
`--version` checks executable loading. Run required deployment/crypto checks against the output digests,
using a FIPS-enabled environment where required. Record unavailable checks and hold release use until
required qualification passes. Keep receipts with the relevant CVE or migration tracker.

## Done When

All components/repos scanned. CVE report presented (sorted by severity). User triages and approves.

### Upstream Source (grype)

Grype scans show no CVEs for all 7 repos (including libraries) on release-0.X branch.

### Downstream Images (clair)

Scan all 9 components (replace 0-X with version, e.g., 0-21):

- submariner-operator-0-X
- submariner-gateway-0-X
- submariner-globalnet-0-X
- submariner-route-agent-0-X
- lighthouse-agent-0-X
- lighthouse-coredns-0-X
- nettest-0-X
- subctl-0-X
- submariner-bundle-0-X (no Clair results expected)

**Note:** submariner-addon is in a separate snapshot - scan separately if needed.

Requires: `oc login --web https://api.kflux-prd-rh02.0fk9.p1.openshiftapps.com:6443/`

```bash
# Get recent snapshot and pick a component to check
# Replace 0-X with actual version (e.g., 0-21 for 0.21.x releases)
SNAPSHOT=$(oc get snapshots -n submariner-tenant --sort-by=.metadata.creationTimestamp | grep "^submariner-0-X" | tail -1 | awk '{print $1}')
IMAGE=$(oc get snapshot $SNAPSHOT -n submariner-tenant -o jsonpath='{.spec.components[?(@.name=="lighthouse-agent-0-X")].containerImage}')

# Get architecture-specific digest (Clair reports attach to arch digests, not multi-arch manifest)
ARCH_DIGEST=$(skopeo inspect --raw docker://$IMAGE | jq -r '.manifests[] | select(.platform.architecture=="amd64") | .digest')
IMAGE_REPO=$(echo $IMAGE | cut -d@ -f1)

# Pull and analyze Clair report
CLAIR_DIGEST=$(oras discover "${IMAGE_REPO}@${ARCH_DIGEST}" --artifact-type "application/vnd.redhat.clair-report+json" -o json | jq -r '.manifests[0].digest')
oras pull "${IMAGE_REPO}@${CLAIR_DIGEST}"

# CVE details (sorted by severity for triage)
jq '.vulnerabilities | to_entries[] | .value |
  {cve: .name, severity: .normalized_severity, pkg: .package_name, desc: .description}' clair-report-*.json |
  jq -s 'sort_by(.severity) | reverse[]'
```
