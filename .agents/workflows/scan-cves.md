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

Fix Go toolchain CVEs by updating the builder in each used addon Dockerfile (`Dockerfile.konflux` for
Konflux and ordinary `Dockerfile` for OpenShift CI). Confirm the selected branch and Dockerfile in the
actual Component/PaC, CI and applicable ART source/`from`/`streams.yml` configuration. ART may override
the source Dockerfile's builder and runtime; branch copies and appstudio branches may not be active sources.

**Repo:** <https://github.com/stolostron/submariner-addon>
**Local:** `~/go/src/stolostron/submariner-addon`

```bash
skopeo list-tags docker://registry.redhat.io/openshift/golang-builder
```

Use the floating `golang-builder-v<Go-minor>-rhel<major>` family documented in
[ACM-45149](https://redhat.atlassian.net/browse/ACM-45149). The repository requires internal registry
entitlement; verify pulls through the actual OpenShift image-build and Konflux remote-build credential
paths. Local registry access does not establish CI access; change credentials only for a demonstrated gap.

Select the Go minor/patch against every module actually compiled and the required security fixes.
Preserve the required compiler lineage, OS/CPU baseline, runtime base and crypto contract for each build path,
using resolved metadata and build evidence. Preserve existing CGO/strict-FIPS flags and
PQC runtime choices where present. Keep prefetch and offline build behavior aligned with the build;
the ART image's `GOFLAGS=-mod=vendor` does not override an explicit `-mod=mod` build flag.

Record source SHA, resolved builder/runtime digests, pipeline/task revisions, effective compiler/
`GOTOOLCHAIN` and the built binary's
`go version -m` data, inspecting the extracted binary with tooling outside the runtime image.
[Go can select/download another toolchain](https://go.dev/doc/toolchain), so
image labels and module floors alone do not establish the artifact compiler or crypto implementation.
Use the ordinary **images** check as well as relevant source tests for pre-merge validation. After normal
review/merge, verify the actual consumer's push-build source and required platform results against the
published output index and child digests. A successful x86_64 PR build does not qualify a four-platform
push image. Run startup/deployment checks against those output digests; a `--version` smoke check covers
executable loading, while streams requiring FIPS also need their deployment/crypto checks in a FIPS-enabled
environment. Keep qualification gaps explicit when that environment is unavailable. Retain receipts with
the addon change and its CVE or migration tracker; hold release use until required qualification passes.

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
