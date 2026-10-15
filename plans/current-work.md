<!-- markdownlint-disable MD013 -->

# Release-management work

Ownership checked October 15, 2026 against Jira's assigned-to-current-user query. Jira owns assignment, priority, status and acceptance. These plans retain Daniel's implementation decisions specific to this repository.

## Suggested work order

Order and activity checked October 15, 2026. This is a recommendation based on deadlines and release dependencies; refresh Jira and existing PRs before starting. Ticket activity alone does not establish implementation progress. Promote a tooling fix if it blocks an active release.

| Order | Work | Observed activity and next action |
| --- | --- | --- |
| 1 | [ART migration — ACM-45318](https://redhat.atlassian.net/browse/ACM-45318) | Due October 15; Jira New. Inventory posted October 8, migration unconfirmed. Finish addon migration/qualification and the [local guidance edit](#builder-guidance) |
| 2 | Nettest — [ACM-48176](https://redhat.atlassian.net/browse/ACM-48176), [ACM-48194](https://redhat.atlassian.net/browse/ACM-48194) | Both New, updated October 15; logs added to ACM-48176. Confirm tested images and whether reports share a cause; implementation progress unconfirmed |
| 3 | [0.23.4 — ACM-44527](https://redhat.atlassian.net/browse/ACM-44527) | In Progress; October 12 stage evidence reconciled October 13. Follow up on nettest disposition and QE, then production prerequisites |
| 4 | [OCP 5 pre-GA gate](ocp-5-0-fbc-rollout.md#decision-before-stage) | Existing draft #119/#120 commits October 15. Resolve required scenario evidence and installation timing before stage |
| 5 | [OCP onboarding/catalog delivery](ocp-5-0-fbc-rollout.md#existing-changes-to-reuse) — ACM-48092/ACM-48200 | In Progress; #119/#120 and FBC #82 already underway. Continue existing changes and tenant MR !23786, then the canonical rollout after the gate decision |
| 6 | [Lifecycle publication — OPGM-364](https://redhat.atlassian.net/browse/OPGM-364) | In Progress; shares active FBC #82 prerequisites. Release existing data and record publication proof; catalog delivery alone does not complete this |
| 7 | [0.22.2 — ACM-45070](https://redhat.atlassian.net/browse/ACM-45070) | In Progress; last Jira update October 4. Recover candidate/operand evidence using the [existing investigation](#existing-release-work) |
| 8 | [Production URL conversion](autorelease-step-automation.md#production-url-conversion) — ACM-39732 | Jira New; existing fork implementation. Reconcile that candidate, complete skill/wiring and exact publication verification |
| 9 | [Tracker reconciliation](autorelease-step-automation.md#tracker-reconciliation) — ACM-39730 | In Progress; related #114/#118 merged October 13. Retarget automation and parent Key Artifacts refresh remain |
| 10 | [Conductor follow-ups](autorelease-step-automation.md#tracker-reconciliation) — ACM-39731 | In Progress; related #114/#117 merged October 13. Review remaining write/retry, discovery and snapshot-selection boundaries within that work |

## Existing release work

[0.23.4 — ACM-44527](https://redhat.atlassian.net/browse/ACM-44527) owns release coordination; the [merged QE handoff](../releases/fbc/qe-0.23.4-stage-20261012.md) owns successful stage identities. QE acceptance belongs to the owner of ACM-44539. Daniel's nettest investigations remain in ACM-48176/ACM-48194; their logs and tested-artifact attribution belong with those issues.

For [0.22.2 — ACM-45070](https://redhat.atlassian.net/browse/ACM-45070), preserve the September EC receipt for `submariner-0-22-20260923-230555-000`. The later inspected `submariner-0-22-20261002-125823-000-lz` is unselected; embedded operand identity remains unreconciled. The [dated investigation](https://github.com/stolostron/submariner-release-management/blob/0b57e9604b2cca44a6fc367711a1176d4ec96f7a/plans/current-work.md#0222-candidate-reconciliation) retains the comparison and its limits. Recover intended candidate/operand evidence before choosing reuse, rebuild or retargeting; empty later receipts alone justify no EC rerun.

## Builder guidance

[ART migration — ACM-45318](https://redhat.atlassian.net/browse/ACM-45318) owns the addon migration and recorded inventory. Its local follow-up is to update [addon toolchain guidance](../.agents/workflows/scan-cves.md#addon-go-toolchain) with the accepted ART builder while preserving the actual Go/OS family. Dockerfile changes and image qualification belong in the addon repository.
