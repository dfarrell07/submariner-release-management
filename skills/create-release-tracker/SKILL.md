---
name: create-release-tracker
description: Create Jira release tracker with parent task and 15-18 subtasks for Submariner release workflow tracking
version: 1.0.0
argument-hint: "<version> [--qe-assignee EMAIL] [--dry-run]"
user-invocable: true
allowed-tools: Bash
---

# Create Release Tracker

Creates a Task in the ACM Jira project ("Release Submariner X.Y.Z") with per-step
subtasks (15 for Z-stream, 18 for Y-stream). Other release skills automatically
update tracker subtasks as they run.

Safe to re-run — returns the existing tracker if one already exists for that version.

**Invocation:**

```text
Claude: /create-release-tracker 0.24.0 --dry-run
Codex:  $release-management:create-release-tracker 0.24.0 --dry-run
```

Without `--dry-run`, the skill creates or reuses the tracker. The version may
be two or three segments. Use `--qe-assignee <email>` to assign the QE subtask.

**Requires:** `acli jira auth login --web` (needed even for `--dry-run`, which
still does a read-only Jira check for an existing tracker), `jq`

## Inputs and execution

The release version is required. Optional arguments are `--qe-assignee <email>`
and `--dry-run`. Use exactly the values supplied by the user; do not infer a
version, assignee, or mutation mode.

Resolve the release-management root before running the operation. If
`${CLAUDE_PLUGIN_ROOT}` has been expanded to an absolute path, use that plugin
root. Otherwise, locate the checkout containing this `SKILL.md` and
`scripts/create-release-tracker.sh`. Verify the script exists and is executable.

Run `scripts/create-release-tracker.sh`, passing each supplied value as a
separate argument in its original order. Do not combine arguments into a shell
string or use `eval`.
