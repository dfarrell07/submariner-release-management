---
name: fbc-update
description: Update FBC catalog with bundle from Konflux snapshot - runs update-bundle + build-catalogs, commits, and updates the release tracker
version: 1.0.0
argument-hint: "<version> [--snapshot name] [--replace old-version]"
user-invocable: true
allowed-tools: Bash
---

# FBC Update Skill

Automates Step 11 (FBC catalog update) of the Submariner release workflow.

**What it does** (via `scripts/fbc-catalog-update.sh`):

- Runs `make update-bundle` in the FBC repo (queries the latest passing snapshot)
- Runs `make build-catalogs` to regenerate all 7 OCP catalogs
- Commits the catalog update
- Appends the push command to the autorelease push log (never auto-pushes)
- Updates the Jira release tracker (`fbcCatalogUpdate` step)

## Usage

```bash
/fbc-update <version> [--snapshot name] [--replace old-version]

# Examples:
/fbc-update 0.22.1                                  # UPDATE scenario (most common)
/fbc-update 0.22.0                                  # ADD scenario (new Y-stream)
/fbc-update 0.21.2 --replace 0.21.1                 # REPLACE scenario
/fbc-update 0.22.1 --snapshot submariner-0-22-xxxxx # Explicit snapshot
```

## Arguments

- `<version>` - Version to update (e.g., `0.22.1`)
- `--snapshot <name>` - Optional: Specific snapshot (default: latest passing)
- `--replace <old-version>` - Optional: Old version to replace (REPLACE scenario)

## Prerequisites

- oc login to Konflux cluster
- FBC repository at ~/konflux/submariner-operator-fbc

**Arguments:** $ARGUMENTS

---

```bash
#!/bin/bash
set -euo pipefail

# Find git repository root
GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -z "$GIT_ROOT" ]; then
  echo "❌ ERROR: Not in a git repository"
  exit 1
fi

# Verify companion script exists
if [ ! -x "$GIT_ROOT/scripts/fbc-catalog-update.sh" ]; then
  echo "❌ ERROR: Required script not found"
  echo "This skill requires: scripts/fbc-catalog-update.sh"
  exit 1
fi

# Delegate to companion script (passes all arguments)
exec "$GIT_ROOT/scripts/fbc-catalog-update.sh" $ARGUMENTS
```
