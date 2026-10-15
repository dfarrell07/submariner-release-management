<!-- markdownlint-disable MD013 -->

# Additional existing-issue updates

Historical October 8 payloads. The [current queue](../jira-update-queue.md#approval-order) supersedes the old grouping and pending-action labels. The [completed-write table](../agentic-sdlc-jira-updates.md#a5-execution-order) records October 8 ids; later writes are reconciled in the queue. Posted blocks below are fixed records. Other drafts are not current requests: check live tracking for a useful missing delta before seeking approval. Set `Red Hat Employee` visibility at comment creation.

## Group 1 — CI research handoff

### CORENET-7171 — correct the May handoff

Completed: comment `18824859`, created October 7 at 22:59 UTC with initial `Red Hat Employee` visibility. Approved text, rendered links and unchanged In Progress status were verified. The block below is a fixed posted record; do not repost it. Parent coverage/ownership questions remain in the implementation plan.

```text
Implementation subtasks CORENET-7173 through CORENET-7199 were created on May 20, 2026 and are tracked under CORENET-7086. CORENET-7196/7197/7198 scope AI security/RBAC review and release-note suggestions to post-merge workflows (push to main), correcting the earlier PR-review wording.
```

CORENET-7086: no parent comment proposed. Its hierarchy already exposes the task split; post when there is a concrete implementation or ownership decision.

## Group 2 — CVE contributions (complete)

Both approved child comments were posted and verified October 8 at 11:48 UTC, in the order below, with employee visibility set at creation. Exact ADF/rendered text and each PR link were verified before continuing; prior comments, all other issue fields, hierarchy, changelogs and watch metadata are preserved. Both issues remain New. These are fixed posted records; do not repost them.

### ACM-39740 — CVE-agent contribution

Fixed posted record: comment `18831845`, created October 8 at 11:48:24 UTC. Adoption/remediation progress remains on ACM-39729/39736; include cve-jira-triage dependencies in the contribution’s configuration review.

```text
Preparatory CVE-agent work merged October 6 in https://github.com/dfarrell07/claude-skills/pull/35: shipped-image applicability and provenance, source/version mapping, mixed triage outcomes and multi-architecture digest handling.

Per-product configuration still needs extraction, including component/image mappings, version references, Jira scope and cve-jira-triage dependencies. The ai-helpers contribution and non-Submariner product validation remain unfinished.
```

### ACM-39739 — CVE-fix contribution

Fixed posted record: comment `18831852`, created October 8 at 11:48:51 UTC. September remediation counts and team adoption remain on ACM-39729.

```text
The CVE-fix prerequisite https://github.com/submariner-io/shipyard/pull/2582 remains open. It implements per-repository .cve-fix.yaml overrides, configurable repository registries and Claude/Codex review.

The general contribution still needs to resolve the hardcoded Submariner builder-image fallback for unconfigured Shipyard consumers and merge go-fix-cves into ai-helpers.
```

ACM-39738: no parent rollup proposed. The two child updates are posted; the broader generally relevant skill inventory remains an owner/scope decision in the [queue](../jira-update-queue.md).

## Group 4 — deadline and requested status

Complete: lifecycle comment `18829498` and builder planning comment `18839276` are posted and verified. Both blocks below are fixed posted records; do not repost them. Future comments must add a missing delta. No workflow transition or program label was assigned.

### ACM-45318 — builder migration inventory

Completed: comment `18839276`, created October 8 at 15:37:20 UTC with initial `Red Hat Employee` visibility. Exact ADF/rendered text and the immutable inventory link are verified. New status, criteria, hierarchy and complete history are unchanged. The read-back also reports a populated first-response timestamp and the posting account watching; no separate field or watcher write was performed. This planning comment does not complete the migration.

```text
Prepared a [repository and branch inventory](https://github.com/stolostron/submariner-release-management/blob/123ebebaa7279a5d75b7a3d2626988475d0a8ee8/plans/art-builder-migration.md) for the October 15 ART builder migration. Brew Go-builder references occur in both addon Dockerfiles; all 36 ticket-listed component Dockerfiles across 0.19–0.24 use UBI Go Toolset. The release-management CVE workflow still selects Brew builders.

Remaining work: confirm active build sources, migrate affected addon Dockerfiles and update builder-selection guidance, preserve builder OS/compiler/crypto requirements, and verify OpenShift CI and Konflux pulls plus required platform/runtime checks. Record migration or no-change evidence for every repository before closure. Source and registry checks do not establish a completed migration.
```

### OPGM-364 — requested lifecycle status

Completed: comment `18829498`, created October 8 at 09:37 UTC with initial `Red Hat Employee` visibility. Exact ADF, rendered text/links, unchanged In Progress status and prior comments were verified. The block below is a fixed posted record; do not repost it.

```text
Lifecycle publication is pending. Tenant configuration blocks the build.

Catalog/tooling preparation merged in https://github.com/stolostron/submariner-operator-fbc/pull/81.

Remaining work: reconcile tenant resources, merge lifecycle injection in https://github.com/stolostron/submariner-operator-fbc/pull/82, and release existing valid PLCC data without new OpenShift 5 / 5.0 compatibility statements. Record the release advisory/snapshot/IIB and redhat-operator-index:v5.0 membership or team IIB/catalog proof.

Blockers observed October 7: the published build fails at init for a missing build account; the tenant also lacks the Application and Component. Refreshing GitLab main fails DNS. Registry access remains unverified.
```

## Group 5 — release evidence

Group 5 is partial: the recovery-map comment posted and verified October 8 at 10:43 UTC. The candidate comment remains on hold until its relevance to the intended release is confirmed. Preserve fields/statuses and refresh mutable evidence before any approved post.

### Release Submariner 0.23.4 — recovery map

Completed on ACM-44527: comment `18830594`, created October 8 at 10:43 UTC with initial `Red Hat Employee` visibility. Exact text, rendered link, unchanged In Progress status and all earlier comments were verified. The block below is a fixed posted record; do not repost it.

```text
The [0.23.4 FBC recovery map](https://github.com/stolostron/submariner-release-management/blob/0d23d60a992aeb432a0cd72ad868d256427ce35f/plans/fbc-failure-recovery.md#retained-snapshot-and-scenario-identities) records the snapshot, test scenario and failed run for each OCP version 4.16–4.21.
```

### Release Submariner 0.22.2 — candidate inspection, on hold

Target: ACM-45070. The October 2 candidate is absent from the full release-target histories. Confirm its relevance before proposing this comment for posting; approval of the recovery-map comment does not include this held draft. Inspection does not select or approve a release snapshot. Verify production image identity before advancing EC/bundle steps or parent artifacts.

```text
The October 8 check of snapshot submariner-0-22-20261002-125823-000-lz found passing snapshot integration with warnings and a 0.22.2 bundle. [Evidence](https://github.com/stolostron/submariner-release-management/blob/e2a38ecd219a6c2593431b848ecda30d69aa967b/plans/current-work.md#release-recovery-and-time-sensitive-work).

Production images remain unverified: seven related-image digests differ from the snapshot images, and the referenced operator returns manifest unknown. Different digests alone do not prove incorrect content. Confirm this candidate belongs to the release before using it.
```

## Group 6 — independent epic descriptions (partial)

The [Create agents to automate the bump description](k8s-rebase/epic-and-stories.md#epic-create-agents-to-automate-the-bump-applied) was applied and verified October 8 at 11:23 UTC; do not repeat it. [Submariner Sustenance Automation edits](submariner-sustenance/epic-description-edits.md) remain pending in order 4, 3, 5, then optional 1/2. These edits need no new story keys.

## Group 7 — scope and conditional corrections

The optional [ACM-39732 candidate note](submariner-sustenance/comments-existing.md#acm-39732-optional-progress-on-the-existing-url-conversion-story) belongs here; it is fork-only progress, not shipped functionality.

ACM-26999: no comment proposed. Its May update already records production tooling and the remaining upstream contribution. Resolve its scope/closure disposition before drafting another update.

### ACM-25779 — proposed description correction

This is a replacement description after reviewing the full original ADF; preserve useful existing links and other required fields.
Its May comment already explains deferral, so another copy of that comment is unnecessary.

```text
Complete the agreed Submariner pipeline migration to konflux-build-catalog. Migration instructions: https://github.com/stolostron/konflux-build-catalog.

Addon adoption is recorded in the May comment. Migration of the upstream component repositories and FBC remains pending an ownership/maintenance decision because existing Submariner release automation assumes inline pipelineSpec. Supported branches and the required tooling changes remain to be agreed.
```

### ACM-37426 — OLMv1 target correction

Apply only after the issue owner confirms the July 24 target is still ACM 5.1 (February 2027). Update the title and description together; make no status change or duplicate timeline comment. Save the original ADF, preserve its analysis-document link on `analysis doc` below, and retain other useful reference nodes. Confirm fresh-install/migration scope with the owner; do not silently transfer the old 5.0 contract to 5.1.

* Original title: `Support OLMv1 for Submariner addon in ACM 5.0`
* Proposed title: `Support OLMv1 for Submariner addon in ACM 5.1`

Proposed description:

```text
Submariner addon OLMv1 support targets ACM 5.1 (February 2027), per the July 24 timeline clarification (analysis doc). stolostron/submariner-addon deploys operators on managed clusters via OLMv0 (Subscription + OperatorGroup) and needs to support OLMv1 (ClusterExtension).

The earlier ACM 5.0 analysis scoped fresh installs only and left upgrade migration without a committed timeline. The fresh-install/migration contract for ACM 5.1 remains unconfirmed.

Reference: [MCH#4109](https://github.com/stolostron/multiclusterhub-operator/pull/4109).
```

## Group 8 — new tracking

Approve [ACM stories](submariner-sustenance/new-stories.md) in order S4, S2, S3, S1, S5 and [CORENET stories](k8s-rebase/epic-and-stories.md) separately. Omit epic summaries that repeat the child tracking; status changes require acceptance/workflow review.

## Group 9 — acceptance reviews

ACM-34592 and ACM-40644 retain acceptance-review dispositions in the [queue](../jira-update-queue.md). They have no unconditional closure payload.

### ACM-34593 — original build-failure acceptance review

The September closure request already exists. Add this new build evidence only if not recorded, then separately review the original DNF/RPM criteria and fix attribution before proposing a resolution.

```text
A newer route-agent-0-21 push build succeeded October 2 at source 82adbacdd58e1edaf4c11a8f2d07a94e3b3b84fc: https://github.com/submariner-io/submariner/runs/110847099550. Its retained snapshot is submariner-0-21-20261002-125839-000.

The snapshot's separate EC scenario fails; the successful build supplies build evidence, while compliance remains unresolved.
```

Other release/closure reviews and private security follow-up remain in the [queue](../jira-update-queue.md); no success payload is drafted from Jira status alone.

## Group 3 — EVPN planning handoff

### CORENET-7615 — reconcile planning decisions

Deferred to the end of the queue at the maintainer’s request. October 7 report: another planning PR iteration is WIP and CI PRs will start soon. Refresh this retained draft before review. Group 3: one planning comment, with the merged PR and its substantive discussion linked. Preserve To Do; no related-issue edits, decision-index edits or transitions are authorized.

```text
The delivery plan merged October 1 in https://github.com/openshift/evpn-gateway-appliance/pull/2. The October 1 [review discussion](https://github.com/openshift/evpn-gateway-appliance/pull/2#issuecomment-5936707328) records preliminary artifact-graph review, the OpenShift FRR/frr-metrics choice with planned standalone/EVPN-metrics fixes, and a transit-VIF resolution for CORENET-7501.

The decision index on main still needs these outcomes recorded with owners and dates. Open [appliance PR #6](https://github.com/openshift/evpn-gateway-appliance/pull/6) proposes host-installed FRR for RHEL 10; reconcile it with the recorded payload choice. Product home, Konflux cluster and AMI channel remain pending. Release-gate/responsibility review and owner-attributed recording of the CORENET-7501/7504/7505 criteria resolutions remain unfinished.
```
