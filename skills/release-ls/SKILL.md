---
name: release-ls
description: Check Submariner release status across 20 workflow steps - shows completed phases, current blockers, and next actions. Use when checking release progress, verifying builds, or debugging failed releases.
version: 1.0.0
argument-hint: "<version>"
user-invocable: true
allowed-tools: Bash, Read
---

# Release Status

Report completed release phases, blockers, and the exact next action.

## Invocation

```text
Claude: /release-ls 0.22.0
Codex:  $release-management:release-ls 0.22.0
```

**Requires:** `oc login`

## Inputs and execution

The release version is required. Use exactly the value supplied by the user;
do not infer one. If it is missing, report the script's usage instead of
starting a status check.

Resolve the release-management root before running the operation. If
`${CLAUDE_PLUGIN_ROOT}` has been expanded to an absolute path, use that plugin
root. Otherwise, locate the checkout containing this `SKILL.md` and
`scripts/release-status.sh`. Verify the script exists and is executable.

Run `scripts/release-status.sh` with the supplied version as one argument.
Report its status and next action; do not mutate release state.
