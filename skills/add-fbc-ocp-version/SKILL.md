---
name: add-fbc-ocp-version
description: Add FBC support for new OCP version in Konflux release data - creates overlays, tenant config, and RPA entries.
version: 1.0.0
argument-hint: "<ocp-version> <min-submariner-version>"
user-invocable: true
allowed-tools: Bash, Read, Glob
---

# Add FBC OCP Version

Adds FBC (File-Based Catalog) support for a new OCP version in Konflux release data.

**Invocation:**

```text
Claude: /release-management:add-fbc-ocp-version 4.22 0.23
Codex:  $release-management:add-fbc-ocp-version 4.22 0.23
```

The OCP version may also use hyphenated form, for example `4-22 0.23`.

**What it does:**

- Auto-detects previous OCP version from existing overlays
- Creates feature branch (subm-fbc-configure-4-22) from main
- Creates 3 commits:
  - Commit 1: 8 YAML overlay files (FBC overlay structure)
  - Commit 2: 7 auto-generated Kustomize manifests + kustomization.yaml
  - Commit 3: 2 FBC RPA files updated (applications list)
- Verifies all changes before committing
- Outputs push command, MR instructions, and Phase 2 instructions

## Inputs and execution

The OCP version and minimum Submariner version are required. Use exactly the
values supplied by the user; do not infer either value.

Resolve the release-management root before running the operation. If
`${CLAUDE_PLUGIN_ROOT}` has been expanded to an absolute path, use that plugin
root. Otherwise, locate the checkout containing this `SKILL.md` and
`scripts/add-fbc-ocp-version.sh`. Verify the script exists and is executable.

Run `scripts/add-fbc-ocp-version.sh`, passing the OCP version and minimum
Submariner version as two separate arguments in that order. Do not combine
arguments into a shell string or use `eval`.
