# Submariner FBC rollout to OCP 5.0

Reviewed October 26, 2026. Tracking: [ACM-48200][delivery]. Release management
owns the automated installation test; QE follows the normal stage handoff.
Use the [onboarding workflow][onboarding] for mechanics. Keep one candidate
record linked from ACM-48200: bundle/channel, source SHA, push build, snapshot,
image, lifecycle reference, test results, release identities and QE approval.

The initial candidate is Submariner **0.24.1**, channel **stable-0.24**, for
OCP **5.0**. [FBC PR #81][catalog] merged the catalog and tooling;
[FBC PR #82][pipelines] merged the four-platform build (`amd64`, `arm64`,
`ppc64le`, `s390x`) using the OCP 5 RHEL9 registry base and lifecycle injection.
Confirm the intended bundle digest against the approved component release
before qualification. Product compatibility and lifecycle-support changes
remain separate.

Status as of October 26, 2026. Tenant resources and admissions have reconciled.
FBC PR #82 merged as `13b7416`; its push build produced snapshot
`submariner-fbc-5-0-20261026-144157-000` and image digest
`sha256:6bd0ce2161ac…` (the [PR build][pr-build] for head `897c64a` had already passed on all four platforms).
The [cluster-profile PR][profile] and [helper PR #120][helper] are still open.

The optional operator scenario now creates its PipelineRun: the tenant fix
removing `CHANNEL_NAME` (release-data !24109) is deployed, and the first push
run completed `get-unreleased-bundle` (channel `stable-0.24`, the 0.24.1 bundle) and
`pick-cluster-params` (OCP 5.0, amd64). `provision-cluster` then failed
validation: `konflux cluster "kflux-prd-rh02" and tenant "submariner-tenant"
don't own the cluster profile "aws-konflux-prod"`
(`EphemeralClusterValidationFailure`). The task kept polling the
`InitializationFailed` phase for its full 2-hour timeout and exited 255, so the
scenario ended `TestFail`. That is a profile-ownership failure, resolved only by
the cluster-profile PR; it is not installation evidence and says nothing yet
about the OCP release. The `stable-5.0` update graph still has no nodes
(`candidate-5.0` has releases, for example `5.0.0-rc.7`). Refresh these
observations when executing the plan.

## 1. Reconcile tenant resources and admissions

[Release-data !23786][tenant] merged both tenant resources and admissions.
Live account ownership, credential bindings and stage/prod admission matching
are verified. Keep autorelease disabled.

The tenant follow-up removing the entire `CHANNEL_NAME` parameter from the 5.0
operator scenario (release-data !24109) has merged and reconciled, and the
first push run confirmed it: the scenario now creates its PipelineRun instead
of failing admission. Reviewed integration-service source converts an empty ITS
value to JSON `null`; server controls reproduced the same admission error for
null. Omission uses the upstream pipeline's empty-string default and preserves
catalog-default selection. Removing only the value is insufficient. Keep this
shape in any regenerated manifest.

For any new build, recheck the 5.0 Application, Component, ImageRepository,
build-account ownership and image-push secret bindings. Check the registry
credential binding on `konflux-integration-runner` and confirm authenticated
pulls in the eventual test. ServiceAccount existence alone is insufficient.
Reconcile any bot-generated pipeline PR with #82 rather than merging two
competing pipeline definitions.

Release qualification needs the recorded candidate push build below. Both
stage/prod ReleasePlans must remain matched before live verification and
release.

Progress #120 review, cluster-profile access and OCP 5 release availability in
parallel. Build readiness and installation have separate gates.

## 2. Build and identify the candidate

Before merging the candidate source, record whether all intended bundle and
operand digests can be pulled from production or need approved 0.24 stage
mirrors. Verify mappings and pull access if mirrors are needed. The install
pipeline reads `.tekton/images-mirror-set.yaml` at that SHA; the current file
targets 0.23 only. The first push run was given that 0.23 mirror set, but it
failed before any bundle or operand pull, so pull behavior is unobserved. Both
5.0 catalog bundles are `registry.redhat.io` digests and the mirrors use
`AllowContactingSource`; record the actual pull behavior of the installing run
rather than assuming it. Any change to `images-mirror-set.yaml` triggers new
builds of every FBC pipeline, including 5-0, and so replaces the candidate.

Build PipelineRuns are short-lived. The push run for `13b7416`
(`submariner-fbc-5-0-on-push-lcghf`) and its operator-test run were already gone
from the cluster a few hours after they finished, before any of this evidence
could be captured. The snapshot, its recorded image digest and the lifecycle
artifact tag `13b7416f64ac909538ac5ec818ffcad7491f17ae.lifecycle` remain in
quay, but the helper needs the build's live resolved spec, and retained
check/image evidence alone cannot satisfy it. Treat `13b7416` as unverifiable
unless a reviewed Tekton Results (or equivalent) path recovers its run.

Several task pins are marked with an `expires_on` date in Conforma's legacy
trusted-task list (checked October 26): in the merged 5.0 pipelines `init` on
2026-11-16, and `git-clone-oci-ta`, `build-image-index` (an 11-18 record also
exists) and `fbc-inject-lifecycle-oci-ta` on 2026-11-22; until fbc #86 merges, the
4.x pipelines have earlier dates, from 2026-10-30. These dates do not block release under today's
policy: the `fbc-standard` and `fbc-stage` policies load `policy-data`, which has
`trusted_task_rules_enabled: true`, and when rules data is present the policy
checks task versions against allow and deny rules and does not consult the expiry
list. If `trusted_task_rules_enabled` were false or the rules empty, the policy would
fall back to the expiry list, which is the one way these dates start to matter. The
policy references float (`:konflux`, `:latest`), so re-read that flag and the deny
rules before each release, and treat a refresh as a hedge: take the current
non-expiring digests from Conforma's trusted-task data
(`quay.io/konflux-ci/tekton-catalog/data-acceptable-bundles`), not from this plan,
in a standalone FBC change. Merging it starts a 5.0 push build, so time it with the
qualifying build below, or accept that an earlier build is only a placeholder. What
policy does require of every build today is the `fbc-inject-lifecycle-oci-ta`
task; snapshots built without it, such as the PaC push snapshots from `main` before
fbc #86 merges, need a rebuild before a production release. (The 0.23.4 stage
replacement builds of October 12 already include it.)

The candidate is the push build recorded in the candidate record: `13b7416`
only if it is recovered as above, otherwise the first replacement build that
meets these conditions. A replacement is qualifying only if its PipelineRun,
TaskRuns and lifecycle artifact stay retrievable until `verify-live`. Capture
them, with logs and the lifecycle artifact digest, immediately after it
completes. Start that qualifying build only when every install prerequisite is
met (cluster-profile access merged and either `stable-5.0` has nodes or a
reviewed candidate-channel test approved; before that its operator test fails the
same way), capture the run at once, and do the scenario rerun and `verify-live`
the same day, or first establish a Tekton Results path. A rebuild needs a new
commit to `main` that touches the 5.0 build files. It creates a new source SHA,
snapshot, image and lifecycle artifact, so it replaces the candidate record
(source SHA, snapshot, image, lifecycle digest and `FBC_EXPECTED_COMMIT`) and must
pass every gate again.

FBC PR #82 has merged and its gating checks passed at the merged head.
Verify all four platforms, effective build arguments, OCP base annotations,
catalog validation and lifecycle-task execution using the onboarding workflow.
Retain resolved task/image identities and the policy used by the build.

Obtain `lifecycle.json` from the candidate push build's digest-pinned lifecycle
`SOURCE_ARTIFACT`. Check TaskRun ownership, successful injection `TEST_OUTPUT`
and resolved task/image pins; review the lifecycle contents and retain the
artifact digest and file SHA256. Do not extract the reference from the catalog
image under test. Reference provenance and support policy are manual review
inputs, not claims established by the content verifier.

Merge #120 with the reviewed fixes for omitted default-channel parameters,
required operator-test labels and exact source/reference content verification
before using `verify-live`. Use its merged helper and updated workflow with
`--expected-lifecycle` pointing to the reviewed candidate push reference.

## 3. Qualify installation and catalog contents

Actual provisioning requires [cluster-profile access][profile] and an available
requested OCP release, checked in that order because the profile check fails
first: without access the claim is rejected within a second
(`don't own the cluster profile "aws-konflux-prod"`) yet the task polls for its
full 2-hour timeout before exiting 255. Provisioning runs only on push events;
the PR-event `TestPassed` skips every install task, so it proves nothing here.
The reviewed upstream pipeline requests `stable`;
recheck `stable-5.0` (its graph had no nodes on October 26) rather than
assuming GA makes it available. If earlier
testing is needed, separately review a temporary candidate-channel pipeline
and tenant resolver revision, selecting an approved exact prerelease with a
removal plan. Verify the observed cluster version matches that selection.
Tenant `CHANNEL_NAME` selects the OLM channel, not the OCP release channel.

Require successful intended-bundle selection, provisioning and deployment.
For the upstream path, inspect `get-unreleased-bundle`, `pick-cluster-params`,
`provision-cluster` and `deploy-operator`. Record the bundle digest/channel,
installed CSV and the cluster's observed **5.0.x** version from test artifacts.
PR-event skips, empty-result push no-ops and fallback 4.x clusters do not
satisfy this gate. The install task also pushes its workspace (gathered cluster
resources, CSV and InstallPlan dumps) to `<OCI_REF>:<source-sha>-<taskrun-uid>` in
the FBC component's quay repository, which outlives the pruned run; pull it after
a run that reaches that step and look for the cluster version. Its contents are
not yet verified for 5.0.
If no eligible unreleased bundle remains, use a separately reviewed explicit
bundle/channel test; rerunning the unchanged selection is insufficient.

Prepare a separate tenant follow-up, including regenerated manifests, making
the live 5.0 operator scenario required (`optional: "false"`) before final
verification; review and reconcile it when the installation path is usable.
Making it required does not by itself add assurance: a push run that selects no
unreleased bundle also ends `TestPassed` without installing, so the evidence above
is still what proves installation.
Reuse a completed `TestPassed` run only if its candidate and test
definition are unchanged and the installation evidence above is present.
Otherwise, after existing tests finish, rerun the scenario on the recorded
push snapshot (not a new build, and never a PR-event snapshot, which skips
installation) using [Konflux instructions][rerun]; confirm its snapshot/scenario identities and
successful completion. Retain resolved wrapper/pipeline/StepAction revisions
and image digests; their Git resolver chain follows `main`.

Then run the merged helper's live verification for the recorded source SHA and
reviewed lifecycle reference. Require its reported snapshot/image and that
snapshot's linked build PipelineRun to match the candidate record. Stop on
mismatch. A replacement must pass the build and installation gates with its
own lifecycle and test evidence. Require matched admissions, account bindings,
completed successful tests and exact source/reference content on all four
platforms, alongside the actual installation evidence above.

## 4. Stage the pinned candidate and hand it to QE

Follow [stage creation][stage], scoped to `0.24.1` and `--ocp 5.0`. Pin both
`FBC_EXPECTED_COMMIT` and `FBC_EXPECTED_SNAPSHOTS` to the recorded candidate:
the commit is the 40-character SHA, and the snapshots are a JSON map keyed by the
hyphenated OCP ID, for example
`FBC_EXPECTED_SNAPSHOTS='{"5-0":"submariner-fbc-5-0-<timestamp>"}'`. Production
creation does not read either pin.
Inspect the generated Release's exact name, plan and snapshot; use that file
for [application][apply] and [completion checks][check], not an mtime lookup.

Require the exact stage Release to finish `Released=True/Succeeded` with no
policy violations and no production-index publication. Follow the
[QE handoff][qe] for the released fragment and intended bundle/channel, using
the verified mirrors if needed. Compare any URL-helper result with that exact
Release, snapshot and fragment; a latest-successful lookup can select another
candidate. Record these identities and artifact digests in the QE handoff, and
wait for approval of those artifacts before production.

## 5. Publish the approved snapshot and activate scope

Follow [production creation][prod], still scoped to `0.24.1` and OCP 5.0.
Confirm production bundle availability and required Pyxis FBC opt-in; this
repository has no procedure for the opt-in, so name its owner and the way to
confirm it before the production Release. The helper
selects the latest version-matched stage YAML; it does not establish QE approval.
Check that its selected stage record and the generated production Release's
snapshot are exactly the recorded QE-approved candidate before application.
If they differ, stop and reconcile rather than releasing the newer candidate.

Verify the exact production Release succeeds, then inspect the actual v5.0
index for the approved bundle digest and intended channel. A printed URL or
version-named catalog file alone is insufficient. Confirm production bundle
and operand pulls resolve without stage mirrors. Only then add `5-0` to
`scripts/lib/fbc-scope.sh` through review and complete the normal QE/tracker
closeout. Retain release, snapshot/IIB and lifecycle evidence for
[OPGM-364][lifecycle]; check its criteria before closure. Compatibility changes
under [OPGM-261][compatibility] remain separate work.

## Failure and rollback

If a stage Release fails policy or QE rejects the artifacts, do not edit the
candidate record in place: fix the cause, build again, and restart sections 2 to 4
with a new record. A failed or mistaken production Release does not by itself
change `scripts/lib/fbc-scope.sh`; leave `5-0` out of it until the v5.0 index is
verified, and treat a published bad bundle as a new release problem (a replacement
bundle) rather than something this plan reverses. If OCP 5.0 GA slips, nothing here
expires: hold at the last completed gate and rerun the checks in the order above
when the install path becomes usable.

[delivery]: https://redhat.atlassian.net/browse/ACM-48200
[catalog]: https://github.com/stolostron/submariner-operator-fbc/pull/81
[pipelines]: https://github.com/stolostron/submariner-operator-fbc/pull/82
[pr-build]: https://konflux-ui.apps.kflux-prd-rh02.0fk9.p1.openshiftapps.com/ns/submariner-tenant/pipelinerun/submariner-fbc-5-0-on-pull-request-npbx4
[profile]: https://github.com/openshift/release/pull/87176
[helper]: https://github.com/stolostron/submariner-release-management/pull/120
[tenant]: https://gitlab.cee.redhat.com/releng/konflux-release-data/-/merge_requests/23786
[rerun]: https://konflux-ci.dev/docs/testing/integration/rerunning/
[lifecycle]: https://redhat.atlassian.net/browse/OPGM-364
[compatibility]: https://redhat.atlassian.net/browse/OPGM-261
[onboarding]: ../.agents/workflows/add-fbc-ocp-version.md
[stage]: ../.agents/workflows/create-fbc-stage-release.md
[apply]: ../.agents/workflows/apply-fbc-releases.md
[check]: ../.agents/workflows/check-fbc-releases.md
[qe]: ../.agents/workflows/share-with-qe.md
[prod]: ../.agents/workflows/create-fbc-prod-release.md
