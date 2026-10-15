<!-- markdownlint-disable MD013 -->

# Jira tracking decisions

Checked October 15, 2026 against native issue fields/comments and related PRs. The [work map](current-work.md) owns engineering handoffs; [audit records](jira-audit-records.md) retain completed-write receipts and the immutable historical payloads. No historical approval batch is a current write request.

## Proposed tracking delta

[ACM-48200 — Add OCP 5.0 FBC catalog](https://redhat.atlassian.net/browse/ACM-48200): one provisional comment should clarify that the proposed pre-GA QE path still conflicts with the pass-before-stage readiness gates. The [rollout plan](ocp-5-0-fbc-rollout.md#2-establish-registry-access-and-determine-whether-installation-will-run) records the source evidence and required reconciliation. Keep In Progress, unresolved, with existing ownership and acceptance unchanged. Posting needs fresh target/operation/visibility evidence and approval; this cleanup does not post it.

## Existing tracking to retain

| Scope | Current disposition |
| --- | --- |
| [Onboarding automation — ACM-48092](https://redhat.atlassian.net/browse/ACM-48092) / [catalog delivery — ACM-48200](https://redhat.atlassian.net/browse/ACM-48200) | Both assigned to the maintainer and In Progress. Their descriptions now separate reusable tooling from actual 5.0 delivery; the automation comment already corrects task-trust wording. Reuse these issues |
| [ART builders — ACM-45318](https://redhat.atlassian.net/browse/ACM-45318) | New, due October 15. Existing planning comment records the inventory. Planning alone does not establish implementation start; retain the [pilot and qualification](art-builder-migration.md) |
| [0.23.4 — ACM-44527](https://redhat.atlassian.net/browse/ACM-44527) | In Progress. Catalog/stage children ACM-44537/44538 are Resolved with completed receipts; QE acceptance and production remain pending. QE child ACM-44539 is still New despite reported test failures; its owner should reconcile that state with the tested-artifact evidence. No duplicate recovery/merge/range comment |
| [Nettest — ACM-48176](https://redhat.atlassian.net/browse/ACM-48176) / [ACM-48194](https://redhat.atlassian.net/browse/ACM-48194) | Both assigned to the maintainer, New. The first reports service-discovery failures; the newer report says discovery works and nettest service deployment fails. Logs and tested digests are needed before diagnosing or calling them duplicates. ACM-48176's description says 0.23.4 while Affects Version says 0.23.2; leave attribution unresolved |
| [0.22.2 — ACM-45070](https://redhat.atlassian.net/browse/ACM-45070) / [EC step — ACM-45075](https://redhat.atlassian.net/browse/ACM-45075) | In Progress. Preserve the completed September EC receipt and later empty progress records. Reconcile intended candidate/bundle/operand identity before selecting a replacement or changing workflow; empty receipts alone justify no rerun |
| [Lifecycle publication — OPGM-364](https://redhat.atlassian.net/browse/OPGM-364) | In Progress. Existing lifecycle-only acceptance permits target publication or IIB/catalog proof without new 5.0 compatibility statements. Neither 4.x no-op execution nor broader runtime qualification substitutes for that proof |
| [Tracker/orchestration — ACM-39730](https://redhat.atlassian.net/browse/ACM-39730) / [ACM-39731](https://redhat.atlassian.net/browse/ACM-39731) | In Progress; merged changes already recorded. Parent-artifact/retarget follow-up belongs here. [Knowledge transfer — ACM-39736](https://redhat.atlassian.net/browse/ACM-39736) remains New until multiple other releasers complete full releases and report gaps |
| [Contributions — ACM-39738](https://redhat.atlassian.net/browse/ACM-39738), [ACM-39739](https://redhat.atlassian.net/browse/ACM-39739), [ACM-39740](https://redhat.atlassian.net/browse/ACM-39740) | New. Shipyard #2582's merge is already recorded; it does not deliver the separate ai-helpers contributions. The generalized agent also needs non-Submariner validation |
| [Kubernetes plugin — CORENET-7155](https://redhat.atlassian.net/browse/CORENET-7155) | In Progress. Preserve the maintainer's design/coverage attribution and original evaluation/qualification/upstream-merge criteria; no retrospective child split |
| [EGA planning — CORENET-7615](https://redhat.atlassian.net/browse/CORENET-7615) / [lint — CORENET-7664](https://redhat.atlassian.net/browse/CORENET-7664) | In Progress. #14 is ready for review; its dated draft wording alone needs no status-only comment. Preserve the current planning acceptance and #15's earlier-tool-PR requirement |
| [Upstream triage — ACM-39734](https://redhat.atlassian.net/browse/ACM-39734) | New. The personal Jira audit skill is read-only; it does not deliver continuous incoming GitHub classification/labeling and scrub automation |

ACM-25779 remains New pending the receiving team's build-catalog ownership decision. ACM-39733 (upstream orchestration) and ACM-39737 (diagnostics approval/workflows) retain their other owners; ACM-39735 (three-bug AI trial) is unassigned. They are related work, not self-assignment proposals. The separate CVE/advisory plan branch needs policy/ownership review and tracking reconciliation in the specialist workflow before implementation; this audit selects no security write.

Original MCN implementation, PQC readiness, older CVE scope and release-tracker children remain separate work. Restricted issues stay in their specialist workflow. Other-owned ART consumption is context, not a reassignment proposal. The optional extra epic deliverable sections remain an unselected scope decision; do not create stories or edits merely to exhaust the historical sequence.
