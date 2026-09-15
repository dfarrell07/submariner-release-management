---
name: autorelease
description: Run ready release steps — chains auto steps, stops at gate/review/manual
version: 1.0.0
argument-hint: "<version> [--dry-run | --complete STEP | --refresh STEP | --close]"
user-invocable: true
allowed-tools: Bash
---

# Autorelease

Finds the next ready step in the release workflow and runs it. Chains consecutive
auto steps, stopping at gate, review, or manual steps. Invoke the skill again to
advance after a review, gate, or manual action is complete.

Uses a Jira release tracker. A normal run creates one if missing; `--dry-run`
can preview without creating a tracker.

**Invocation:**

```text
Claude: /autorelease 0.25.1
Codex:  $release-management:autorelease 0.25.1
```

Additional argument forms:

```text
0.25                             # Auto-detect the target patch version
0.25.1 --dry-run                 # Preview without running or writing
0.25.1 --complete cveFixes       # Mark a step complete
0.25.1 --refresh bundleShas      # Reset a step to run again
0.25.1 --close                   # After the release has shipped
```

**Requires:** `acli jira auth login --web`, `jq`, `gh`, `oc` (logged in for verifier steps), `skopeo` (for auto-close registry probes)

**Arguments:** the release version followed by any supported flags supplied by the
user. Pass them unchanged to `scripts/autorelease.sh`.

The conductor writes to Jira and attempts automatic pushes, PR creation, and
PR auto-merge setup at review stops. Before a normal run, obtain the user's
explicit authorization for those external actions. Without it, offer `--dry-run`
and stop; do not assume that stopping at review prevents external writes.
Other mutating flags must likewise be explicitly requested.

## Execution

Resolve the release-management root before running the operation. If
`${CLAUDE_PLUGIN_ROOT}` has been expanded to an absolute path, use that plugin
root. Otherwise, locate the checkout containing this `SKILL.md` and
`scripts/autorelease.sh`. Verify the script exists and is executable.

Run `scripts/autorelease.sh`, passing the release version and every supplied
flag or flag value as separate arguments in the user's original order. Do not
combine arguments into a shell string, use `eval`, or assume shell variables
persist across tool calls.
