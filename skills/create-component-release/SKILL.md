---
name: create-component-release
description: Create component release (stage or prod) with comprehensive verification
version: 2.0.0
argument-hint: "<version> [stage|prod]"
user-invocable: true
allowed-tools: Bash
---

# Create Component Release

Automates Step 8 (stage) and Step 15 (prod) of the Submariner release workflow.

**What it does:**

- Verifies latest component snapshot (event type, tests, 9 components)
- Generates 1 Release YAML (stage or prod)
- Validates YAML with make test-remote
- Automatically commits with descriptive message

**Invocation:**

```text
Claude: /create-component-release 0.22.1 stage
Codex:  $release-management:create-component-release 0.22.1 stage
```

The environment defaults to `stage` when omitted. `prod` copies the stage
notes, and a two-segment version such as `0.22` expands to `0.22.0`.

**Prerequisites:**

- oc login (required for snapshot queries)
- **For stage:** Step 7 complete (bundle SHAs updated)
- **For prod:** Stage YAML exists with release notes (Steps 8-9 complete)

## Inputs and execution

The version is required; the optional environment is `stage` or `prod`. Use
exactly the values supplied by the user and let the backing script apply the
documented stage default and version normalization.

Resolve the release-management root before running the operation. If
`${CLAUDE_PLUGIN_ROOT}` has been expanded to an absolute path, use that plugin
root. Otherwise, locate the checkout containing this `SKILL.md` and
`scripts/create-component-release.sh`. Verify the script exists and is
executable.

Run `scripts/create-component-release.sh`, passing the version and any supplied
environment as separate arguments in that order. Do not combine arguments into
a shell string or use `eval`.
