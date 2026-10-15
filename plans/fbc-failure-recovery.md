<!-- markdownlint-disable MD013 -->

# 0.23.4 FBC recovery record and QE handoff

**Recovery completed October 12, 2026.** All six applicable OCP 4.16–4.21 stage Releases succeeded with unchanged approved 0.23.4 bundle/operand pins. The merged [QE handoff](../releases/fbc/qe-0.23.4-stage-20261012.md) owns exact successful Release/snapshot/fragment identities. Installation/functional QE qualification remains open; production is a separate gate. Catalog/stage Jira children ACM-44537/44538 are Resolved, with completion receipts on ACM-44527.

This is a recovery record, not a request to rerun it. The [earlier incident record](https://github.com/stolostron/submariner-release-management/blob/f071c65c288e2bf1b2fd8f2470e70d819ad2031a/plans/fbc-failure-recovery.md) retains original commands, diagnostics and authorization receipts. OCP 4.14/4.15 are retired; active 4.22 and provisional 5.0 do not carry this candidate.

## Incident and completed repair

The original operator checks failed while rendering the production index; the saved 4.19 log reports anonymous `401 Unauthorized`. The existing registry secret was missing from the integration runner's credential lists. October 12 credential validation/linking and reruns restored all six integration results. This resolved that incident; do not repeat credential linking without current evidence of a missing binding.

The first stage attempt then exposed a separate required-task policy failure. Fresh signed builds executed clone → lifecycle task → OPM, preserved catalog content and passed managed policy. On 4.x the task's lifecycle injection was a successful no-op; it does not establish OPGM-364's target 5.0 publication proof.

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
All six were recorded at catalog source `2e6b489e65620738d68504d9158418fe463e2073` with finished failed integration verdicts. They are the original incident identities, not the successful replacement snapshots in the QE handoff.

The intended bundle digest is `sha256:b83d0f0f158e8b7ad1fc749f2a2b69de30aac8b1b7ca0a62ad19b1b0e9359960`.
Its recorded component-stage snapshot is `submariner-0-23-20260930-064533-000`.
The archived component Release `submariner-0-23-4-stage-20260930-01` succeeded; later reads returned NotFound.
Reconcile that existing stage evidence instead of creating a duplicate component release.

## Release-data merge-request scope

The earlier three-file declarative credential draft at `3edd2876` is a historical candidate. Current GitLab source access worked again on October 15; approvals/CI were not independently read. Before submission, reconcile current ownership and actual desired binding instead of replaying the old repair. OCP 5 tenant/admission MR !23786 is a separate scope in the [rollout plan](ocp-5-0-fbc-rollout.md).

## Future recovery

No recovery rerun is pending. For a demonstrated new failure, use the [canonical stage recovery workflow](../.agents/workflows/create-fbc-stage-release.md#recover-a-policy-rejected-image). Inspect the exact candidate, completed aggregate/scenario evidence, current error and any pending run before choosing rerun versus rebuild. Keep the original failure and replacement identities distinct.

Main now includes merged release-management #114/#117's completed-test, exact-snapshot and publication gates. The earlier warning that main accepts unfinished markers is superseded. Do not bypass those checks or infer installation from a completed skipped-install scenario.

## Stage and hand off to QE

The original 4.19 Release `submariner-fbc-4-19-0-23-4-stage-20261012-01` failed required-task policy without publishing. Retry `submariner-fbc-4-19-0-23-4-stage-20261012-02` succeeded using replacement snapshot `submariner-fbc-4-19-20261012-184702-000`; the other five targets also completed. Their successful managed pipelines each passed 700 policy checks with zero violations. These are dated recovery receipts, not fresh policy results.

QE must select channel `stable-0.23`, CSV `submariner.v0.23.4` and the handoff's exact staged fragments/mirrors. The package default `stable-0.24` selects a different release. QE tracker ACM-44539 already reports the same 14-failure summary as ACM-48176. ACM-48176 has an `e2e.zip` attachment; its bytes remain unread, and ACM-48194 has no attachment in the captured fields. Correlate primary logs with actual OCP version, CSV, catalog/bundle/operand/nettest digests and the invoked test/CLI version. Inspect admission events and container startup before attributing service-discovery symptoms to DNS or calling the reports duplicates. The described 0.23.4 versus ACM-48176 Affects Version 0.23.2 discrepancy remains unresolved. Keep QE acceptance open.

## Remaining handoffs

* FBC [#85](https://github.com/stolostron/submariner-operator-fbc/pull/85) (`02ac47d1`, two docs) and [#86](https://github.com/stolostron/submariner-operator-fbc/pull/86) (`7c963da2`, fourteen pipeline files) remain open. Required checks pass; Tide is pending. The old twelve-file local draft is superseded by the submitted seven-catalog pipeline proposal.
* #86's seven exact-head PR snapshots were verified earlier October 15 with Finished/Passed aggregates and completed operator/standard scenarios. Their PR provenance is distinct from the successful manual recovery builds. A subsequent live read returned Unauthorized, so no later live freshness is claimed.
* Complete normal repository review, actual QE installation/testing and production approval. Reconcile stream-specific CVE/advisory coverage through the [separate metadata proposal](current-work.md#release-recovery-and-time-sensitive-work); it is not implemented or an approved closure policy. Confirm the exact successful stage identities before production generation: current generators select stage files lexically and do not enforce QE approval. Existing stage Releases need no replay. Release-management #115–118 already merged the recovery workflow, handoff and validation fixes.
