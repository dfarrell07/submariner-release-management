<!-- markdownlint-disable MD013 -->

# Release-management work

Ownership checked October 15, 2026 against Jira's assigned-to-current-user query. Jira owns assignment, priority, status and acceptance. These plans retain Daniel's implementation decisions specific to this repository.

## Suggested work order

Order and activity checked October 15, 2026. This is a recommendation based on deadlines and release dependencies; refresh Jira and existing PRs before starting. Ticket activity alone does not establish implementation progress. Promote a tooling fix if it blocks an active release.

| Order | Work | Observed activity and next action |
| --- | --- | --- |
| 1 | [ART migration — ACM-45318](https://redhat.atlassian.net/browse/ACM-45318) | Due October 15; Jira New. Brew consumers verified October 15; no open addon PR changes their Dockerfiles. Confirm live CI sources/access, then migrate and qualify the addon using the [handoff](#builder-guidance) |
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

[ART migration — ACM-45318](https://redhat.atlassian.net/browse/ACM-45318) still owns the consumer migration. The parent's statement that migration is complete refers to ART publishing the replacements; current addon Dockerfiles still use Brew. October 15 checks found no Dockerfile changes in the 13 open addon PRs. [Toolchain guidance](../.agents/workflows/scan-cves.md#addon-go-toolchain) now uses the ART registry; implementation and qualification belong in the addon repository.

First confirm deployed source selection and pull access. [Release-data at bc743a1e](https://gitlab.cee.redhat.com/releng/konflux-release-data/-/tree/bc743a1e127c1722636d1fb332025b5bd3df9df6/tenants-config/auto-generated/cluster/stone-prd-rh01/tenants/crt-redhat-acm-tenant) selects `release-2.11`, `release-2.13`–`release-2.17`, `release-5.0` and `main` (for both ACM 5.1/5.2), using `Dockerfile.konflux`. ACM 2.12 was removed; [addon #2826](https://github.com/stolostron/submariner-addon/pull/2826) still proposes pipeline cleanup. Prow still configures ordinary `Dockerfile` builds for 2.11–2.17, 5.0, 5.1 and main. Confirm retained support before choosing backports; separate appstudio branches, 2.10, 4.23 and 5.2 copies are not automatically active sources. Live ACM-tenant reads failed authentication/access checks, so Git configuration does not establish deployment.

Choose a floating tag under `registry.redhat.io/openshift/golang-builder` after confirming the used Dockerfile's current family. October 15 index/config reads support these candidates, not completed build qualification:

| Current Brew builder | Candidate ART tag |
| --- | --- |
| Pinned Go 1.24.6 / RHEL9 (2.11/2.12) | `golang-builder-v1.24-rhel9` |
| `v1.25`, which declares RHEL8 (2.13–2.17) | `golang-builder-v1.25-rhel8` |
| `v1.26` / RHEL9 (main/5.x) | `golang-builder-v1.26-rhel9` |

Prepare isolated addon changes using the workflow's qualification checks. Replace Brew references in both **used** Dockerfiles; leave the 2.14 ordinary CI builder alone. Preserve 2.15/2.16's CGO/strict-FIPS flags and 5.0's PQC runtime base. The RHEL9 Go 1.25 candidate adds `GOAMD64=v2`; choosing it would combine registry migration with an OS/CPU change.

The other ticket-listed repositories still use UBI Go Toolset in all 36 inspected 0.19–0.24 component Dockerfiles; fresh devel and 0.19–0.24 source searches found no direct Brew consumer. Retain their no-change evidence in Jira, checking deployed overrides/external inputs before closure. The deadline alone does not require replacing UBI builders.
