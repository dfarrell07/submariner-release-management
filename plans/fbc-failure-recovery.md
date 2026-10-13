<!-- markdownlint-disable MD013 -->

# Restore 0.23.4 FBC and stage it for QE

The immediate goal is successful **0.23.4 stage releases for every active applicable catalog: OCP 4.16–4.21**.
All six stage Releases succeeded on October 12. Their released catalogs are verified with unchanged 0.23.4 bundle and operand pins; the consolidated QE handoff is prepared for the release-record PR.
Generated 4.14/4.15 catalogs also retain this bundle, but are deliberately retired from the active release scope and have no current build pipelines. Active 4.22 and provisional 5.0 contain no 0.23.4 bundle. Do not reactivate those targets for this release.
OCP 5, task-pin refreshes, verifier refactoring, production release and planning-PR cleanup are deferred.

## Why this repair is the first step

The six published operator checks at FBC source `2e6b489e65620738d68504d9158418fe463e2073` originally failed at `get-unreleased-bundle`;
the catalog push builds succeeded. The saved 4.19 log records anonymous production-index pulls returning `401 Unauthorized`.
The October 8 tenant read found the existing Docker-config secret `submariner-konflux-registry-redhat-io`
unlinked from both credential lists on `konflux-integration-runner`.
The [Konflux registry guide](https://konflux-ci.dev/docs/testing/integration/accessing-private-repositories/)
requires an additional-registry credential link to that account.

This supports testing the missing mount link first. It does not establish that the secret is still valid or that every failed run has the same cause.
A new 4.19 run that authenticates and renders the production index is the proof; if it fails, diagnose that run's specific error before changing anything else.
Task expiry, the 4.x channel setting and the OCP 5 build account do not explain this saved 401.

## Retained snapshot and scenario identities

| OCP | Original FBC snapshot |
| --- | --- |
| 4.19 — first | `submariner-fbc-4-19-20260930-152916-000` |
| 4.16 | `submariner-fbc-4-16-20260930-152915-000` |
| 4.17 | `submariner-fbc-4-17-20260930-152915-000` |
| 4.18 | `submariner-fbc-4-18-20260930-152916-000` |
| 4.20 | `submariner-fbc-4-20-20260930-152915-000` |
| 4.21 | `submariner-fbc-4-21-20260930-152915-000` |

Namespace: `submariner-tenant`. Each operator scenario is `submariner-fbc-operator-<OCP-ID>`.
All six were recorded at the source SHA above with finished failed integration verdicts. Re-read those identities before rerunning;
do not select a newer snapshot implicitly. Check actual catalog content before stage release, rather than blocking the credential canary on six catalog extractions.

The intended bundle digest is `sha256:b83d0f0f158e8b7ad1fc749f2a2b69de30aac8b1b7ca0a62ad19b1b0e9359960`.
Its recorded component-stage snapshot is `submariner-0-23-20260930-064533-000`.
The archived component Release `submariner-0-23-4-stage-20260930-01` succeeded; later reads returned NotFound.
Reconcile that existing stage evidence instead of creating a duplicate component release.

## 1. Check and add the credential link

Reconfirm the cluster and namespace. Read the runner and existing secret; check the secret type and usable `registry.redhat.io` credentials
without printing credential values. Test the named secret against the 4.19 production index, using a private temporary auth file.
Save the original runner, check for competing credentials and confirm that the additive link preserves existing links.
If the secret is already linked, inspect the task's credential initialization instead of unlinking/relinking it.

If the link is absent and the credential check succeeds:

```bash
oc secrets link konflux-integration-runner submariner-konflux-registry-redhat-io -n submariner-tenant
```

Use the mount link shown above; an image-pull-only link does not supply a running task's index-render credentials.
Read it back. The change affects new task pods; it cannot repair the old failed pod.

### Release-data merge-request scope

The existing declarative repair is only three tenant files at local commit `3edd2876d3c3eaa31c573ada703fce1fe6c3f858`
in `fbc-failure-fix-work/registry-access`. Refresh/review it when GitLab is reachable and verify reconciliation preserves the link.
GitLab access and merging that draft are not prerequisites to proving the live repair or preparing the first stage release.

## Rerun the same release snapshots

Confirm its initial tests finished, source/application/image identity matches the candidate, and no rerun is already pending.
Then follow the [snapshot rerun procedure](https://konflux-ci.dev/docs/testing/integration/rerunning/):

```bash
oc label snapshot submariner-fbc-4-19-20260930-152916-000 \
  test.appstudio.openshift.io/run=submariner-fbc-operator-4-19 -n submariner-tenant
```

Verify the new run's snapshot/scenario labels, successful `get-unreleased-bundle` production-index render and completed operator result.
If authentication still fails, inspect credential-copy errors and the effective `HOME`, Docker config or auth-file override.
If the error changes, retain its logs and make only the repair that error justifies. A build `/retest` is not this snapshot rerun.

## 3. Verify and prepare the first stage artifact

Require `AppStudioIntegrationStatus=True/Finished`, `AppStudioTestSucceeded=True`, the new operator run's success,
and completed standard/operator results. Completed warnings are acceptable; `BuildPLRInProgress` strings alone are not proof.
Check that the actual 4.19 fragment contains the intended bundle and operands and that the recorded stage mirror pullspecs are accessible.
The generated production bundle URL can be unpublished at stage: verify the approved Quay digest and exact mirror mapping.
Do not change channels or require production publication merely to stage this candidate. Rebuild only when an actual release failure requires it, as documented below.

Run the existing verifier for the single first target:

```bash
FBC_OCP_VERSIONS=4-19 \
FBC_EXPECTED_COMMIT=2e6b489e65620738d68504d9158418fe463e2073 \
  ./scripts/verify-fbc-release.sh 0.23.4
```

Its JSON must name only 4.19 and the original 4.19 snapshot above. Stop on identity, content or component-SHA mismatches.
Current main's helper accepts unfinished markers, so retain the independent completed-run evidence alongside the verifier result.
Merging the separate gate-hardening draft is not required for this recovery.

In a clean release worktree, use `scripts/generate-fbc-release.sh` with OCP `4.19`, version `0.23.4`, that exact snapshot,
release type `stage` and the current release date. Review the resulting YAML and validate its live ReleasePlan/references.
This preserves the user's existing checkout and pins the verified snapshot explicitly.

## 4. Stage and hand off to QE

Apply the reviewed stage Release through the existing release workflow. Require that exact Release to report `Released=True/Succeeded`.
The October 12 first attempt failed Conforma verification: all five image attestations lack required task `fbc-inject-lifecycle-oci-ta`; no artifact was published.
The supported repair is a fresh 4.19 build with clone → required lifecycle task → OPM and unchanged catalog source/bundle pins.
The approved task reports lifecycle injection unnecessary for OCP 4.19; verify its `TEST_OUTPUT` is successful and the catalog content is unchanged.
Local draft `fbc-failure-fix-work/fbc-4-19-lifecycle` changes only the required task and its artifact forwarding in the six 4.16–4.21 push/PR pairs. Each explicit manual PipelineRun uses the original source SHA, existing build account, unique image tag, all four platforms and all checks.
Require the replacement build, its signed attestations, fresh snapshot tests and exact content/component verification to pass before generating another stage-only Release with that exact new snapshot and a distinct name. Do not retry the old snapshot or weaken policy.
The existing helper prefers the older PaC push snapshot over a manual build, so its green result does not verify this replacement. Use the saved exact-snapshot preflight: signed successful build, finished aggregate/scenario tests, all 19 catalog files equal to pinned source, unchanged approved bundle/operand digests and correct channel. Release policy still evaluates the replacement normally.
Read `status.artifacts.components[].fbc_fragment` from that exact Release and verify its catalog contains the approved 0.23.4 bundle and channel.
Prepare the QE handoff with its Release name, OCP 4.19, verified stage catalog image, bundle digest and approved stage ImageDigestMirrorSet.
`./scripts/get-fbc-urls.sh 0.23.4 --ocp 4.19 --raw-url` is a corroborating lookup only: it can select another matching Release or fall back to a pre-release snapshot.
Raw mode avoids an automatic Jira description update. The snapshot image alone does not prove stage publication.
Follow the [stage-QE workflow](../.agents/workflows/share-with-qe.md) for the actual available target; do not require every supported target before the first handoff.

A green operator scenario can skip installation because the current channel selection returns no bundle.
It establishes recovery of this integration gate, not installation or QE success. QE must install the approved staged bundle using the mirrors: package `submariner`, channel `stable-0.23`, starting CSV `submariner.v0.23.4`.
The package default is `stable-0.24`; selecting that default would test a different release.
The first 4.19 stage release need not wait for the other five. Recover and stage those targets individually after their own checks pass;
report the actual available scope instead of claiming all six are ready. Stop this workstream at the stage/QE handoff.

## Rollback and current limit

If this recovery added the link and rollback is needed, unlink only that credential reference; preserve the shared secret, runner and prior links.
For the declarative repair, remove the reference while retaining the ServiceAccount resource to avoid pruning it.
October 12 live preflight confirms the secret can authenticate the 4.19 index, no linked credential competes for `registry.redhat.io`,
and server dry-run preserves all existing links. The mount link is now added and read back. Canary run `submariner-fbc-operator-4-19-7g6p6`
references the original snapshot/scenario. The run completed successfully; snapshot integration is Finished and aggregate tests now Passed. Scoped release verification also passes for the exact snapshot.
All six original snapshots now have fresh passing operator results and finished successful aggregate verdicts.
The first 4.19 stage YAML passes server dry-run and `make test-remote`; the user explicitly approved stage-only application.
Release `submariner-fbc-4-19-0-23-4-stage-20261012-01` was applied at 18:42 UTC on October 12 and failed at the required-task check in `rhtap-releng-tenant/managed-4wp6h` at 18:43 UTC. It has no published artifact.
Replacement build `submariner-fbc-4-19-stage-recovery-20261012-01` completed all 12 pipeline tasks successfully at 18:54 UTC and is signed. Snapshot `submariner-fbc-4-19-20261012-184702-000` has finished passing tests. All 19 rebuilt catalog YAML files match the pinned source; the required task's test result is SUCCESS and its source artifact is unchanged.
The second stage Release `submariner-fbc-4-19-0-23-4-stage-20261012-02` pins that exact replacement snapshot. It reached `Released=True/Succeeded` at 19:11 UTC on October 12. Managed pipeline `rhtap-releng-tenant/managed-mzvh7` passed with 14 tasks completed, zero failures and five skips; release policy passed 700 checks with zero violations and ten warnings.
Its released FBC fragment is the verified Quay catalog at `sha256:154bba93658ca69ae2a7933a19b04247f2d276cf6baed2f12dfbffba1123f5f7`; its immutable manifest is accessible and contains all four architectures. IIB stage build `1228243` produced index digest `sha256:3e3c7790dfb451efbe36483d96168c92b78c73d0882e99586d4e0eff03c5c68f`. A local probe of the internal index registry timed out; QE can use the verified released fragment with stage mirrors.
The full six-target release verifier also completed successfully and returns exactly the original six snapshots, approved bundle and component pins.
All six stage Releases and their exact released fragments are now verified. The last target, 4.16, reached `Released=True/Succeeded` at 20:02:39 UTC. All replacement builds are signed and successful, snapshot tests finished passing, and catalog contents match the pinned source. Their stage-only YAMLs passed server dry-run, live-reference checks and repository tests before application. Every managed stage pipeline passed 700 policy checks with zero violations. Fresh registry reads verified all six catalog digests/four architectures and the eight bundle/operand mirrors; every `stable-0.23` channel head is `submariner.v0.23.4`. The release-record PR carries the consolidated handoff and exact Release/snapshot identities; completed build, snapshot, policy and Release JSON records are retained with the recovery evidence. Installation remains for QE.
The twelve-file pipeline repair remains local and needs normal submission for future builds, alongside the declarative credential-link follow-up. Stage recovery is complete; review only the demonstrated automation gaps next. No production Release was applied.
The staged bundle and all seven operand mirror digests also match the recorded component-stage snapshot and are locally registry-accessible.
