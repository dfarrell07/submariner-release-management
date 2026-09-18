---
name: configure-downstream
description: Configure Konflux for new Submariner version - creates overlays, tenant config, and RPAs for Y-stream releases.
version: 1.0.0
argument-hint: "<new-version>"
user-invocable: true
allowed-tools: Bash, Read, Glob
---

# Configure Downstream Release

Configures Konflux CI/CD for a new Submariner minor version (Y-stream releases).

**Invocation:**

```text
Claude: /release-management:configure-downstream 0.23
Codex:  $release-management:configure-downstream 0.23
```

`0.23.0` is also accepted and is reduced to its major/minor version.

**What it does:**

- Auto-detects previous version from existing overlays
- Creates feature branch (subm-configure-v0.23) from main
- Creates 3 commits with 49 total files:
  - Commit 1: 26 YAML overlay files
  - Commit 2: 22 auto-generated Kustomize manifests
  - Commit 3: 2 ReleasePlanAdmission files (stage + prod)
- Verifies all changes before committing
- Outputs push command and MR instructions

## Inputs and execution

The new Submariner version is required. Use exactly the value supplied by the
user; do not infer a release version.

Resolve the release-management root before running the operation. If
`${CLAUDE_PLUGIN_ROOT}` has been expanded to an absolute path, use that plugin
root. Otherwise, locate the checkout containing this `SKILL.md` and
`scripts/configure-downstream.sh`. Verify the script exists and is executable.

Run `scripts/configure-downstream.sh` with the supplied version as one argument.
Do not combine arguments into a shell string or use `eval`.
