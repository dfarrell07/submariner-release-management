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
subtasks (15 for Z-stream, 18 for Y-stream). Other release skills
(`/create-component-release`, `/bundle-image-update`, `/add-release-notes`, etc.)
automatically update tracker subtasks as they run.

Safe to re-run — returns the existing tracker if one already exists for that version.

**Usage:**

```bash
/create-release-tracker 0.24.0                              # Auto-detect Y-stream
/create-release-tracker 0.24.1                              # Auto-detect Z-stream
/create-release-tracker 0.24                                # Auto-expands to 0.24.0
/create-release-tracker 0.24.0 --qe-assignee qe@redhat.com  # Assign QE subtask
/create-release-tracker 0.24.0 --dry-run                    # Preview without creating
```

**Requires:** `acli jira auth login --web` (needed even for `--dry-run`, which
still does a read-only Jira check for an existing tracker), `jq`

**Arguments:** $ARGUMENTS

---

```bash
#!/bin/bash
set -euo pipefail
GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -z "$GIT_ROOT" ]; then
  echo "ERROR: Not in a git repository" >&2
  exit 1
fi
if [ ! -x "$GIT_ROOT/scripts/create-release-tracker.sh" ]; then
  echo "ERROR: Required script not found" >&2
  echo "This skill requires: scripts/create-release-tracker.sh" >&2
  exit 1
fi
exec "$GIT_ROOT/scripts/create-release-tracker.sh" $ARGUMENTS
```
