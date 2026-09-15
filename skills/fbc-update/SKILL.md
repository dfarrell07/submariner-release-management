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

```text
Claude: /fbc-update 0.22.1
Codex:  $release-management:fbc-update 0.22.1
```

Argument examples: `0.22.0` for an ADD scenario,
`0.21.2 --replace 0.21.1` for REPLACE, or
`0.22.1 --snapshot submariner-0-22-xxxxx` for an explicit snapshot.

## Arguments

- `<version>` - Version to update (e.g., `0.22.1`)
- `--snapshot <name>` - Optional: Specific snapshot (default: latest passing)
- `--replace <old-version>` - Optional: Old version to replace (REPLACE scenario)

## Prerequisites

- oc login to Konflux cluster
- FBC repository at `~/konflux/submariner-operator-fbc`, or set `FBC_REPO` to
  its location

## Execution

The version is required. Preserve any supplied `--snapshot <name>` or
`--replace <old-version>` option and do not infer missing values.

Resolve the release-management root before running the operation. If
`${CLAUDE_PLUGIN_ROOT}` has been expanded to an absolute path, use that plugin
root. Otherwise, locate the checkout containing this `SKILL.md` and
`scripts/fbc-catalog-update.sh`. Verify the script exists and is executable.

Run `scripts/fbc-catalog-update.sh`, passing each supplied value as a separate
argument in its original order. Do not combine arguments into a shell string or
use `eval`.
