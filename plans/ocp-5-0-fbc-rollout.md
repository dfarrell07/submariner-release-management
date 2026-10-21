# Submariner FBC rollout to OCP 5.0

Reviewed October 21, 2026. Tracking: [ACM-48200][delivery]. Release management
owns the automated installation test; QE follows the normal stage handoff.
Use the [onboarding workflow][onboarding] for mechanics. Keep one candidate
record linked from ACM-48200: bundle/channel, source SHA, push build, snapshot,
image, lifecycle reference, test results, release identities and QE approval.

The initial candidate is Submariner **0.24.1**, channel **stable-0.24**, for
OCP **5.0**. [FBC PR #81][catalog] merged the catalog and tooling;
[FBC PR #82][pipelines] proposes the four-platform build (`amd64`, `arm64`,
`ppc64le`, `s390x`) using the OCP 5 RHEL9 registry base and lifecycle injection.
Confirm the intended bundle digest against the
approved component release before qualification. Catalog packaging does not
establish product compatibility or a new lifecycle-support statement.

At review, #82, the [cluster-profile PR][profile] and [helper PR #120][helper]
remain drafts. The 5.0 Application, Component and build account are absent;
the `stable-5.0` graph has no release nodes. Refresh these observations when
executing the plan. Hosted GitLab CI and approvals still need verification.

## 1. Reconcile tenant resources and admissions

Narrow [release-data !23786][tenant] to tenant infrastructure and publish the
two RPA additions as a separate managed-config MR. Record its link here.
Require review and hosted CI at each published head. ArgoCD reconciles tenant
resources; release-data CI applies managed configuration.

Before retesting #82, verify the 5.0 Application, Component, ImageRepository,
build-account ownership and image-push secret bindings. Check the registry
credential binding on `konflux-integration-runner` and confirm authenticated
pulls in the eventual test. ServiceAccount existence alone is insufficient.
Reconcile any bot-generated pipeline PR with #82 rather than merging two
competing pipeline definitions.

Merge the separate admissions after tenant onboarding. Both stage/prod
ReleasePlans must actually match their admissions before live verification
and release; keep autorelease disabled.

## 2. Build and identify the candidate

Once infrastructure is ready, retest #82, obtain review and require successful
required checks at its exact head before merging. Identify the original
successful merged-source push PipelineRun, snapshot and immutable image.
Verify all four platforms, effective build arguments, OCP base annotations,
catalog validation and lifecycle-task execution using the onboarding workflow.
Retain resolved task/image identities and the policy used by the build.

Obtain `lifecycle.json` from the original push build's digest-pinned lifecycle
`SOURCE_ARTIFACT`. Check TaskRun ownership, successful injection `TEST_OUTPUT`
and resolved task/image pins; review the lifecycle contents and retain the
artifact digest and file SHA256. Do not extract the reference from the catalog
image under test. Reference provenance and support policy are manual review
inputs, not claims established by the content verifier.

Merge #120 with the reviewed fixes for required operator-test labels and exact
source/reference content verification before using `verify-live`. Its proposed
`--expected-lifecycle` input is not on the published head at review: publish and
review the follow-up, then use its merged helper and updated workflow.

## 3. Qualify installation and catalog contents

Actual provisioning requires [cluster-profile access][profile] and an available
requested OCP release. The reviewed upstream pipeline requests `stable`;
recheck `stable-5.0` rather than assuming GA makes it available. If earlier
testing is needed, separately review a temporary candidate-channel pipeline
and its removal plan.

Require successful intended-bundle selection, provisioning and deployment.
For the upstream path, inspect `get-unreleased-bundle`, `pick-cluster-params`,
`provision-cluster` and `deploy-operator`. Record the bundle digest/channel,
installed CSV and the cluster's observed **5.0.x** version from test artifacts.
PR-event skips, empty-result push no-ops and fallback 4.x clusters do not
satisfy this gate.
If no eligible unreleased bundle remains, use a separately reviewed explicit
bundle/channel test; rerunning the unchanged selection is insufficient.

Reconcile a reviewed tenant change, including regenerated manifests, making
the live 5.0 operator scenario required (`optional: "false"`) before final
verification. Reuse a completed `TestPassed` run only if its candidate and test
definition are unchanged
and the installation evidence above is present. Otherwise, after existing tests
finish, rerun the recorded snapshot using [Konflux instructions][rerun]; confirm
its snapshot/scenario identities and successful completion. Retain resolved
wrapper/pipeline/StepAction revisions and image digests; their Git resolver
chain follows `main`.

Then run the merged helper's live verification for the recorded source SHA and
reviewed lifecycle reference. Require its reported snapshot/image and that
snapshot's linked build PipelineRun to match the candidate record. Reconcile
any mismatch before proceeding. Require matched admissions, account bindings,
completed successful tests and exact source/reference content on all four
platforms, alongside the actual installation evidence above.

## 4. Stage the pinned candidate and hand it to QE

Follow [stage creation][stage], scoped to `0.24.1` and `--ocp 5.0`. Pin both
`FBC_EXPECTED_COMMIT` and `FBC_EXPECTED_SNAPSHOTS` to the recorded candidate.
Inspect the generated Release's exact name, plan and snapshot; use that file
for [application][apply] and [completion checks][check], not an mtime lookup.
Generation validates and commits YAML; managed-release policy acceptance is
established by the actual release execution.

Require the exact stage Release to finish `Released=True/Succeeded` with no
policy violations and no production-index publication. Follow the
[QE handoff][qe] for the released fragment and intended bundle/channel. Verify
approved **0.24** mappings and pull access if stage mirrors are needed; the
current mirror file targets 0.23. Compare any URL-helper result with that exact
Release, snapshot and fragment; a latest-successful lookup can select another
candidate. Record these identities and artifact digests in the QE handoff, and
wait for approval
of those artifacts before production.

## 5. Publish the approved snapshot and activate scope

Follow [production creation][prod], still scoped to `0.24.1` and OCP 5.0.
Confirm production bundle availability and required Pyxis FBC opt-in. The helper
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

## Related 4.x migration

[release-data !23841][migration] is independent of this rollout. Its prepared
default-channel follow-up still needs intended-stream selection and enforced
installation to qualify maintenance releases.

[delivery]: https://redhat.atlassian.net/browse/ACM-48200
[catalog]: https://github.com/stolostron/submariner-operator-fbc/pull/81
[pipelines]: https://github.com/stolostron/submariner-operator-fbc/pull/82
[profile]: https://github.com/openshift/release/pull/87176
[helper]: https://github.com/stolostron/submariner-release-management/pull/120
[tenant]: https://gitlab.cee.redhat.com/releng/konflux-release-data/-/merge_requests/23786
[migration]: https://gitlab.cee.redhat.com/releng/konflux-release-data/-/merge_requests/23841
[rerun]: https://konflux-ci.dev/docs/testing/integration/rerunning/
[lifecycle]: https://redhat.atlassian.net/browse/OPGM-364
[compatibility]: https://redhat.atlassian.net/browse/OPGM-261
[onboarding]: ../.agents/workflows/add-fbc-ocp-version.md
[stage]: ../.agents/workflows/create-fbc-stage-release.md
[apply]: ../.agents/workflows/apply-fbc-releases.md
[check]: ../.agents/workflows/check-fbc-releases.md
[qe]: ../.agents/workflows/share-with-qe.md
[prod]: ../.agents/workflows/create-fbc-prod-release.md
