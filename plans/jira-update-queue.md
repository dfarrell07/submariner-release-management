<!-- markdownlint-disable MD013 -->

# Assigned Jira work: update queue

Verified October 8, 2026. This queue accounts for all 76 active assigned non-Vulnerability issues; private security follow-up remains separate.

Next review: **Submariner description edits 4 → 3 → 5**, then optional 1/2. Ten comments and the Kubernetes description are complete; [verified ids](agentic-sdlc-jira-updates.md#a5-execution-order). The 0.22.2 candidate note remains on hold; EVPN is last. Re-read each approved target and omit completed deltas.

[Current work](current-work.md) owns engineering evidence; the [epic plan](agentic-sdlc-jira-updates.md) owns creation and field procedures; [portfolio payloads](agentic-sdlc-jira-updates-payloads/portfolio-comments.md) contain exact existing-issue drafts.

## Approval order

Table rows set approval priority; group identifiers stay fixed. Use this order for the remaining Jira work. Start with small comments supported by established records, then handle mutable release evidence, description changes, new tracking and acceptance reviews. Each group is a separate approval chunk; approval of one does not authorize the others. The four earlier ACM comments, groups 1 and 2, both comments in group 4, the recovery-map comment in group 5 and the Kubernetes epic description in group 6 remain completed.

| Group | Work | Targets, in order | Why here / boundary |
| --- | --- | --- | --- |
| 1 (complete) | CI research correction | CORENET-7171 | Posted and verified comment 18824859; parent comment remains deferred |
| 2 (complete) | CVE contributions | ACM-39740 → ACM-39739 | Posted and verified comments 18831845 and 18831852; both remain New; parent rollup deferred |
| 4 (complete) | Deadline and requested status | OPGM-364 → ACM-45318 | Posted and verified lifecycle comment 18829498 and builder planning comment 18839276. The builder remains New; migration/source/CI/runtime qualification remains engineering work |
| 5 (partial) | Release evidence | Release Submariner 0.22.2 (ACM-45070), on hold | Recovery-map comment 18830594 posted on Release Submariner 0.23.4 (ACM-44527). Confirm candidate relevance before proposing its comment for posting; no selection or step transitions |
| 6 (partial) | Independent epic descriptions | Submariner Sustenance Automation (ACM-39728) edits 4 → 3 → 5; optional metrics cleanup 1/2 | Create agents to automate the bump description applied and verified, changelog 92306194. Submariner edits need separate approval; preserve unaffected ADF. Qualification remains required |
| 7 | Scope and conditional corrections | ACM-25779; ACM-37426; optional ACM-39732 | Owner decisions gate descriptions; fork-only progress is optional. Older CVE scope remains deferred |
| 8 | New tracking, by epic | ACM stories S4 → S2 → S3 → S1 → S5; CORENET stories K1–K5 separately | Approve splits/fields and any In Progress transitions; complete project field/comment canaries before further creations; omit duplicate epic summaries. Terminal transitions wait for group 9 |
| 9 | Acceptance and closure reviews | ACM-34592; ACM-34593; ACM-40644; any proposed finished-story transitions | Original criteria, attribution, artifact/QE proof and workflow required; no automatic closure |
| 3 (deferred) | EVPN planning handoff | CORENET-7615 | Last at maintainer request; another planning PR iteration is WIP and CI PRs will start soon. Refresh the draft when reprioritized |

Exact existing-issue drafts follow the same grouping in [portfolio-comments.md](agentic-sdlc-jira-updates-payloads/portfolio-comments.md). The [epic plan](agentic-sdlc-jira-updates.md) owns creation/field procedures; the [verification record](agentic-sdlc-jira-updates-verification.md) owns the dated evidence. Refresh only the targets and prerequisites of the approved group before writing; omit facts already present and verify restricted visibility/text/links afterward.

FBC recovery, the four private CVE cases and October 15 builder work retain their engineering priority and can proceed alongside this comment queue. Deferred, terminal and other-owned work below remains outside the posting sequence.

## Coverage

The unrestricted, paginated `assignee = currentUser()` search returned **703 unique issues across nine projects**:
80 active, 623 terminal. Of these, 483 are Vulnerability issues: four active and 479 terminal.
The latest non-Vulnerability refresh read 228 full documents: all 220 other assigned issues plus eight related targets. The four active private vulnerabilities were inspected in the earlier comprehensive sweep.
The pre-posting refresh found assigned keys/statuses, inspected scope fields and complete target comment histories unchanged.
The tables below account for **all 76 active non-Vulnerability issues**. Terminal issues default to no update.
The September 13 onward non-Vulnerability update search returned 118 issues, including 53 terminal ones;
an `updated` timestamp alone does not establish new engineering work.

Private vulnerability keys, issue contents, personal research exports and teammate identities remain outside this public repository.
Full views of the four active vulnerabilities were re-read privately. Per-image/version applicability, fix and closure evidence remain in their existing private workflow.
Neither the historical 259 closures nor a merged tooling PR authorizes closing them. The other 479 need no new bulk comment or transition.

## Submariner automation and contribution issues — 10

| Issue | Proposed update | Completion/status boundary |
| --- | --- | --- |
| ACM-39728 | Apply reviewed description edits independently; defer a duplicate child-tracking summary | Keep In Progress; preserve original ADF and verify each approved edit |
| ACM-39729 | Posted comment 18820449: September remediation, merged CVE-agent work, open CVE-fix work and initial teammate adoption | Do not equate tooling merges or issue counts with complete remediation |
| ACM-39730 | Posted comment 18820431: Activity Type fix and observed retarget/artifact gaps | Parent artifact refresh/retarget automation remains a follow-up |
| ACM-39731 | Posted comment 18820423: merged hardening, open #114 and initial teammate adoption | #114 is pending, not shipped |
| ACM-39732 | Record the existing fork-only URL-conversion candidate if useful | New; source/scope reconciliation before a review PR; no additional story |
| ACM-39734 | Defer | No new triage implementation evidence found; avoid an empty progress post |
| ACM-39736 | Posted comment 18820438: initial teammate adoption and shared setup prerequisites | New; multiple team members must each complete a release, with the maintainer not driving; document gaps and feed them into improvements |
| ACM-39738 | Defer a duplicate child-progress rollup; settle the broader contribution inventory | New; original acceptance covers all generally relevant skills. Reconcile that inventory; neither two CVE children nor an open plugin PR establishes parent completion |
| ACM-39739 | Posted comment 18831852: implemented project config, registries and Claude/Codex review in open shipyard#2582 | New, unchanged; unconfigured Shipyard builder fallback and ai-helpers merge remain |
| ACM-39740 | Posted comment 18831845: source #35 merge and agent/triage configuration gaps | New; per-product configuration, ai-helpers merge and validation on another product’s CVE issues remain. Initial team adoption does not satisfy these criteria |

The first four posted existing-story updates and optional URL-conversion draft are recorded in
[comments-existing.md](agentic-sdlc-jira-updates-payloads/submariner-sustenance/comments-existing.md).
The two contribution-child comments are posted and verified independently of S-story creation; no parent rollup is proposed. Keep ACM-39733 with its existing owner;
ACM-39735 is unassigned and ACM-39737 belongs to another owner. No status or comment is proposed for those three here.

## Releases — 17

| Assigned issues | Proposed treatment | Evidence needed before changing status |
| --- | --- | --- |
| ACM-40644 | Closure review; all 15 children terminal, parent In Progress | Exact production bundle is verified. Seven 4.16–4.22 index probes timed out and historical Release CRs are NotFound; recover catalog/QE proof and compare all 159 comments before closeout. Neither failure proves absence |
| ACM-44527; ACM-44537, ACM-44538, ACM-44540, ACM-44541, ACM-44542 | Recovery-map comment 18830594 posted; change individual steps only as recovery progresses | Catalog In Progress; stage/prod/URL steps New. Six exact FBC snapshot/scenario associations are recovered, all aggregate Failed; use the recovery map and verify credentials/content before reruns |
| ACM-45070; ACM-45075, ACM-45077, ACM-45078, ACM-45079, ACM-45080, ACM-45081, ACM-45083, ACM-45084, ACM-45085 | Reconcile candidate source/operand identity before accepting EC/bundle and filling parent artifacts | Unselected nine-component candidate passes integration with warnings and contains a 0.22.2 bundle. Seven embedded operand digests differ from snapshot operands; registry/content identity remains unverified. EC/bundle stay In Progress; stage onward New |

QE subtasks retain their existing owners and are dependencies, not assigned work in these totals.
ACM-45087/45088 are two extra test subtasks under the 0.22.2 parent; their disposition is separate from release completion.
Do not use broad closeout to resolve them as release deliverables. A tracker close command can change Jira and needs explicit write authorization.

## Deadline, lifecycle and older open work — 8

| Issue | Proposed update | Gate or reason to defer |
| --- | --- | --- |
| ACM-45318 | Posted planning comment 18839276; retain October 15 deadline | Use [builder inventory](art-builder-migration.md): 137 canonical refs across nine repos. Confirm all active build sources; cached 5.1/5.2 builds select main, matching their filters. Migrate both used Brew Dockerfiles while preserving OS family; current Go 1.25 has a matching RHEL8 ART candidate. Verify both CI pull paths and image checks, output-binary compiler settings and required FIPS runtime behavior. Bind platform evidence to published child digests; update Brew-selecting CVE guidance, retain addon propagation and record each repo/source disposition. Source tests alone do not qualify the output image; UBI Go Toolset alone does not establish ART consumption |
| ACM-41119 | Defer completion; reconcile image coverage with builder work | Addon 5.0 PQC base selection is partial source evidence; main/5.1 differ and shipped-image policy remains unverified |
| ACM-37426 | Coordinated title/description timeline correction using the prepared draft after owner confirmation | Description says ACM 5.0; July comment says 5.1. Prototype manifests exist, with incomplete least-privilege RBAC; preserve that preparation without claiming implementation |
| OPGM-364 | Status answer posted and verified as comment 18829498; add only a missing new delta | Lifecycle injection and publication are existing scope. It explicitly forbids adding OCP 5 compatibility statements; a valid catalog/IIB proof is an allowed alternative to public-index membership |
| ACM-25779 | Replace the stale console-specific description with the actual Submariner pipeline scope | Existing May comment already explains ownership-dependent deferral. Do not repost it or treat inline pipelines as an unrecorded failure |
| ACM-26999 | Defer another progress comment; reconcile older CVE scope with ACM-39729/39739/39740 | The May comment already records production tooling and remaining contribution. Closure/supersession needs a scope decision |
| ACM-34592 | Closure review with existing five PRs | All five directly read PRs merged May 28. Parent ACM-34591 is Closed and the comment asks for closure; review issue criteria and current transition/resolution before resolving |
| ACM-34593 | Closure review of the original build failure | October 2 route-agent push build succeeds at 82adbacd; retained snapshot exists, while its EC scenario fails. Confirm the original DNF/RPM criteria and fix attribution before resolving; EC failure is a separate investigation |

ACM-45508 is a related addon-consumption task owned by another person, not an assigned issue.
Link it from S1 where useful; it does not prove FBC runtime compatibility. OPGM-364 also predates S1:
reconcile/link its lifecycle scope instead of creating another publication story.

## Kubernetes and MCN/EVPN work — 41

| Assigned issues | Proposed update | Gate or reason to defer |
| --- | --- | --- |
| CORENET-7155 | Description applied and verified, changelog 92306194; K-story creation remains pending; defer duplicate summary | In Progress, no children. Records original design credit and reported working coverage; qualification, measurement and upstream merge criteria remain |
| CORENET-7086 | Defer a parent comment until a concrete implementation or ownership decision | To Do; task membership is already visible. Header/API coverage and GHA/Prow scope remain implementation questions |
| CORENET-7171 | Posted comment 18824859: May task creation and post-merge AI scope | In Progress, unchanged. Review the original research/rationale deliverable; implementation tracking does not establish research acceptance |
| CORENET-7173–7199 | Defer individual comments; retain one disposition per existing subtask | All 27 To Do. Existing descriptions cover lint, security, test, coverage, context and AI workflows. Require repository change and meaningful CI evidence for each criterion before any completion claim |
| CORENET-7078, CORENET-7079, CORENET-7080, CORENET-7081, CORENET-7082, CORENET-7083, CORENET-7084, CORENET-7085, CORENET-7087, CORENET-7089 | Defer until repository/build/registry/CI ownership and prerequisites are agreed | All ten To Do under existing MCN scope; source bootstrap, Prow/cloud E2E, image publishing and release automation are distinct deliverables |
| CORENET-7615 | Group 3 deferred to the end: another planning PR iteration is WIP; CI PRs will start soon (maintainer report). Refresh the handoff before review | To Do / no comments. Discussion records the FRR/exporter choice and transit-VIF resolution, but the published decision index remains unreconciled. Record existing outcomes with owners/dates and reconcile open #6’s host-FRR proposal with the recorded image choice; complete release-gate/responsibility review or requested changes. Pending decisions need not all be settled. Imports and CI remain separate |

Do not duplicate the 27 CI subtasks from the May research drafts or post the same research list on each one.
Do not close CORENET-7171 solely because the subtasks exist. Do not reuse EVPN or plugin qualification as MCN implementation evidence.
CORENET-7085 and CORENET-7089 have empty descriptions: scope test reuse and release/versioning after repository ownership is agreed.
The parent also requires license-header verification and API compatibility. The linked proposal already recommends goheader, crdify and go-apidiff; reconcile explicit implementation coverage within existing tracking. CORENET-7195's dependency-license scanning and CORENET-7174's API conventions do not establish those criteria. The proposed GHA/Prow split needs alignment with CORENET-7083's presubmit/postsubmit/periodic jobs and CORENET-7087's Prow image builds.

## Recent work and terminal issues

The author-wide GitHub sweep returned 23 PRs updated since September 30 and 16 currently open PRs, plus five recently updated issues.
Direct reads distinguish merge/closure, current heads, review state and checks. These populations overlap and are not additive.
The important active work is already mapped above or in [current work](current-work.md): release recovery, OCP 5 #82,
conductor #114, CVE #2582, upgrade #2654/#1944, helper pod #2618, addon #2792 and plugin #617.
Open release-management #111 is this planning work, not a shipped automation deliverable.

Older threat-model PR #186 and six personal documentation PRs also remain open. The corresponding assigned threat-model issues are terminal;
no new assigned-issue completion/update is inferred from these stale PRs. Review their remaining purpose separately before any closure action.
The terminal assigned history across ACM, CORENET and seven other projects needs no retrospective progress spam or reopening.
Resolved recent release steps stay as evidence on their parents; routine timestamp changes do not justify reposting the inventory.

## Apply a reviewed update

Re-read the target's description, complete comments, PR field, parent and available transitions; preserve the original rich text.
Post only a missing delivery, blocker/evidence, correction or answer to an explicit request. Keep audit instructions and repeated criteria in this plan; omit duplicate rollups. Set comment visibility `Red Hat Employee` at creation and verify it on read-back.
Descriptions/PR fields need ADF or a converting client. Read back each write and record its issue/comment id before continuing.
Status reviews are separate from comments and require acceptance evidence, resolution metadata and any project points/sprint requirements. Live metadata confirms required resolution on terminal transitions; the existing closure candidates remain reviews, not approved transitions. CORENET Original story points/PR fields need post-create edits; see the epic plan.
No branch push, PR update, Jira write, cluster change or release is authorized by this planning document.
