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

**Usage:**

```text
$release-management:autorelease 0.25.1     # Codex invocation (use the displayed skill name)
/autorelease 0.25.1                        # Claude invocation
/autorelease 0.25                          # Auto-detect the target patch version
/autorelease 0.25.1 --dry-run              # Preview without running/writing
/autorelease 0.25.1 --complete cveFixes     # Mark a step complete
/autorelease 0.25.1 --refresh bundleShas    # Reset a step to run again
/autorelease 0.25.1 --close                # After the release has shipped

# Optional arguments are shared by all invocation styles:
# --dry-run, --complete STEP, --refresh STEP, and --close
```

**Requires:** `acli jira auth login --web`, `jq`, `gh`, `oc` (logged in for verifier steps), `skopeo` (for auto-close registry probes)

**Arguments:** the release version followed by any supported flags supplied by the
user. Pass them unchanged to `scripts/autorelease.sh`.

The conductor writes to Jira and attempts automatic pushes, PR creation, and
PR auto-merge setup at review stops. Before a normal run, obtain the user's
explicit authorization for those external actions. Without it, offer `--dry-run`
and stop; do not assume that stopping at review prevents external writes.
Other mutating flags must likewise be explicitly requested.

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
# In this call, bind RELEASE_ARGS to the user's individually quoted arguments.
# Example only, when the user actually requested that version and preview:
# RELEASE_ARGS=("0.25.1" "--dry-run")
declare -p RELEASE_ARGS >/dev/null 2>&1 || { echo "ERROR: Bind release arguments first" >&2; exit 1; }
[[ ${#RELEASE_ARGS[@]} -gt 0 ]] || { echo "ERROR: Release arguments required" >&2; exit 1; }
exec "$GIT_ROOT/scripts/autorelease.sh" "${RELEASE_ARGS[@]}"
```
