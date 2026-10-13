# Share FBC with QE

Provide verified catalog URLs for the requested Submariner version and environment.

## Share stage FBC with QE

### Select the release scope and exact artifacts

Use the applicable active OCP versions established by
[stage preparation](create-fbc-stage-release.md). Do not assume a fixed count:
a retained catalog directory is not an active release target, and an active
catalog can omit this Submariner version.

`./scripts/get-fbc-urls.sh <version> --raw-url` is a corroborating lookup, not
a substitute for the reviewed Release identities. Older checkouts can select a
different matching Release or fall back to a snapshot; raw output hides that
fallback. Hardened lookup requires successful stage completion, exact snapshot
images and completed tests, plus the intended bundle in every applicable catalog.
Default non-raw output also updates the QE Jira subtask when a tracker exists;
use it only when that external update is authorized.

For each target, select the reviewed stage YAML for this version and successful
attempt explicitly. Read the fragment from that exact successful Release:

```bash
set -euo pipefail
OCP_ID=4-19
FILE=releases/fbc/4-19/stage/submariner-fbc-4-19-0-23-4-stage-YYYYMMDD-02.yaml
NAME=$(yq -r '.metadata.name' "$FILE")
PLAN=$(yq -r '.spec.releasePlan' "$FILE")
SNAPSHOT=$(yq -r '.spec.snapshot' "$FILE")
RELEASE=$(oc get release "$NAME" -n submariner-tenant -o json)
printf '%s' "$RELEASE" | jq -e --arg plan "$PLAN" --arg snapshot "$SNAPSHOT" --arg ocp "$OCP_ID" '
  .spec.releasePlan == $plan and
  $plan == ("submariner-fbc-release-plan-stage-" + $ocp) and
  .spec.snapshot == $snapshot and
  ([.status.conditions[]? | select(.type == "Released")] |
    length == 1 and .[0].status == "True" and .[0].reason == "Succeeded") and
  (.status.artifacts.components | length == 1) and
  .status.artifacts.components[0].ocp_version == ("v" + ($ocp | gsub("-"; "."))) and
  .status.artifacts.components[0].target_index == "" and
  .status.artifacts.components[0].target_index_with_timestamp == ""'
CATALOG=$(printf '%s' "$RELEASE" | jq -er '.status.artifacts.components[0].fbc_fragment')
SNAPSHOT_IMAGE=$(oc get snapshot "$SNAPSHOT" -n submariner-tenant \
  -o jsonpath='{.spec.components[0].containerImage}')
[ "$CATALOG" = "$SNAPSHOT_IMAGE" ]
printf 'OCP %s: %s\n' "${OCP_ID//-/.}" "$CATALOG"
```

Run in Bash; replace the example with the exact reviewed
file and OCP ID. Verify the ReleasePlan/admission is stage-only, with no
production target index. A pending or failed Release is not ready even if its
snapshot image is accessible. If a live object is missing, use retained completed
Release evidence for the same name, plan, snapshot and artifact; YAML plus a
Snapshot alone cannot establish successful publication. Do not infer success or
a particular deletion cause from `NotFound`.

### Verify the catalog and stage mirrors

Extract each released fragment and check the intended bundle version/digest,
channel and component pins against the approved component-stage snapshot and
pinned FBC source. Check the immutable manifest digest and supported platforms.
Do not select a newer component snapshot implicitly.

Catalogs can contain logical `registry.redhat.io` bundle/operand URLs before those
images are published there. Use the approved FBC `images-mirror-set.yaml` for the
candidate's Y-stream and verify that every required Quay mirror digest matches
the approved stage evidence and is accessible. Inspect the physical staged bundle
CSV to confirm its version and operand references. Local `skopeo inspect` does
not use the cluster's ImageDigestMirrorSet.

A missing production manifest at stage does not prove the approved staged image
is missing. Production publication is a separate gate. A full internal IIB index
reported by the Release and the Quay fragment are distinct artifacts: identify
which was independently inspected and which QE should use.

### Prepare the QE handoff

Provide:

- One `OCP: catalog@sha256:...` line per verified target, with its exact Release
  and snapshot identity; explicitly list any remaining pending targets.
- Package, intended channel, starting CSV and approved bundle digest. Select the
  release's channel explicitly; the catalog default can be a newer stream.
- The approved ImageDigestMirrorSet and the required Quay pull access.
- Verification results and remaining installation/compatibility testing.

For example, Submariner 0.23.4 uses package `submariner`, channel `stable-0.23`
and starting CSV `submariner.v0.23.4`; a catalog default of `stable-0.24` tests a
different release. A green integration scenario that skipped installation does
not qualify the intended bundle. QE should confirm CatalogSource readiness, the
intended CSV reaches `Succeeded`, and operand pulls resolve through the approved
stage mirrors before testing.

Share through the QE Jira subtask or agreed channel when authorized. A verified
target can be handed off while others are pending; report that scope accurately.
Stage handoff is complete when QE receives the artifacts and starts testing.
Wait for QE approval before proceeding to component or FBC production releases.

## Share production FBC with QE

Check every applicable target's exact production Release using
[release verification](check-fbc-releases.md). Require `Released=True/Succeeded`
and the QE-approved stage snapshot; a count of matching rows is insufficient.

```bash
./scripts/get-fbc-urls.sh 0.X.Y --prod-index --raw-url
```

This helper checks production bundle availability and prints public operator
index URLs. Independently verify each intended production index contains the
approved bundle digest; helper output alone does not prove inclusion in every
index. Production bundle and operand pullspecs must resolve without stage mirrors.
Report the exact tested/released scope to QE. Follow the existing release tracker
closeout procedure only after the production release and QE handoff are complete.
