<!-- markdownlint-disable MD013 -->

# Release-management work

Ownership checked October 15, 2026 against Jira's assigned-to-current-user query. Jira owns assignment, priority, status and acceptance. These plans retain Daniel's implementation decisions specific to this repository.

| Work | Plan and canonical tracking |
| --- | --- |
| Tracker reconciliation, conductor and production URL conversion | [Implementation handoff](autorelease-step-automation.md); ACM-39730, ACM-39731 and ACM-39732 |
| OCP onboarding and the unresolved pre-GA release gate | [OCP 5 handoff](ocp-5-0-fbc-rollout.md); ACM-48092, ACM-48200 and OPGM-364. The [onboarding workflow](../.agents/workflows/add-fbc-ocp-version.md) owns procedures |

## Existing release work

[0.23.4 — ACM-44527](https://redhat.atlassian.net/browse/ACM-44527) owns release coordination; the [merged QE handoff](../releases/fbc/qe-0.23.4-stage-20261012.md) owns successful stage identities. QE acceptance belongs to the owner of ACM-44539. Daniel's nettest investigations remain in ACM-48176/ACM-48194; their logs and tested-artifact attribution belong with those issues.

For [0.22.2 — ACM-45070](https://redhat.atlassian.net/browse/ACM-45070), preserve the September EC receipt for `submariner-0-22-20260923-230555-000`. The later inspected `submariner-0-22-20261002-125823-000-lz` is unselected; embedded operand identity remains unreconciled. The [dated investigation](https://github.com/stolostron/submariner-release-management/blob/0b57e9604b2cca44a6fc367711a1176d4ec96f7a/plans/current-work.md#0222-candidate-reconciliation) retains the comparison and its limits. Recover intended candidate/operand evidence before choosing reuse, rebuild or retargeting; empty later receipts alone justify no EC rerun.

## Builder guidance

[ART migration — ACM-45318](https://redhat.atlassian.net/browse/ACM-45318) owns the addon migration and recorded inventory. Its local follow-up is to update [addon toolchain guidance](../.agents/workflows/scan-cves.md#addon-go-toolchain) with the accepted ART builder while preserving the actual Go/OS family. Dockerfile changes and image qualification belong in the addon repository.
