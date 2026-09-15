---
name: create-fbc-release
description: Create FBC releases for all OCP versions (stage or prod) with comprehensive verification
version: 1.0.0
argument-hint: "<version> [stage|prod]"
user-invocable: true
allowed-tools: Bash
---

# Create FBC Releases

Automates Step 12 (FBC stage releases) and Step 17 (FBC prod releases) of the Submariner release workflow.

**What it does:**

- Verifies GitHub catalog consistency (all 7 OCP versions)
- Verifies FBC snapshots (event type, tests, bundle SHAs)
- Verifies component SHAs across sources (operator repo, registry bundle, FBC GitHub, 7 snapshots)
- Generates 7 Release YAMLs (one per OCP version: 4-16 through 4-22)
- Validates YAMLs with make test-remote
- Automatically commits with descriptive message

**Invocation:**

```text
Claude: /create-fbc-release 0.22.1 stage
Codex:  $release-management:create-fbc-release 0.22.1 stage
```

Use `prod` for production releases. The environment defaults to `stage` when
omitted.

**Prerequisites:**

- oc login (required for snapshot queries)
- Step 10 complete (component stage release)
- Step 11 complete (FBC catalog updated)
- FBC snapshots rebuilt (~15-30 min after Step 11)

## Inputs and execution

The version is required; the optional environment is `stage` or `prod`, and
the two values are order-independent. Use exactly the values supplied by the
user and let the backing script apply the documented stage default.

Resolve the release-management root before running the operation. If
`${CLAUDE_PLUGIN_ROOT}` has been expanded to an absolute path, use that plugin
root. Otherwise, locate the checkout containing this `SKILL.md` and
`scripts/create-fbc-releases.sh`. Verify the script exists and is executable.

Run `scripts/create-fbc-releases.sh`, passing each supplied value as a separate
argument in the user's original order. Do not combine arguments into a shell
string or use `eval`.
