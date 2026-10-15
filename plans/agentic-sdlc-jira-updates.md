<!-- markdownlint-disable MD013 -->

# Historical plan: agentic-SDLC Jira epic updates

**Release priority:** [the six 0.23.4 FBC stage candidates are recovered](fbc-failure-recovery.md); actual QE installation is next. Independent deadline work and planning can proceed with their own evidence and approvals.

October 15 reconciliation: the [current queue](jira-update-queue.md) supersedes this plan's proposed approval and creation sequence. The live Submariner description contains edits 1/2 and the main corrections from edits 3/4; edit 5's additional deliverable sections are absent and unselected. OCP onboarding is tracked by ACM-48092; do not create S1 again. The other S/K story splits remain historical proposals, not a requirement to create retrospective stories. No new Jira write batch is selected.

The remaining sections retain their October 8, 2026 cutoff, including then-pending actions and metadata. [Current work](current-work.md) owns engineering handoffs, and the [verification log](agentic-sdlc-jira-updates-verification.md) retains dated evidence. Completed payloads and ids are fixed records. Any useful new delta needs fresh target evidence and its own authorization.

The two epic updates are independent:

| Part | Epic | Project | What it tracks |
| --- | --- | --- | --- |
| A | ACM-39728 "Submariner Sustenance Automation" | ACM | Release, CVE and tooling automation for Submariner |
| B | CORENET-7155 "Create agents to automate the bump" | CORENET | The k8s-rebase plugin for Kubernetes minor-version rebases |

Rules that apply to both parts:

* Approval covers named actions only. Story creation, field edits, comments and transitions require explicit scope; acceptance and resolution remain separate from progress updates. Skip completed deltas.
* Refresh the target, complete paginated comments, mutable evidence and relevant metadata. Before creating stories, search for existing scope beyond the epic. Run one story canary per project and read back every write before continuing.
* Comments add a missing delivery, blocker, correction or requested answer. Link relevant PRs with their merged/open/draft state; use a dated inventory for large batches. Omit repeated criteria and duplicate parent summaries.
* Descriptions, comments and Git Pull Request fields require ADF or a converting client. Preserve unrelated nodes and links; verify text, formatting and exact hrefs after writing. Keep punctuation outside link marks. Append only missing approved PR links.
* Set comment visibility to `Red Hat Employee` in the initial request and verify it. The current comment CLI cannot set that restriction; use REST or a supported UI. Confirm group membership and permissions in preflight.
* Read complete [Story create metadata](https://developer.atlassian.com/cloud/jira/platform/rest/v3/api-group-issues/), target edit metadata and transitions with required fields. The payloads specify project-specific Activity Types, points and sprint rules; verify a new canary's workflow rather than reusing existing transition ids.
* Save each field's live baseline and compare it immediately before writing. Stop on drift or an uncertain response; reconcile Jira before retrying. Restore only while the live field still equals this operation's result, preserving later edits. Issue deletion is outside this plan.
* Keep private security details, internal links and teammate names outside this public repository. Project rules prohibit Jira keys in public PR titles, bodies and commit messages; Jira comments may link to GitHub.

Exact text to post, all under [agentic-sdlc-jira-updates-payloads/](agentic-sdlc-jira-updates-payloads/):

| Part | File | Content |
| --- | --- | --- |
| A | [new-stories.md](agentic-sdlc-jira-updates-payloads/submariner-sustenance/new-stories.md) | Five new child stories with fields, description, acceptance criteria, progress comment |
| A | [comments-existing.md](agentic-sdlc-jira-updates-payloads/submariner-sustenance/comments-existing.md) | Four posted existing-story comments and an optional URL-conversion draft |
| A | [epic-description-edits.md](agentic-sdlc-jira-updates-payloads/submariner-sustenance/epic-description-edits.md) | Five independent old-to-new edits to the epic description |
| A | [shipyard-audit-prs.md](agentic-sdlc-jira-updates-payloads/submariner-sustenance/shipyard-audit-prs.md) | 113 PRs of the Glasswing shipyard-audit remediation, state read 2026-09-30 |
| A | [cve-fix-prs.md](agentic-sdlc-jira-updates-payloads/submariner-sustenance/cve-fix-prs.md) | 43 CVE-related PRs since 2026-09-13 |
| A | [ec-tekton-prs.md](agentic-sdlc-jira-updates-payloads/submariner-sustenance/ec-tekton-prs.md) | 33 Enterprise Contract and Tekton task PRs since 2026-09-13 |
| B | [epic-and-stories.md](agentic-sdlc-jira-updates-payloads/k8s-rebase/epic-and-stories.md) | The fixed applied epic description and five pending child stories with fields and progress comments |

## Part A: Submariner Sustenance Automation (ACM-39728)

The epic is ACM-39728, the Submariner part of the company-wide agentic SDLC effort. It was last updated 2026-09-16 (description) and 2026-09-13 (comments). Most of what has
shipped since is not recorded on it. Part A covers this epic and its children; the [assigned-issue queue](jira-update-queue.md)
covers release-tracker hygiene and other assigned work.

### A1. Current state of the epic and its children (rechecked 2026-10-08)

| Key | Summary | Status | Activity Type | Priority | Has PR links |
| --- | --- | --- | --- | --- | --- |
| ACM-39728 | Submariner Sustenance Automation (epic) | In Progress | Future Sustainability | Undefined | no |
| ACM-39729 | Harden autonomous CVE remediation | In Progress | Security & Compliance | Major | shipyard#2443, claude-skills#27, shipyard#2582 (open) |
| ACM-39730 | Agentic downstream release tracking in Jira | In Progress | Future Sustainability | Major | release-management#89 |
| ACM-39731 | Orchestrate existing release skills into autorelease | In Progress | Future Sustainability | Major | release-management#90-93 |
| ACM-39732 | Create FBC prod URL conversion skill | New | Future Sustainability | Normal | no |
| ACM-39733 | Integrate upstream release into agentic release workflow (assignee: a teammate, not the maintainer) | In Progress | Future Sustainability | Normal | releases#1444 |
| ACM-39734 | Agentic upstream issue and PR triage | New | Future Sustainability | Normal | no |
| ACM-39735 | Evaluate AI-assisted bug fixing | New | Future Sustainability | Normal | no |
| ACM-39736 | Release knowledge transfer to team | New | Future Sustainability | Major | no |
| ACM-39737 | Start PIA approval for automated customer log analysis | New | Security & Compliance | Minor | no |
| ACM-39738 | Contribute Submariner skills to openshift/ai-helpers | New | Future Sustainability | Major | ai-helpers#617 |

ACM-39735 is unassigned and ACM-39737 belongs to a teammate. ACM-39738 has two children not listed above: ACM-39739 (go-fix-cves) and ACM-39740 (generalized CVE agent), both New, with approved contribution comments posted and verified 2026-10-08; the cve-agent PR (claude-skills#35) is relevant to ACM-39740.

Child stories carry the component "Multicluster Networking[ext]" (id 33720), assignee the maintainer unless noted, and the Epic Link field.

### A2. Work to record

| Destination | Evidence and acceptance boundary |
| --- | --- |
| Existing ACM-39729/39730/39731/39736 | CVE tooling and September remediation; tracker fixes; merged conductor hardening and open #114; shared prerequisites; multiple releasers and feedback remain required for knowledge transfer |
| Existing ACM-39738/39739/39740 | Parent covers all generally relevant skills; reconcile that inventory. Open shipyard#2582 and merged cve-agent#35 do not meet either child's ai-helpers merge criterion; ACM-39740 also requires another product's validation |
| S1 | OCP-major FBC onboarding: release-management#109 and FBC#81 merged; pipeline #82 and configuration/build/install/release gates remain. Relate existing OPGM-364 lifecycle work and ACM-45508 addon consumption without claiming their acceptance criteria |
| S2 | Delivered EC deny-rule detection, supported by #109 and the EC/Tekton inventory |
| S3 | Delivered Claude/Codex discovery and compatibility contract; five known overlapping konflux-ci-fix debt entries and installed-host execution remain |
| S4 | Delivered RPM prerequisite setup in #110; multiple team members completing releases and feeding back gaps remain ACM-39736 work |
| S5 | Glasswing shipyard audit: September inventory of 113 PRs, 105 merged. Eight FIND-006 drafts closed unmerged October 3; finding disposition and open OCP helper/upgrade repairs remain |

The September inventories retain their original periods: 40 CVE-fix PRs (23 merged, 17 closed unmerged), three lint-only reverts,
33 EC/Tekton PRs (32 merged), and 259 Vulnerability closures by the maintainer during September 13–30.
The reconstructed epic-period inventory stops at **September 30, 05:00 UTC**: 335 PRs across 12 repositories,
290 merged, 32 closed unmerged and 13 open at that cutoff. Categories are heuristic, recorded per entry in
[epic-period-prs.json](agentic-sdlc-jira-updates-payloads/submariner-sustenance/epic-period-prs.json).
These are historical populations, not today's PR or assigned-issue totals. The [verification record](agentic-sdlc-jira-updates-verification.md)
keeps the source pins and discovery limits; [current work](current-work.md) owns current PR, local-work and release observations.

Routine releases, version labels, bundle updates and release notes stay on existing release trackers.
The [update queue](jira-update-queue.md) handles deadline work, older open items, MCN/EVPN work and terminal issues;
no new umbrella story is proposed for them. Full OCP rollout evidence remains in [ocp-5-0-fbc-rollout.md](ocp-5-0-fbc-rollout.md).

### A3. Decisions to make before executing

1. **Story split.** Recommended: five separate stories (payloads provided), because each is a distinct deliverable with its own status. Fewer stories is possible;
   merge S2 and S3 into one first.
2. **Status of finished stories.** Recommended: Resolved, matching the release-tracker subtasks the tooling already resolves. Closed is the alternative.
   Confirm acceptance criteria and the issue's available transition and resolution fields before deciding; merging a PR alone does not establish every acceptance criterion.
   S3 covers the delivered discovery/compatibility contract; five known `konflux-ci-fix` debt entries and the installed-host matrix remain. Do not report every skill as execution-portable.
3. **Activity Type.** Copied from siblings: Future Sustainability for S1, S3, S4; Security & Compliance for S2 and S5.
4. **0.23.2 (decided 2026-09-30).** It will not ship downstream; it is superseded by 0.23.4, which is in progress. Edit 3 of the epic description drops it, and no 0.23.2 release tracker is needed.
5. **Sprint.** Leave unset, or use an active sprint chosen by the maintainer. On 2026-10-06 the existing In Progress siblings include active
   Submariner Sprint 2026-59 (id 87579); Sprint 2026-58 (id 85613) is now closed and must not be used as the active sprint.

### A4. Preflight for approved actions (stop on any surprise)

Use the [work map](current-work.md) when refreshing payloads: distinguish the closed FIND-006 drafts, open upgrade-test PRs,
known portability debt and time-sensitive builder migration from the September historical counts.

1. Re-read ACM-39728 and its ten children. Compare the table in section A1, especially statuses, child membership, comments and PR links;
   stop and reconcile any new work instead of creating duplicates. Include the two CVE contribution subtasks and search for each proposed deliverable beyond this epic before creation. A sprint update by itself is not evidence that a payload was applied.
2. Before each approved pending epic-description edit, confirm its old snippet or insertion heading occurs exactly once. Reconcile completed edits and omit them; stop on an unexplained difference. Save the current full ADF and update the corresponding nodes, preserving other content and earlier edits.
3. Use section A8 to refresh mutable claims in the approved payload. Retain the verified September inventories and their cutoff; recompute historical totals only to correct or expand that population. If reporting current state, update dates, states and totals together. The 107, 110 and 335 figures are different discovery snapshots, not expected totals for a new search.
4. Confirm #109 and #110 are still merged and 0ed2981 is on main. Also check #112, #113 and #114 (section A11) and claude-skills#35 ([current work](current-work.md#release-tooling-and-jira-payloads)):
   preserve the four posted payloads as historical records. Prepare any newly approved missing delta separately, identifying open work explicitly.
5. Confirm the maintainer's answers to section A3 (the 0.23.2 question is already answered).
6. Reconcile ACM-39738's generally relevant skill inventory with its existing CVE children and CORENET-7155 contribution tracking. Reuse existing issues; propose a subtask only for an uncovered contribution scope.
7. Re-read project create-field metadata and each issue's transition metadata. Confirm the component, Activity Type, priority, assignee, sprint,
   resolution and link type against the current workflow; the read-only review did not exercise any create or transition operation.

### A5. Execution order

Completed writes, reverified October 8. These are fixed records; do not repost or reapply them. Exact payloads remain in the linked payload files, and the [verification log](agentic-sdlc-jira-updates-verification.md) retains receipts and side-effect checks.

| Target | Completed action | Comment id / description changelog |
| --- | --- | --- |
| ACM-39731 | Conductor hardening and initial adoption | 18820423 |
| ACM-39730 | Tracker correction and artifact gap | 18820431 |
| ACM-39736 | Initial adoption and shared prerequisites | 18820438 |
| ACM-39729 | September remediation and CVE tooling | 18820449 |
| CORENET-7171 | CI handoff correction | 18824859 |
| ACM-39740 | CVE-agent contribution evidence | 18831845 |
| ACM-39739 | CVE-fix contribution evidence | 18831852 |
| OPGM-364 | Lifecycle status answer | 18829498 |
| ACM-45318 | Builder migration planning | 18839276 |
| ACM-44527 | 0.23.4 recovery map | 18830594 |
| CORENET-7155 | Epic description | 92306194 |

The [current queue](jira-update-queue.md#approval-order) supersedes the historical sequence below. Do not replay the epic edits or create S1: edits 1/2 and the main corrections from 3/4 are present, edit 5 is unselected, and ACM-48092 tracks onboarding. Fixed October 8 receipts above do not enumerate later writes.

After story split and fields are approved, create S4 → S2 → S3 → S1 → S5. CORENET creation is separate. No duplicate epic summary is proposed.

Each creation or field write is read back before the next. Skip completed deltas.

1. **Canary: create story S4** (RPM lockfile setup) using the fields in new-stories.md: ACM Story, the maintainer's account, parent ACM-39728,
   component 33720, priority 10002 and Activity Type 10606. Story create metadata marks reporter required with a default; preserve the approved reporter and verify it on read-back. Use the approved Jira client/UI and its supported description format.
   Read it back and check the parent, fields, italic headings and bullets. If the workflow requires legacy Epic Link instead of `parent`, use
   `customfield_10014` only after create-field metadata confirms that field is writable.
2. **Canary: Git Pull Request field.** Confirm S4's edit metadata and client support before appending the #110 link to `customfield_10875` as ADF.
   Read back the full field and confirm its links and formatting. If unsupported, use the comment-only route; omit subsequent PR-field edits.
3. **Canary: restricted progress comment.** Post S4's progress comment with restricted visibility set at creation. Verify text, clickable links and visibility before creating another story.
4. Create S2, S3, S1, S5 using each story's own fields in new-stories.md. S2 and S5 use Security & Compliance (10609); S3 uses Normal priority (10003).
   Read back each creation and record its key. Complete that story's approved field/comment writes and read-backs before creating the next.
   Append its proposed PR links only if step 2 passed and its own edit metadata confirms support; read back each field. S5 proposes no PR-field edit.
5. Move S1/S5 to In Progress only if those transitions were included in the approved group, using each new issue’s metadata and read-back. Keep S2/S3/S4 in their created status until the separate group-9 acceptance review approves a terminal transition and its resolution; do not resolve them as part of story creation.
6. Add related-issue links from S1 to ACM-45508 (addon consumption) and OPGM-364 (lifecycle publication), using the link type confirmed in preflight. Check for an existing link first and read back each new relationship.
7. The four existing-story updates are already posted (ids above); reconcile their read-backs and post only newly approved missing deltas. Optionally append the #109 link to the
   Git Pull Request field of ACM-39731 and ACM-39730 only after step 2 passes. Re-read the original ADF, add only missing link nodes and set the combined document; the field exposes `set`, not an `add` operation. Verify that every original link survives and stop if the baseline changed.
8. Apply only approved epic description edits not already performed in group 6, verifying each by read-back; omit completed deltas.

### A6. Verification and rollback

* After each write, read the issue back and compare to the payload. Do not batch writes without reading back.
* A supported Jira client/UI can edit or delete comments if the account has permission. Save each created comment id; REST comment updates use the
  [update-comment operation](https://developer.atlassian.com/cloud/jira/platform/rest/v3/api-group-issue-comments/#api-rest-api-3-issue-issueidorkey-comment-id-put), not add-comment.
  No issue-deletion operation is authorized by this plan; a mistaken story needs a separate disposition decision. That is why one story is created first as a canary.
* Save the full current ADF before each independent description edit. Apply the shared baseline/rollback rule above so earlier approved edits and later changes survive; issue history provides no automatic restore operation.
* Do not put Jira keys in the titles or bodies of upstream GitHub PRs (project rule); Jira comments may link to GitHub, not the reverse.

### A7. Work outside these epic payloads

Use the [assigned-issue queue](jira-update-queue.md) for release closeout, lifecycle publication, builder/PQC/OLMv1 work,
older onboarding/CVE/release items, MCN CI research and EVPN acceptance. It distinguishes review-ready text from blocked status changes.
The addon's configured CVE-agent binary path still needs separate verification: the previous shipped-image audit found `/submariner`,
while component-modules.json configured `/usr/local/bin/submariner`. This finding was not part of merged cve-agent#35;
do not infer complete addon scan coverage from that merge.

### A8. How the numbers were produced

```bash
# Discover PRs created in the September reporting window.
# Review repository and theme membership before counting; this is an author-wide search.
gh search prs --author dfarrell07 --created '2026-09-13..2026-09-30' --limit 1000 --json repository,number,title,state,url

# Discover PRs created since the epic began, up to the same cutoff.
gh search prs --author dfarrell07 --created '2026-08-04..2026-09-30' --limit 1000 --json repository,number,title,state,url

# Glasswing shipyard-audit PRs: the stored list has 113 URLs; state of each from the API.
rg -o 'https://github.com/[^ )]+/pull/[0-9]+' plans/agentic-sdlc-jira-updates-payloads/submariner-sustenance/shipyard-audit-prs.md | sort -u
# Substitute owner, repo and n from each URL before running this template.
gh api 'repos/<owner>/<repo>/pulls/<n>' --jq '[.merged, .state, .created_at, .base.ref]'

# Historical repo-size audit baseline (not today's main).
git ls-tree -d --name-only 0ed2981 skills/ | wc -l
git ls-tree -r --name-only 0ed2981 scripts | rg '\.(sh|py)$' | wc -l
```

Jira discovery query for Vulnerability issues the maintainer closed during the reporting window:

```jql
project = ACM AND issuetype = Vulnerability AND status changed TO Closed BY currentUser() DURING ("2026-09-13 00:00", "2026-09-30 23:59") AND assignee = currentUser()
```

GitHub search returns current states; a closed result does not distinguish merged from closed without merging. Read each pull request's `merged` field
with the API before classifying it. The 107 and 110 searches were taken at different times on September 30; a date-bounded query now can include PRs
created later that day. The 335-PR inventory is now included, with an explicit 05:00 UTC cutoff. A full September 30 query also finds later PRs, so filter
creation and lifecycle timestamps to that cutoff before comparing totals. The bounded JQL above returned 259 issues on 2026-10-06,
matching the original unbounded `AFTER` query; no private issue export is included. Run it as the maintainer, or substitute that account for `currentUser()`.

Do not use a full-text `gh search prs "FIND-"` to count the audit PRs: it is a fuzzy search and matches unrelated PRs from years earlier.

### A11. Release retarget and current handoff

The 0.23.2 release was superseded by 0.23.4. On September 30/October 1 a separate operation reconciled ACM-44527's stale
step records, subtask statuses and artifact descriptions against cluster/GitHub evidence. Those tracker writes did not apply these epic payloads.
Merged release-management#112/#113 and FBC#83/#84 are evidence for the existing ACM-39731 comment;
release-management#114 remains an open proposal and is absent from main.

Both epics remain In Progress; ACM has ten direct children and CORENET has none. The Kubernetes description is applied; Submariner edits remain pending.

[Current work](current-work.md) owns release state and configuration drafts. [FBC recovery](fbc-failure-recovery.md) owns the six failed snapshot/scenario associations and credential/content prerequisites. Its archived component-stage success does not complete FBC; later NotFound reads do not erase that evidence. No fresh cluster or registry qualification is supplied by this Jira review.

## Part B: k8s-rebase automation (CORENET-7155)

The epic is CORENET-7155, "Create agents to automate the bump". It covers the k8s-rebase plugin built for the openshift-eng/ai-helpers marketplace. Prepared from a read of
the epic, related CORENET issues, the GitHub pull request, the maintainer's downstream PRs and the local clone of the plugin. Payloads are in
[agentic-sdlc-jira-updates-payloads/k8s-rebase/](agentic-sdlc-jira-updates-payloads/k8s-rebase/).

### B1. What the epic looks like today (verified after the 2026-10-08 edit)

* CORENET-7155, Epic, In Progress, assigned to the maintainer, reporter a CoreNet teammate. Created 2026-05-19, updated 2026-10-08. Priority Normal, Activity Type
  Product / Portfolio Work, no components.
* **Description: applied and verified October 8 at 11:23 UTC, changelog `92306194`. Child issues: none.** It is in the active sprint "CORENET Sprint 295" and earlier sprints 289 to 294.
* Six comments, all between 2026-06-04 and 2026-06-12: a link to the work-in-progress branch and its results, progress on other repos, links to the first automated PRs, and a
  discussion of one dependency issue with a teammate.
* Git Pull Request field: openshift-eng/ai-helpers#617.
* Linked (link type "Account") to CORENET-6983, the Kubernetes 1.36 rebase epic for the CoreNet repos (Release Pending), most of whose stories are assigned to CoreNet teammates. CORENET-7062
  under it, the ovn-kubernetes-mcp bump, was assigned to the maintainer and closed on 2026-07-24 because the agent's PR merged.

### B2. Development evidence and remaining acceptance

The October 8 maintainer clarification credits the entire design to the maintainer: the original epic supplied only a title, with no specification. The plugin is reported fully working across all six CoreNet repositories on Kubernetes 1.34.1, 1.35.3 and 1.36.2, and now working for 1.37. That functional progress and original design credit are now recorded in the approved epic description; retained qualification evidence, measurement and upstream merge remain separate acceptance work.

The [payload evidence](agentic-sdlc-jira-updates-payloads/k8s-rebase/epic-and-stories.md) and [verification record](agentic-sdlc-jira-updates-verification.md#kubernetes-rebase-evidence)
retain the pinned bak42 development counts and historical PR inventory. The October 8 PR head is `1a33dafe`, matching October 7 committed plugin source except two court-test files; source publication supersedes the old unpublished-work conclusion. Fresh source/runtime qualification remains required.

| Destination | Evidence and remaining acceptance |
| --- | --- |
| K1 | Maintainer-originated architecture and implemented five-step plugin; reported working coverage is recorded above. Published source at 1a33dafe needs its own retained qualification evidence |
| K2 | Maintainer reports working coverage of all six repositories across the three earlier versions. Six June 1.36.2 PRs and 108 July draft PRs are historical evidence; retained per-run archives/failure dispositions remain separate closure work |
| K3 | Sixteen eval cases and a metrics runner; valid measurements, judge outcomes and an answer to the reviewer's measurement/shared-harness question remain |
| K4 | Maintainer reports the plugin now working for 1.37. Recorded CNCC/Multus/MCP 1.37.1 trials retain their dated limits; qualify the exact current source/runtime separately |
| K5 | #617 remains draft with invalid-OWNERS/needs-ok-to-test labels; review the full delta, resolve blockers, obtain approval and merge |

### B3. Things to know before touching Jira

Preserve and qualify the exact published source selected for review. October 7 local source and backup counts remain historical; this review does not inspect or execute the plugin checkout. Follow the [CORENET payload conventions](agentic-sdlc-jira-updates-payloads/k8s-rebase/epic-and-stories.md) for original points, sprint and post-create PR-field edits.

### B4. Decisions to make first

1. **Story split.** Recommended: five stories (plugin, qualification runs, evals, Kubernetes 1.37, upstreaming). Fewer is possible; merge K3 into K1 first.
2. **Story points** for each story (the automation needs a value; CORENET-7062, a one-repo bump, used 1). Placeholders in the payload file.
3. **Sprint:** add the stories to the active "CORENET Sprint 295" (recommended, the epic is already in it), or another.
4. **Status of K2:** In Progress pending its own 1.36.2 acceptance review. Recover per-target qualification and failure dispositions, or agree explicit limits; the July PR inventory and legacy PASS summaries do not justify closure. K4's 1.37 work has separate criteria.
5. **July inventory:** report 108 closed draft PRs. Do not equate one PR with one independently qualified run; source/gate/result evidence is separate.
6. **K4 acceptance boundary.** Retained CNCC, Multus and MCP 1.37.1 trials exist, with the [recorded limits](current-work.md#kubernetes-plugin-qualification-and-publication). Keep K4 In Progress until its own criteria pass on the selected source/runtime.

### B5. Preflight for approved actions (stop on any surprise)

1. Re-read CORENET-7155 and its children. Reconcile any description or stories with recorded approved writes; omit completed actions and stop on unexplained differences. The description is already applied, and the verified child list is empty; preserve the completed edit.
2. Refresh current PR/run claims used by the approved payload. Section B8 records the historical counting method; retain the verified bak42 snapshot and its dates. Refresh dates and counts together when reporting current work; do not expect mutable HEAD or review totals to equal the historical snapshot.
3. Confirm the maintainer's answers to section B4. Refresh local source/backup observations used by the approved payload and record unfinished qualification or backup gaps as blockers.
4. Confirm the story-point scale and the sprint id with the team.
5. Re-read Story create metadata and available transitions. The October 7 metadata exposes `parent`, not legacy Epic Link, on CORENET creation; Original story points and Git Pull Request require later edits. `Related` is currently link type 10077. Confirm the new canary's edit metadata and rich-text handling before continuing.
6. Reconcile K2/K4 qualification scope with existing delivery epics CORENET-6983 and CORENET-7450 and their children. K stories qualify the plugin; they do not recreate repository bumps or change those other-owned delivery issues.

Before authorized plugin changes or publication, preserve and verify committed and dirty work. Before fresh qualification, freeze the intended source, compare loaded skill/hook bytes and retain the original trial budgets/reports. These engineering actions require their own scope; Jira tracking can record the unfinished work.

### B6. Execution order

The epic description was applied and verified independently in group 6. The sequence below handles separately approved K-story creation; preserve the completed description edit.

1. Create K1 as a canary with writable create fields: `parent` CORENET-7155, its own Activity Type/priority, approved Story Points and sprint, assignee and description. Verify the default/approved reporter on read-back. CORENET create metadata does not expose legacy Epic Link, Original story points or Git Pull Request; do not send those fields in the create request. Read back membership and rendered content.
   Fetch K1 edit metadata, then set approved Original story points and read it back. Existing Story edit metadata supports that field, but the new canary must confirm it. Do not transition to In Progress until it is set and verified; do not silently omit the automation prerequisite.
2. Append K1's PR link only after its edit metadata confirms support; use an ADF-capable client and read back the full field. If the field/client is unsupported, use the comment-only route and omit subsequent PR-field edits.
3. Post K1's progress comment with restricted visibility set at creation. Verify text, clickable links and visibility before creating K2–K5.
   Create each remaining story with its own writable fields; inspect its edit metadata, set Original story points and verify both point fields and sprint. Complete its approved field/comment writes and read-backs before creating the next.
   Append proposed PR links only if K1's field canary passed and that issue's edit metadata confirms support; read back each field. K3/K4 propose no PR-field edit.
4. Add the related-issue link from K2 to CORENET-7062 using the link type confirmed in preflight, and read it back.
5. Transition K1–K5 to In Progress only if included in the approved group, after the approved field setup. A separate K2 closeout requires its own qualification/failure-disposition evidence and the appropriate resolution.
   Read each issue's available transitions, verify points and sprint first, and read each transition back; do not reuse ACM transition ids.
6. Preserve the recorded approved epic description; omit its completed group-6 edit. Reconcile any later live change before proposing another edit.

### B7. Verification and rollback

* Read each issue back after writing and compare with the payload before continuing.
* Comments can be edited by id with a supported client/UI; issue deletion is outside this plan, which is why one story is created first as a canary.
* The description was empty before the approved October 8 edit. Its full pre-write baseline and read-back are retained privately. Apply the shared baseline/rollback rule before any restoration; restore only if the live field still equals the recorded approved result, preserve later edits, then read it back.

### B8. How the numbers were produced

The [verification log](agentic-sdlc-jira-updates-verification.md#kubernetes-rebase-evidence) records the pinned bak42 source/counts, six June PRs and 108 July drafts. Counts describe their dated populations. Current PR state and source comparisons belong to [current work](current-work.md#kubernetes-plugin-qualification-and-publication); rewritten history requires file comparisons rather than ancestry counts.

### B9. Corrections made while preparing this plan

Bak42 was already backed up on the fork. The October 8 publication supersedes the earlier unpublished-source gap. The epic description is now applied; the child stories remain uncreated. Earlier findings and their cutoffs remain in the verification log.
