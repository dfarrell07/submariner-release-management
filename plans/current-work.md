<!-- markdownlint-disable MD013 -->

# Release-management work

Ownership checked October 15, 2026 against Jira's assigned-to-current-user query. Jira owns assignment, priority, status and acceptance. These plans retain Daniel's implementation decisions specific to this repository.

## Suggested work order

Order and activity checked October 15, 2026. This is a recommendation based on deadlines and release dependencies; refresh Jira and existing PRs before starting. Ticket activity alone does not establish implementation progress. Promote a tooling fix if it blocks an active release.

| Order | Work | Observed activity and next action |
| --- | --- | --- |
| 1 | [ART migration — ACM-45318](https://redhat.atlassian.net/browse/ACM-45318) | Due October 15; Jira New. Brew source references verified October 15; no open addon PR changes their Dockerfiles. Prepare a minimal main-branch pilot; resolve effective CI inputs/access for qualification using the [handoff](#builder-guidance) |
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

[ACM-45318](https://redhat.atlassian.net/browse/ACM-45318) owns the addon consumer migration. Next: prepare an addon PR against main replacing the Brew builder `FROM` in `Dockerfile` and `Dockerfile.konflux`. Use the [addon builder checks](../.agents/workflows/scan-cves.md#addon-go-toolchain) and normal repository review; backport only to supported consumers after the image checks pass.

Source decisions checked October 15:

* [Konflux configuration](https://gitlab.cee.redhat.com/releng/konflux-release-data/-/tree/bc743a1e127c1722636d1fb332025b5bd3df9df6/tenants-config/auto-generated/cluster/stone-prd-rh01/tenants/crt-redhat-acm-tenant) selects 2.11, 2.13–2.17, 5.0 and main for both ACM 5.1/5.2. ACM 2.12's Konflux component is retired; Prow additionally configures 2.12 and 5.1 branch builds. Confirm active sources before backporting.
* ART's ACM 2.15–2.17 configuration selects a private source mirror and [overrides the builder](https://github.com/openshift-eng/ocp-build-data/blob/acm-2.16/images/submariner-addon.yml) with [ART Go 1.26/RHEL9](https://github.com/openshift-eng/ocp-build-data/blob/acm-2.16/streams.yml). Preserve those overrides; the table below applies to direct Dockerfile consumers.

Candidate tags under `registry.redhat.io/openshift/golang-builder`, subject to the workflow's checks:

| Current Brew builder | Matching ART family |
| --- | --- |
| Pinned Go 1.24.6 / RHEL9 (2.11/2.12) | `golang-builder-v1.24-rhel9` |
| `v1.25` / RHEL8 (2.13–2.17) | `golang-builder-v1.25-rhel8` |
| `v1.26` / RHEL9 (main/5.x) | `golang-builder-v1.26-rhel9` |

Preserve runtime bases and existing flags, including CGO/strict-FIPS on 2.15/2.16 and the PQC base on 5.0. Leave the 2.14 ordinary CI builder and inspected UBI Go Toolset paths unchanged. RHEL9 Go 1.25 adds `GOAMD64=v2` and needs a separate OS/CPU decision.
