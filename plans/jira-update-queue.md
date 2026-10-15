<!-- markdownlint-disable MD013 -->

# Assigned Jira work: current dispositions

Reconciled October 15, 2026. Paginated inventory: **706 assigned issues, 77 active**; membership/status categories were unchanged at the 14:48 UTC refresh. Field reads covered 24 assigned issues updated since October 8 and five related targets. This is a recent-change reconciliation, not a semantic audit of the whole backlog. Restricted follow-up stays private.

The [October 8 queue](https://github.com/stolostron/submariner-release-management/blob/f071c65c288e2bf1b2fd8f2470e70d819ad2031a/plans/jira-update-queue.md) and [verification log](agentic-sdlc-jira-updates-verification.md) retain the earlier 703-issue inventory and 76 active general-issue dispositions. Those populations and approval groups are historical. The old payloads must not be replayed as a current batch.

## Approval order

**No Jira write batch is selected.** Refresh only a useful missing delta when it is selected; preserve native ADF, acceptance, ownership, existing links and completed receipts. Any later external write needs explicit authorization.

The Submariner description contains edits 1/2 and the main release/ownership corrections from 3/4. Edit 5's additional Release tooling and Glasswing sections are absent; adding them remains a scope decision, not an approved write. OCP onboarding already has ACM-48092. The other S/K splits remain unselected; do not create retrospective or duplicate stories to exhaust the old sequence.

## Engineering priorities and remaining decisions

| Work | Current tracking and next action |
| --- | --- |
| [ART Go builders — ACM-45318](https://redhat.atlassian.net/browse/ACM-45318) | New; October 15 deadline. The existing planning comment records remaining migration and qualification. Confirm active sources and execute/verify the [builder migration](art-builder-migration.md); completion remains unverified. |
| [0.23.4 — ACM-44527](https://redhat.atlassian.net/browse/ACM-44527) | In Progress. Catalog ACM-44537 and stage ACM-44538 are Resolved, with exact completed STEP_DATA on the parent. Use the [existing stage handoff](../releases/fbc/qe-0.23.4-stage-20261012.md) for actual QE installation/testing, then production when approved. Do not repeat stage recovery. |
| [Nettest failures — ACM-48176](https://redhat.atlassian.net/browse/ACM-48176) | New; reports 14 service-discovery failures. Inspect attached logs and reconcile exact tested artifacts: description says 0.23.4 while Affects Version says 0.23.2. Attachment bytes remain unread; diagnosis and release impact are unknown. |
| [FBC production — ACM-44541](https://redhat.atlassian.net/browse/ACM-44541) | New. Today's description already says applicable 0.23.4 catalogs are currently OCP 4.16–4.21. Keep production pending; no duplicate range correction or stage-to-production inference. |
| [OCP onboarding — ACM-48092](https://redhat.atlassian.net/browse/ACM-48092) | In Progress; reuse this story instead of S1. Its comment records the tenant/admission MR. Draft [FBC #82](https://github.com/stolostron/submariner-operator-fbc/pull/82), [runbook #119](https://github.com/stolostron/submariner-release-management/pull/119) and [automation #120](https://github.com/stolostron/submariner-release-management/pull/120) remain open. #82's Konflux check fails. Complete configuration, platform builds and real OCP 5 installation against the story's existing criteria. |
| [Lifecycle publication — OPGM-364](https://redhat.atlassian.net/browse/OPGM-364) | In Progress; preserve its separate lifecycle-only scope, allowed IIB/catalog proof and prohibition on new OpenShift 5 compatibility statements. OCP onboarding is not its acceptance gate. No fresh lifecycle publication proof was inspected. |
| [0.22.2 — ACM-45070](https://redhat.atlassian.net/browse/ACM-45070) | In Progress; parent artifacts remain placeholders. ACM-45075 records six merged PRs and an earlier EC-success claim. Recover existing exact-candidate evidence or owner reconciliation before correcting tracking or recommending another run. The old candidate comment stays held; dry-run children remain separate. |
| [Release automation — ACM-39730 / ACM-39731](https://redhat.atlassian.net/browse/ACM-39731) | In Progress. Existing October 13 comments already record merged #114/#117/#118. Parent artifact/retarget automation remains a follow-up; no duplicate merge comment. |
| [Knowledge transfer — ACM-39736](https://redhat.atlassian.net/browse/ACM-39736) | New. Updated workflows and handoff are already recorded; multiple team members completing full releases and recording gaps remain the original acceptance. |
| [CVE contributions — ACM-39738/39739/39740](https://redhat.atlassian.net/browse/ACM-39738) | New. Shipyard [#2582](https://github.com/submariner-io/shipyard/pull/2582) merged October 14 and is already recorded on ACM-39729/39739. The go-fix-cves ai-helpers contribution remains unfinished; the generalized agent also requires ai-helpers merge and non-Submariner product validation. |
| [Kubernetes plugin — CORENET-7155](https://redhat.atlassian.net/browse/CORENET-7155) | In Progress; description applied, no epic children returned. [#617](https://github.com/openshift-eng/ai-helpers/pull/617) remains draft at `1a33dafe`. Qualification, measured evaluations and upstream merge remain existing criteria; K1–K5 are not a required retrospective split. |
| [EGA planning — CORENET-7615](https://redhat.atlassian.net/browse/CORENET-7615) | In Progress; description already points to draft [#14](https://github.com/openshift/evpn-gateway-appliance/pull/14). Obtain review and owner/date records for existing decisions and acceptance conflicts; retire the old deferred-comment proposal. Product CI/runtime work remains separate. |
| [EGA lint — CORENET-7664](https://redhat.atlassian.net/browse/CORENET-7664) | In Progress; today's description already replaces closed-unmerged #11 with draft [#15](https://github.com/openshift/evpn-gateway-appliance/pull/15). Reconcile its combined tool/consumer proposal with the preserved earlier-tool-PR requirement and qualify all original checks; no duplicate description edit. |
| [Upstream triage — ACM-39734](https://redhat.atlassian.net/browse/ACM-39734) | New. The new personal backlog audit skill is read-only and stops at review. It does not deliver this story's continuous incoming GitHub classification/labeling and scrub automation. No completion or retrospective story is proposed. |
| [FBC production URL conversion — ACM-39732](https://redhat.atlassian.net/browse/ACM-39732) | New. The [existing fork candidate and reconciliation requirements](current-work.md#unpublished-tooling-and-stale-roadmap-entries) remain dated implementation leads, not delivered automation. Reconcile current source and actual production scope before implementation/review. |

## Already reconciled; omit from pending writes

* ACM-39728 remains In Progress with updated release evidence, ownership-transfer wording and count cleanup. Its October 13 comment already records merged planning PR #111. Eleven direct children now include ACM-48092; the older ten-child table is historical.
* ACM-34592, ACM-34593 and the 0.24.1 release ACM-40644 are Resolved; CORENET-7171 research is Closed. Remove their old closure-review actions. These are native status observations, not a new independent delivery audit or closure of implementation children.
* ACM-37426 now targets ACM 5.1 in both title and description; ACM-25779 now describes Submariner pipeline migration with its ownership dependency. Their old description-correction proposals are obsolete. Both remain New.
* The production catalog range and EGA lint PR-reference corrections applied today are present in the fresh native descriptions. Historical provisional drafts are not pending operations.

Other active scopes retain existing tracking: MCN implementation (CORENET-7078–7087, CORENET-7089 and CORENET-7173–7199), PQC readiness (ACM-41119), older CVE scope (ACM-26999), and release-tracker children. Their detailed dispositions and assigned/context distinctions remain in the linked historical queue; they were not semantically re-audited here.

## Personal Jira triage skill

[claude-skills #37](https://github.com/dfarrell07/claude-skills/pull/37) merged October 15. Its `personal-jira-triage` helper collects evidence and checks saved packets; it has no writer. Use it for a newly selected personal backlog audit, with exact scope, native evidence and minimal necessary deltas, rather than replaying these archived payloads.

Evidence and collection limits are in the [verification log](agentic-sdlc-jira-updates-verification.md#tracking-and-checkout-reconciliation-october-15); raw captures remain private.
