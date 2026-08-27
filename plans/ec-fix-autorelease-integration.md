# Plan: Integrate EC Fix into Autorelease as a Smart, Self-Diagnosing Step

## Problem

The current `ecFixes` step in autorelease runs `tekton-task-refs-update.sh`,
which only updates Tekton task *SHAs* (via pipeline-patcher). It does not bump
task *versions* (e.g. `0.1` → `0.2`). If an EC rule requires a newer task
version, the SHA update finds refs "already current" (correct SHA for the wrong
version), makes no commit, and the conductor stops with no useful guidance.

When the user re-runs `/autorelease`, the verifier sees EC still failing, the
conductor re-runs the script, which again makes no changes — an unproductive
loop. The user has no indication of which EC rule is failing or why.

The existing `konflux-ci-fix` skill does know how to diagnose EC failures (by
parsing the downloaded EC log), but it's an early-design skill with no
autorelease integration, no backing script, and requires manual interaction at
every step.

## Goal UX

```text
/autorelease 0.24.1
  → ecFixes: runs tekton-task-version-bump.sh
    → case A: versions and/or SHAs bumped → commits → push log → ⏸ REVIEW
    → case B: nothing to update →
        emits Konflux UI log download URL (from testPipelineRunName annotation)
        "Download EC log, save to ~/Downloads/, re-run /autorelease 0.24.1"

[user pushes PRs if case A; waits for rebuild; re-runs]

/autorelease 0.24.1
  → verify_ecFixes: PRs open → wait (rc=3)
  [PRs merge + Konflux rebuilds]
/autorelease 0.24.1
  → verify_ecFixes: EC passes → ✓ complete → chains to next step

# If case B (nothing to bump):
/autorelease 0.24.1   [after user downloads EC log]
  → tekton-task-version-bump.sh: log file found →
      runs scripts/lib/parse-ec-log.sh to extract failing rules + task names
      surfaces: "Failing rules: X. Affected tasks: Y, Z."
      if fixable (task version available on Quay): bumps + commits → case A
      if not fixable by task bump: surfaces specific rule + guidance → ⏸ REVIEW
```

## Components to Build

### 1. `scripts/tekton-task-version-bump.sh` (new)

Replaces `tekton-task-refs-update.sh` as the `ecFixes` backing script.
`tekton-task-refs-update.sh` stays unchanged for the `tektonTasks` Y-stream step.

**What it does:**

For each of the 6 repos (submariner-operator, submariner, lighthouse, shipyard,
subctl, stolostron/submariner-operator-fbc):

1. Find or create `fix-tekton-tasks-<major.minor>` branch (same branch name as
   `tekton-task-refs-update.sh` — so verify_ecFixes's PR-open guard still works).
2. **Version bump pass:** For each task referenced in `.tekton/*.yaml`, query the
   Quay API (`quay.io/konflux-ci/tekton-catalog`) for the latest available
   version. If a newer version exists, update the version string in the YAML.
3. **SHA bump pass:** Run pipeline-patcher to update SHAs for the (possibly
   bumped) version.
4. If any changes: commit, add to `AUTORELEASE_PUSH_LOG` with push + `gh pr
   create --title ... --body ...` commands. Exit 0.
5. If no changes across all repos: check for downloaded EC log file
   (`~/Downloads/submariner-enterprise-*.log` matching the failing snapshot's
   git revisions). If found: run `scripts/lib/parse-ec-log.sh` and surface
   results. Exit 2 (nothing to update — signals conductor to stop without
   re-running).

**Exit codes:**

- `0`: commits made in one or more repos (user must push PRs)
- `1`: hard failure (prereq missing, repo not found, patcher error)
- `2`: no updates possible; EC log guidance emitted (or no log yet)

**Args:** `<version> [--repo <name>] [--branch <branch>]`

Tracker integration: writes to `ecFixes` subtask (via `AUTORELEASE_TRACKER_STEP`
env var, same mechanism as current).

Fork remote: uses `fork_remote`/`get_gh_user` from `lib/git-utils.sh` (same
pattern as all other scripts).

### 2. `scripts/lib/parse-ec-log.sh` (new)

Shell helper that extracts the actionable signal from a downloaded EC log file.
Kept as a shell script (not inline in the skill) so:

- The agent can call it and get structured output without parsing raw log text.
- It can be unit-tested.
- `tekton-task-version-bump.sh` can call it headlessly when a log is present.

**What it does:**

```bash
parse-ec-log.sh <log-file>
```

Outputs structured text (one section per category):

```text
FAILING_RULES:
  required_tasks.missing_required_task (tasks: clamav-scan, sast-snyk-check)
  tasks.missing_required_step_runner

AFFECTED_TASKS:
  clamav-scan (current: 0.1, required: 0.2)
  sast-snyk-check (current: 0.1, required: 0.2)

WARNINGS:
  deprecated_image_labels (3 occurrences)

FIXABLE_BY_VERSION_BUMP: yes   # or: no (rule is not task-version related)
```

Parsing strategy:

- `grep "Term:"` → task names (existing technique from `konflux-ci-fix` skill)
- `grep "msg="` or `grep "violation"` → rule names
- Cross-reference task names against Quay API for available versions
- Output `FIXABLE_BY_VERSION_BUMP: yes` when all failing rules map to tasks with
  newer versions available

Exit codes:

- `0`: parsed successfully
- `1`: file not found or unreadable
- `2`: no violations found (log shows clean run — stale log or wrong file)

### 3. `skills/konflux-ci-fix/SKILL.md` (rewrite)

Thin wrapper like all modern skills, plus interactive fallback for unfixable
violations.

**Headless path (most cases):**

```bash
exec "$GIT_ROOT/scripts/tekton-task-version-bump.sh" "$VERSION" "$@"
```

**Interactive fallback (when script exits 2 — nothing to update):**

The skill's agent logic (what Claude does when invoked as `/konflux-ci-fix`):

1. Extract `testPipelineRunName` from the failing snapshot annotation for each
   affected repo.
2. Construct and emit the Konflux UI log URLs.
3. Wait for user to confirm log downloaded (or use `AskUserQuestion`).
4. Run `scripts/lib/parse-ec-log.sh <log-file>` and surface the structured
   output.
5. If `FIXABLE_BY_VERSION_BUMP: yes`: re-run `tekton-task-version-bump.sh`
   (should now commit since log confirmed which tasks to bump).
6. If not fixable by version bump: surface the specific failing rule names and
   link to the EC policy source for manual remediation.

The skill arg signature becomes:

```text
/konflux-ci-fix 0.24.1 [--repo operator]
```

Version is required (autorelease passes it). Repo is optional filter.

### 4. `scripts/lib/jira-tracker.sh` — `ecFixes` step wiring

```bash
STEP_SCRIPT["ecFixes"]="scripts/tekton-task-version-bump.sh"
# AUTOMATION_LEVEL stays "review" — user must push PRs before conductor advances
```

### 5. `scripts/autorelease.sh` — conductor rc=2 handling

When `tekton-task-version-bump.sh` exits 2 (nothing to update, log guidance
emitted), the conductor currently treats non-zero as failure and stops with
`❌ failed`. Need a new path:

Script rc=2 at `review` level → conductor prints a distinct message:

```text
⏸ ecFixes: Update Tekton Task Versions — NOTHING TO UPDATE
  EC is failing for a reason other than stale task refs.
  See log download URL above. After downloading, re-run: /autorelease 0.24.1
```

Then stops (does not re-run script on next invocation until the log is present
and a fix is identified).

To avoid re-running when exit 2: conductor should not re-dispatch a `review`
step if the previous run exited 2. Track this via a Jira subtask field or a
local git note — or simpler: `tekton-task-version-bump.sh` sets the Jira subtask
description to "EC log needed" when it exits 2, and `verify_ecFixes` checks for
that description before re-dispatching.

Simplest implementation: when script exits 2, write a sentinel to the Jira
subtask `data` field: `{"needsEcLog": true}`. `verify_ecFixes` checks for this
and returns rc=2 (precondition unmet) instead of rc=1 (not done), which surfaces
"Cannot verify — EC log analysis in progress" and does not re-run the script.

## What Does NOT Change

- `tekton-task-refs-update.sh` — unchanged, still backs the `tektonTasks`
  Y-stream step. The branch name `fix-tekton-tasks-<mm>` is shared with the new
  script so `verify_ecFixes`'s PR-open guard works for both.
- `verify_ecFixes` core logic — PR-open guard + EC pass/fail check is correct.
  Only the "nothing to do" sentinel handling is new.
- `verify_tektonTasks` — unchanged.

## Implementation Order

1. `scripts/lib/parse-ec-log.sh` + tests — standalone, no dependencies.
2. `scripts/tekton-task-version-bump.sh` — builds on parse-ec-log.sh and
   existing lib/git-utils.sh, lib/pipeline-patcher.sh.
3. Conductor rc=2 handling in `autorelease.sh`.
4. Update `STEP_SCRIPT["ecFixes"]` in `jira-tracker.sh`.
5. Rewrite `skills/konflux-ci-fix/SKILL.md` as thin wrapper + interactive
   fallback.
6. Unit tests for parse-ec-log.sh and tekton-task-version-bump.sh.

## Implementation Details (verified)

### Quay API

The Docker v2 API works without auth for public repos:

```bash
curl -s "https://quay.io/v2/konflux-ci/tekton-catalog/task-<name>/tags/list" \
  | jq -r '.tags[]' | grep -E "^[0-9]+\.[0-9]+$" | sort -Vu | tail -1
```

- `-oci-ta` task variants are **separate sub-repos** on Quay (e.g.
  `task-git-clone-oci-ta`) — the task name in `.tekton/` maps directly to the
  sub-repo name, so the same query works for both base and oci-ta variants.
- Version tags are clean `X.Y` (e.g. `0.1`, `0.2`, `0.10`). SHA-suffixed tags
  like `0.2.5-1786021637` are build instances — filter to `^[0-9]+\.[0-9]+$`
  to get only version tags.

### Branch naming

`tekton-task-refs-update.sh` force-recreates `fix-tekton-tasks-<mm>` with
`git checkout -B` from the base branch. This works but silently discards any
existing local branch content.

`tekton-task-version-bump.sh` will use the **`-vN` pattern** (same as the
CVE fix skill in shipyard): check if `fix-tekton-tasks-<mm>` exists locally or
remotely; if it does, try `-v2`, `-v3`, etc. until a free name is found.
This preserves the original branch for audit and avoids confusing GitHub if the
old PR isn't merged yet.

`verify_ecFixes` PR-open guard already searches for any PR with head branch
matching `fix-tekton-tasks-<mm>` — this naturally catches `-v2`/`-vN` variants
since the guard uses `gh pr list --head` with the base name and `jq` filtering,
not an exact match. Confirm this during implementation.

### Log file matching

The `konflux-ci-fix` skill globs `~/Downloads/submariner-enterprise-*.log` and
matches against the snapshot's git revisions. This pattern is empirical — will
confirm naming during testing. The parse script accepts an explicit `<log-file>`
arg so matching is the caller's concern.
