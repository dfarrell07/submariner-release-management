<!-- markdownlint-disable MD013 -->

# OCP 5.0 FBC rollout plan

Reviewed 2026-10-06; heads, published checks and clean configuration drafts rechecked 2026-10-07. Lifecycle target, prerequisites and posting verified 2026-10-08.
Use the [current work map](current-work.md) and [builder branch inventory](art-builder-migration.md) for concurrent builder, PQC, addon and release work. Consolidates the planning document from
[FBC PR #82](https://github.com/stolostron/submariner-operator-fbc/pull/82), head
`1e8b3c26137b49db60a0d93853f144990770f304`. The pipeline implementation remains in that PR.
This document supports the proposed OCP onboarding story in the [tracking plan](agentic-sdlc-jira-updates.md).
It records review gates; it does not authorize pushes, merge requests, cluster changes, provisioning or releases.

[Current FBC failure recovery](fbc-failure-recovery.md) takes priority: restore the existing 4.x release tests, then address #82's missing-account prerequisite.

## Evidence and current boundaries

| Area | Checked result | Remaining gate |
| --- | --- | --- |
| Catalog/tooling | FBC #76 and #81 merged; current FBC main is `2e6b489e65620738d68504d9158418fe463e2073` | Confirm provisional inputs against product policy and runtime compatibility |
| Pipelines | #82 remains open; two pipeline files and a snapshot-verification doc change | Rebase onto current main, reconcile task pins and pass checks at the exact head |
| PR failure | GitHub's published Konflux check reports `init` / `PodCreationFailed`: `build-pipeline-submariner-fbc-5-0` not found | October 7 authenticated read confirms absent build account, Application and Component; reconcile configuration first |
| Tenant/admission | Local drafts inspected; cached base is `8c18efee295889f5d86b03d16930a2f11977fd58` from September 18 | Refresh GitLab main, review two separate changes and verify live reconciliation |
| Registry access | October 7 authenticated read confirms the registry Secret exists but is absent from both integration-runner credential lists | Validate credential usability/field ownership, then separately authorized repair and verified-snapshot rerun |
| Installation | Source inspection establishes conditional execution, not a successful OCP 5 install | Record actual cluster version, selected bundle/channel and successful installation/QE |
| Release | Existing RPA drafts use generic OCP-version index templates | Confirm live matching, release mode, publishing decisions and target-index membership |

The October 7 authenticated read checked `submariner-tenant`. The 5.0 Application, Component and build account are absent;
the existing Docker-config Secret remains unlinked to the integration runner. No PipelineRuns are retained; the [work map](current-work.md#release-recovery-and-time-sensitive-work) owns the current snapshot total.
The six exact failed 4.x [snapshot/scenario associations](fbc-failure-recovery.md#retained-snapshot-and-scenario-identities) are recovered;
re-read their identities and verify intended catalog content before reruns. Credential usability and controller ownership remain unverified.
The refreshed GitLab main read still fails DNS. The published failed PipelineRun is no longer retained; its GitHub check preserves the missing-account error, corroborated by the current tenant read.
The original plan's cluster findings remain dated observations. Native image/E2E validation is recorded in
[implementation status](ocp-5-implementation-status.md); those runs were not repeated during this consolidation.
The September 24 status document describes an earlier state, including before #81 merged.

The catalog on current FBC main uses provisional minimum Submariner stream **0.24**, default channel **stable-0.24**,
and bundles **0.24.0 / 0.24.1**. The unchanged bundle compatibility declaration reported in the implementation record is `v4.15-v4.19`.
Catalog validation and a native OCP-base image test establish packaging behavior, not operator compatibility on OCP 5.
OPGM-364’s requested progress answer was posted October 8 as comment `18829498`; the issue remains In Progress and lifecycle publication remains pending. No program status label or workflow transition was assigned.
OPGM-364 requires publication of existing valid lifecycle data without new OpenShift 5 / 5.0 compatibility statements; team IIB/catalog proof is an allowed alternative to public-index membership. The program’s October 7 parent guidance separately requires a fully supported 4.22/5.0 version at GA. Lifecycle publication alone does not establish that support qualification.

## 1. Refresh and reconcile configuration

Inspect the existing worktrees before changing them. The checked tenant draft ends at `47eda9c5b11c6f57fb7a4f7fb9be2e0fd42be588`
(two commits after its cached base); the separate admission draft ends at `860aa737d0` (one commit after that base).
The tenant draft includes a workflow-document rewrite as well as generated resources. Separate that rewrite from the immediate CI repair;
the configuration-only scope is 16 files and seven new resources. The two-file admission draft serves later release matching,
not build-account provisioning. The [recovery plan](fbc-failure-recovery.md#release-data-merge-request-scope) records the three distinct MR scopes.
Do not regenerate, reset or overwrite an existing draft solely because a fresh helper run is available.

1. Fetch current release-data main when access is available and reconcile each draft with it. Cached configuration cannot prove current policy or deployment state.
2. Keep tenant infrastructure and managed admissions in separate merge requests. Follow release-data's AGENTS.md, direct-project branch policy and current CODEOWNERS;
   validate with full `tox`, tenant regeneration and `tox -e tenants-config-test` where applicable. Record an unrelated baseline failure separately from new failures.
3. Verify the generated Application, Component, ImageRepository, two ITS objects and two manual ReleasePlans. Validate both RPA additions against current constraints,
   origin, policy, service account, destinations and release-plan matching. Do not infer that historical approval coverage or policy remains sufficient.
4. After authorized merge, verify reconciliation rather than relying on elapsed time: tenant changes reconcile through ArgoCD; managed resources apply through release-data CI.
   Check the build service account and image-push secret as well as the resource identities above. Do not publish secret values.
5. Reuse the existing PaC Repository for this source repository only after verifying its current configuration. If an onboarding PR appears, reconcile it with #82's pair.

The draft's operator ITS selects an empty `CHANNEL_NAME` (package default), the image-push secret's `.dockerconfigjson` key, and the
[0.2 PipelineRun wrapper](https://github.com/konflux-ci/tekton-integration-catalog/blob/24ed4b2be4ff378d2d688b7bc380e47ef99a3eba/pipelineruns/deploy-fbc-operator/0.2/deploy-fbc-operator-run.yaml).
That wrapper resolves the **0.3 pipeline**; the directory version is not the executed pipeline version.
Both resolver revisions are `main`, so record the actual resolved source at execution time. A dated source check does not pin future runs.

## 2. Establish registry access and determine whether installation will run

The [private-registry documentation](https://konflux-ci.dev/docs/testing/integration/accessing-private-repositories/) requires credentials for additional registries
such as `registry.redhat.io` to be linked to `konflux-integration-runner`. Component-image credentials are linked automatically.
A credential passed for OCI artifact storage does not by itself establish authentication for the production-index render.

The earlier A11 read records a tenant registry Secret that was not linked to that runner on October 1. Its presence/type does not prove usable credentials; verify the current binding and registry access first.
If the maintainer chooses the documented manual repair and authorizes the live write, the proposed command is:

```bash
oc secrets link konflux-integration-runner submariner-konflux-registry-redhat-io -n submariner-tenant
```

The corresponding `oc secrets unlink` can remove that link; save the original binding so rollback restores the actual prior state.
For a declarative fix, check controller/GitOps ownership and merging behavior before applying a ServiceAccount manifest.
Restoring credentials may remove the observed render failure; it does not prove an install or explain why older runs passed.
Use archived successful-run logs to establish earlier authentication and executed tasks.

The inspected [bundle helper](https://github.com/konflux-ci/tekton-integration-catalog/blob/24ed4b2be4ff378d2d688b7bc380e47ef99a3eba/stepactions/bundles/get-unreleased-bundle/0.1/get-unreleased-bundle.yaml)
uses konflux-test **v1.4.48**, pinned image digest `sha256:9b815268fb2bf10b5d745518da1c6568944f15816efe51adc192972b42a6e74d`.
Its image revision and matching Git tag resolve to
[`5f33b66974c024e0e3b2d809de88297e9806f9a0`](https://github.com/konflux-ci/konflux-test/blob/5f33b66974c024e0e3b2d809de88297e9806f9a0/test/utils.sh).
The helper compares bundle image pullspecs in the fragment with those in the production index selected from the fragment's target OCP version.
For this catalog that target is `registry.redhat.io/redhat/redhat-operator-index:v5.0`.

**Release in a 4.x index does not prove membership in the 5.0 index.** The original plan's claim that the two released bundles necessarily make
5.0 a no-op was unsupported. Read the matching index and helper results before deciding whether this push will provision a cluster.
Registry authentication and current index contents were not verified here.

The inspected [0.3 pipeline](https://github.com/konflux-ci/tekton-integration-catalog/blob/24ed4b2be4ff378d2d688b7bc380e47ef99a3eba/pipelines/deploy-fbc-operator/0.3/deploy-fbc-operator.yaml)
skips discovery/provisioning/installation for PR events. On push, later install tasks depend on a returned bundle; an empty result permits a no-op pass.
Record the resolved TaskRuns and returned bundle/channel. A green PR check or aggregate ITS status cannot establish installation coverage.
The cached 4.x `CHANNEL_NAME=stable` does not match the catalog's versioned channels; that configuration supplies no installation evidence.
Do not claim that every historical 4.x run skipped installation without its archived logs.

Before any provisioning, confirm access to the configured OpenShift CI profile (the 0.3 default is `aws-konflux-prod`).
The [migration guide](https://github.com/konflux-ci/tekton-integration-catalog/blob/24ed4b2be4ff378d2d688b7bc380e47ef99a3eba/pipelines/deploy-fbc-operator/0.3/MIGRATION.md)
requires shared-profile access and recommends 0.3 for new users. The 0.1/0.2 EaaS path is a deprecated, unverified fallback for OCP 5;
using it requires a separate reviewed decision and actual cluster-version evidence. Access should be resolved before the first push that may select a bundle,
rather than deferred until a newly built bundle is added. `KONFLUX_UI_URL` only changes log links.

## 3. Reconcile #82 and verify its build

The published failure identifies the missing service account as the immediate cause; it does not establish that no later pipeline defect exists.
Reconcile configuration first, then review/rebase #82 and rerun the build through a supported PaC trigger.
Posting `/retest` or pushing a trigger commit is a separate external action requiring authorization.

Compare both pipelines with their reviewed predecessor: `catalog-5-0` input, the OCP 5.0 RHEL9 registry base, matching service account,
event-specific tags and CEL filters, lifecycle task ordering/result forwarding, and all four platforms.
Existing local lifecycle injection and native-image reports are supporting evidence; require the actual Konflux run as well.

The October 7 refresh finds all **12 unique task refs** from the push/PR pair in current acceptable-bundles data. Five matching entries expire; the earlier October 6 artifact recorded four:

| Task | Pinned digest prefix | Allowlist expiry (UTC) |
| --- | --- | --- |
| fbc-fips-check-oci-ta | `736177074f49` | 2026-10-30 00:00 |
| run-opm-command-oci-ta | `edc7d8263a73` | 2026-10-30 00:00 |
| validate-fbc | `4b635b529a29` | 2026-10-30 00:00 |
| fbc-inject-lifecycle-oci-ta | `a80834195fca` | 2026-10-31 00:00 |
| deprecated-image-check | `0ccc688a77e9` | 2026-11-06 00:00 |

The lifecycle pin is therefore **not non-expiring**, contrary to #82's existing description. Refresh task trust and deny-rule checks before merging/running;
allowlist membership alone is not a complete Enterprise Contract verdict. Keep a repo-wide task bump separately reviewable if it touches 4.x pipelines.
The refreshed source artifact is `quay.io/konflux-ci/tekton-catalog/data-acceptable-bundles@sha256:5c50ac7864a2e7c30e211278f4d7a6d718b9061df904059d216b06927053ea34`,
with YAML layer `sha256:8d02b6b687936335df2ff6b53e0db6f28eb27c182e08855c758e95e0c2037a3f`. To reproduce this dated read:

```bash
oras blob fetch quay.io/konflux-ci/tekton-catalog/data-acceptable-bundles@sha256:8d02b6b687936335df2ff6b53e0db6f28eb27c182e08855c758e95e0c2037a3f --output /path/to/task-trust.yaml
```

Read effective rulesets and current-head checks with app IDs. The inspected rules require six Actions contexts (app 15368) and DCO (app 1861);
GitHub's published checks satisfy those contexts at the inspected #82 head, while its Konflux check fails. Require that build to pass too.
Recheck after rebase: strict rules require the branch to be current with main. A legacy protection 404 does not remove effective ruleset requirements.

After authorized merge, retain the original merged-main push PipelineRun, exact source SHA, resulting snapshot and image digest.
Verify the four-platform index and every platform's catalog contents and OCP base annotation, with validation and gRPC serving against the native base.
Use the [canonical onboarding workflow](../.agents/workflows/add-fbc-ocp-version.md):

```bash
./scripts/add-fbc-ocp-version.sh 5.0 --phase verify-live --expected-commit <40-character-merged-sha>
```

This read-only check verifies configuration/build evidence; successful installation and QE still need their own evidence.
To rerun integration tests for an existing snapshot, follow the
[snapshot-label procedure](https://konflux-ci.dev/docs/testing/integration/rerunning/), verify the referenced snapshot/scenario, and retain the new run results.
A build retest does not substitute for rerunning the selected snapshot's integration tests.

## 4. Installation, stage, production and activation

1. Confirm the approved minimum stream, bundle digest and channel. If the generic ITS returns no bundle, use the explicit-bundle QE procedure:
   point a CatalogSource at the built fragment, install through an OLM Subscription, and configure image mirrors when needed.
   Retain actual cluster `status.desired.version` from `oc get clusterversion version -o json`, installed CSV and bundle/image digest.
   If using 0.3, retain successful `pick-cluster-params`, `provision-cluster` and `deploy-operator` evidence for that bundle/channel.
2. Verify current live RP/RPA matching and approved stage/prod index destinations, including any pre-GA routing decision. Cached ACM/MCE examples or
   a reachable `v5.0` tag do not prove the required destination is publishing. Do not change release mode to bypass that review.
3. Inspect the **resolved production release pipeline/tasks**. The cached RPA selects release-service-catalog `production`; the October 6 source check pinned
   it to `9bfb0b2588a07e765fccef05e2919e4a44ff4401`, rather than the repository's default `development` branch.
   The inspected version task accepts `v5.0` from the base annotation. That syntax check does not establish target-index readiness.
4. Confirm current bundle-repository Pyxis opt-in and the release's actual publishing decisions. Past 4.x releases do not establish today's flag.
   The inspected [parameter task](https://github.com/konflux-ci/release-service-catalog/blob/9bfb0b2588a07e765fccef05e2919e4a44ff4401/tasks/managed/prepare-fbc-parameters/prepare-fbc-parameters.yaml)
   can succeed for an opted-out standard-production component while disabling publishing/signing/overwrite. Staging intentionally disables those actions;
   pre-GA/hotfix uses different decisions. Read `Must Publish Index` and verify the intended resulting index, not just `Release succeeded`.
5. Stage the selected snapshot and complete QE on the approved OCP 5 cluster. Production must reuse the exact QE-approved stage snapshot.
   Releases are separate authorized operations; this plan does not apply Release resources.
6. Check the approved bundle version with `./scripts/get-fbc-urls.sh <approved-X.Y.Z> --ocp 5.0 --prod-index`, then compare its exact image digest by direct index inspection.
   The explicit OCP filter is required because the default scope excludes 5.0.
   Only after configuration, build, installation, QE and release evidence pass should a reviewed change activate `5-0` in `scripts/lib/fbc-scope.sh`.
   Its current default scope remains OCP 4.16–4.22. Explicit OCP syntax support does not establish general OCP 5 support.

## Review decisions and ownership of follow-up work

* Release-data: refresh/reconcile the tenant and admission drafts, identify reviewers through current CODEOWNERS, and choose the registry-binding repair.
* FBC #82: keep the pipeline pair and snapshot-loop documentation together; replace its duplicate planning file with a pointer after this consolidation is accepted.
  Update its description's expired-trust claim at the same time. Do not close #82 or move its executable pipelines into this repository.
* Installation/QE: confirm cluster-profile access, target-index bundle membership, approved bundle/channel and runtime support policy before provisioning.
* Separate maintenance: 4.x channel selection and EaaS migration, expiring task pins across the repo, and the previously reported 0.24.0 image-label mismatch.
  The image-label mismatch was not rechecked; verify it before proposing a fix.

The story payloads should link this plan as evidence for ongoing onboarding work. None of these gates is a new Jira story automatically,
and none of the dated findings should be promoted to a current successful rollout without its recorded evidence.
