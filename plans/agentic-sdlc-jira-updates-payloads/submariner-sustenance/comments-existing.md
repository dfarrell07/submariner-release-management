<!-- markdownlint-disable MD013 -->

# Comments for existing ACM-39728 stories (exact payloads)

The first four existing-story comments were posted and verified on October 7, 2026 at 18:23 UTC. The optional URL-conversion comment remains unposted. All comments use visibility `{"type": "group", "value": "Red Hat Employee"}`, as the existing comments do.
The four posted blocks are fixed historical records; keep their text, dates and source pins unchanged. Any later comment is a separately approved missing delta after target-specific preflight.

Historical counts retain their September cutoff; the retarget note is from October 1. Refresh evidence and follow the plan’s preflight for the unposted draft only.

Use one concise comment per target for an approved missing delta. The posted records below do not authorize reposting.

## ACM-39731 (Orchestrate existing release skills into autorelease)

Posted and read back: comment `18820423`; visibility `Red Hat Employee`.

This posted progress update supplemented the conductor/refactor and September 13 comments; it changed no status.

```text
Autorelease updates since September 13:

Another team member has begun using the autorelease tooling.

* [release-management#109](https://github.com/stolostron/submariner-release-management/pull/109) (merged September 29): retry/reuse RPM lockfile PRs, serialize Tekton updates, harden checkout restoration and failure checks, strengthen release-note evidence/resume/apply.
* [release-management#112](https://github.com/stolostron/submariner-release-management/pull/112) (merged): fix cross-branch release status, adjust EC handling of retained BuildPLRInProgress markers, and inspect the Step 11 catalog on main.
* [release-management#113](https://github.com/stolostron/submariner-release-management/pull/113) (merged): parallelize the test hook and remove a repeated live-GitHub lookup from the tests.
* [operator-fbc#83](https://github.com/stolostron/submariner-operator-fbc/pull/83) and [operator-fbc#84](https://github.com/stolostron/submariner-operator-fbc/pull/84) (merged): accept BuildPLRInProgress in catalog updates and retarget 0.23.2 to 0.23.4.
* [release-management#114](https://github.com/stolostron/submariner-release-management/pull/114) remains open: document skipping CVE/upstream-release work when the upstream tag exists and skipping Tekton updates when EC passes, and adjust status/staleness messages. These changes are not on main.
```

## ACM-39730 (Agentic downstream release tracking in Jira)

Posted and read back: comment `18820431`; visibility `Red Hat Employee`.

```text
Tracker fix since the last update: https://github.com/stolostron/submariner-release-management/pull/109 sets the Activity Type field on the tracker parent and its subtasks at creation, addressing the missing-Activity-Type warning. Other required fields and project automation still need verification when a tracker is created.

The tracker is in use for the current Z-streams: ACM-45070 (0.22.2) and ACM-44527 (0.23.4).

The 0.23.2-to-0.23.4 retarget required manual reconciliation of step records, subtask statuses and artifact references against cluster and GitHub evidence. Automated retarget/reconciliation and refresh of the parent’s Key Artifacts remain follow-ups; the current tracker integration records step data but does not refresh that parent section.
```

## ACM-39736 (Release knowledge transfer to team)

Posted and read back: comment `18820438`; visibility `Red Hat Employee`.

This story had no comments before this update. It remains New and requires multiple team members to complete releases.

```text
Team adoption has started: another team member has begun using the CVE and autorelease tooling. Capture feedback from these initial runs as it becomes available.

Shared setup and checkout-safety prerequisites have improved:

* https://github.com/stolostron/submariner-release-management/pull/110 (merged 2026-09-29): one-command setup for the RPM lockfile step's Red Hat entitlements and registry login, using the team's shared credentials, so a new releaser does not need a personal activation key.
* https://github.com/stolostron/submariner-release-management/pull/109 (merged 2026-09-29): worktree and branch-safety hardening, add-team-member hardening, and shared Claude/Codex skill discovery. Installed-host execution remains separate qualification.

Still needed for this story's original acceptance criteria: multiple team members each complete a full downstream release using the skills and workflow docs, with the maintainer available for questions but not driving. Document their gaps and feed them back into skill/doc improvements.
```

## ACM-39729 (Harden autonomous CVE remediation)

Posted and read back: comment `18820449`; visibility `Red Hat Employee`.

Existing comments: 2026-09-04. The Git Pull Request field already lists shipyard#2443, claude-skills#27 and shipyard#2582 (open).

```text
CVE remediation during the September 13–30 reporting window, plus current skill work:

Another team member has begun using the CVE tooling.

* 40 CVE-fix PRs across admiral, cloud-prepare, lighthouse, shipyard, subctl, submariner and submariner-operator on release-0.22, release-0.23 and release-0.24: 23 merged, 17 closed without merging. Plus 3 merged reverts of lint-only changes. [Full PR list](https://github.com/stolostron/submariner-release-management/blob/d094bf36994f5d938f41d4fc305feb93bd896977/plans/agentic-sdlc-jira-updates-payloads/submariner-sustenance/cve-fix-prs.md).
* 259 Vulnerability issues moved to Closed by the maintainer in the same period (Jira: status changed to Closed by the maintainer during September 13–30, currently assigned to the maintainer; rechecked 2026-10-07).
* https://github.com/dfarrell07/claude-skills/pull/35 merged October 6: shipped-image applicability and provenance, source/version mapping, mixed triage outcomes and multi-architecture digest handling. The separate ai-helpers contribution remains ACM-39740 scope.
* https://github.com/submariner-io/shipyard/pull/2582 remains open at 3b67af1a3e9d3d9c9dbee1147b1294bf25879fc4. At the 2026-10-07 18:23 UTC read, hosted checks are still running; the current-head review requests changes, with two unresolved current threads and no current-head approval. The PR’s regression and live OpenShift validation claims are author-reported and were not repeated by this audit. Robustness and daily-use acceptance remain to be reviewed before contribution.
```

The independent [contribution-child comments](../portfolio-comments.md) on ACM-39739/39740 are posted and verified; the ACM-39738 parent rollup remains deferred.
Their source merges are prerequisites; both children still require ai-helpers merges, and ACM-39740 requires non-Submariner product validation.
Use one comment per target, omitting facts already recorded there.

## ACM-39732: optional progress on the existing URL-conversion story

This is not an additional story or part of the four required comments. Re-read the issue and candidate source before posting:

```text
A fork-only candidate at 3cabf0e1f7526d3ef554571ffbb0a95db33bf013 adds scripts/update-fbc-prod-urls.sh plus conductor wiring/tests. It is absent from main, and no PR for its branch was found on October 7.

The candidate assumes one OCP production release establishes all-target completion and does not isolate unrelated/untracked work. Those defects remain before review.
```
