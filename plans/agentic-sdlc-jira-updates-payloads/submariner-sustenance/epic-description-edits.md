<!-- markdownlint-disable MD013 -->

# Epic description edits: Submariner Sustenance Automation

Target: ACM-39728. All five edits remain pending. The October 8 full ADF/history/metadata read confirms all seven old paragraphs and the insertion heading match exactly once. Review in order **4 → 3 → 5**, then optional 1/2; no new story keys are needed.

Each edit is independent. Use visible text and ADF structure; Markdown markers below are presentation. Before each approved write, save and recheck the live ADF, then rebuild the request preserving unrelated nodes and earlier edits. Stop on drift; restore only while the live field equals that edit's result, preserving later changes. Issue history is not an automatic restore operation. Follow the [shared write rules](../../agentic-sdlc-jira-updates.md).

## Edit 4: release ownership transfer

Old (replace this paragraph under "Release ownership transfer"):

```text
Currently only one engineer can execute downstream releases. The goal is for any team member to be able to pick up a release branch and drive the full downstream release process. The skills and context docs encode the knowledge, but this hasn't been validated yet.
```

New:

```text
Another team member has begun using CVE and autorelease tooling. Ownership transfer still requires multiple team members each to complete a downstream release without the maintainer driving, with gaps documented and fed back into improvements. RPM lockfile prerequisites can be set up with make setup-entitlements using shared team credentials.
```

## Edit 3: release automation and evidence

Replace all four related claims below together. Correcting only the production bullet would leave the repeated validation and apply-only gate claims. The maintainer decided September 30 that 0.23.2 will not ship downstream; 0.23.4 supersedes it.

### Lifecycle introduction

Old:

```text
The 20-step Konflux release lifecycle, automated end-to-end over 10 months:
```

New:

```text
Automation for the 20-step Konflux release lifecycle:
```

### Conductor bullet

Old:

```text
Autorelease conductor (shipped Aug 2026): chains all automated steps with human gates only at destructive apply points. Any team member can drive a full release. Jira release tracker gives stakeholders and management visibility without cluster access
```

New:

```text
Autorelease conductor (shipped Aug 2026): automates ready steps and stops for review, gates or manual work. The Jira release tracker shows progress without cluster access
```

### Production evidence bullet

Old:

```text
* **Production validation**: 0.24.1 released end-to-end via autorelease (Sep 2026) across 7 OCP versions (4.16–4.22); 0.23.2 in progress
```

New:

```text
* **Release evidence**: 0.24.1 production bundle publication is verified; recorded FBC scope is OCP 4.16–4.22, with catalog/QE proof still needed for tracker closeout. 0.22.2 and 0.23.4 remain in progress
```

### Automated downstream releases deliverable

Old:

```text
Shipped. The autorelease conductor chains all automated steps with human gates only at the destructive apply points. Any team member can run a release. The Jira release tracker gives stakeholders and management visibility into progress without cluster access. Production-validated on 0.24.1 (Sep 2026).
```

New:

```text
The conductor and tracker are shipped, with review and manual steps retained. Release validation and ownership transfer require their own completion evidence.
```

Basis: conductor dispatch and step metadata include review, gate and manual stops. The October 7 production bundle read verifies v0.24.1 publication; seven index probes timed out and historical component Release CRs were NotFound. Full October 8 tracker histories provide no newer catalog/QE closeout proof. These observations do not establish end-to-end validation or artifact absence. See [current artifact evidence](../../current-work.md#release-recovery-and-time-sensitive-work).

## Edit 5: new deliverables (insert before the "Broader ecosystem impact" heading)

Omit this insertion if the block is already present. Otherwise insert it immediately before the line `#### Broader ecosystem impact`:

```text
#### Release tooling

Shared Claude/Codex skill discovery, EC deny-rule diagnosis and resumable OCP catalog/tenant/admission preparation are delivered. Skill execution portability, installed-host checks and OCP 5.0 build/install qualification remain unfinished.

#### Glasswing shipyard audit remediation

Shipyard AI-SAST remediation includes merged fixes across release branches and consumer repositories. Eight FIND-006 drafts closed without merging on October 3; their finding disposition and open upgrade/helper-pod repairs remain unfinished.
```

Basis: release-management #109/#110 and FBC #81 are merged; FBC #82 and the upgrade/helper-pod prerequisites remain open at the October 8 read. `make test-skills` passes 19 checks with five known compatibility debt entries. Keep the September counts in the [audit inventory](shipyard-audit-prs.md), and the detailed deliverable boundaries in the [story payloads](new-stories.md).

## Edit 1: replace stale size metrics with supported scope

Old:

```text
* 18 skills backed by 56 scripts (15,700 LOC) covering component setup, bundle builds, FBC catalogs, release notes, and verification
```

New:

```text
* Release skills backed by deterministic scripts and tests cover component setup, bundle builds, FBC catalogs, release notes, RPM lockfiles, OCP onboarding and verification
```

Basis: replace dated file/line totals with the supported operations. Current scripts and checks are listed in the [autorelease roadmap](../../autorelease-step-automation.md); historical counts remain in the audit history.

## Edit 2: replace the stale test count with validation scope

Old (nested under the Autorelease conductor bullet, indented four spaces):

```text
    * 337 tests across the conductor and step libraries
```

New:

```text
    * Automated shell/Python checks cover the conductor, step libraries, worktree safety, EC deny-rule handling and OCP onboarding
```

Basis: the full `make test` target covers these areas. Naming them avoids maintaining a mixed total of shell assertions and Python test cases.

## After editing: verification

1. Re-read the epic and confirm only the approved changes, nothing else, and that headings, bullets and nested bullets still render.
2. Confirm unaffected nodes in Current Automation and What This Epic Delivers are unchanged; preserve all CVE Remediation, Upstream Release, Agent Context Layer and existing links.
3. If conversion altered formatting, stop and apply the baseline/rollback rule above. Read back any correction before retrying through a supported Jira UI.
