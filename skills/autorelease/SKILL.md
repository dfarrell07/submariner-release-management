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
auto steps, stopping at gate, review, or manual steps. Re-run `/autorelease` to advance.

Requires a Jira release tracker. Run `/create-release-tracker` first if one doesn't exist.

**Usage:**

```bash
/autorelease 0.25.1                        # Find and run the next step
/autorelease 0.25                          # Auto-detects the target patch version
/autorelease 0.25.1 --dry-run              # Preview the chain; run nothing, write nothing
/autorelease 0.25.1 --complete cveFixes    # Mark a step as complete
/autorelease 0.25.1 --refresh bundleShas   # Reset a step to re-run it
/autorelease 0.25.1 --close                # after the release has shipped
```

**Requires:** `acli jira auth login --web`, `jq`, `gh`, `oc` (logged in for verifier steps), `skopeo` (for auto-close registry probes)

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
if [ ! -x "$GIT_ROOT/scripts/autorelease.sh" ]; then
  echo "ERROR: Required script not found" >&2
  echo "This skill requires: scripts/autorelease.sh" >&2
  exit 1
fi
IFS=" " read -ra _args <<< "$ARGUMENTS"
exec "$GIT_ROOT/scripts/autorelease.sh" "${_args[@]}"
```
