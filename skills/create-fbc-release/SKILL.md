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

**Usage:**

```bash
/create-fbc-release 0.22.1 stage     # Create stage releases
/create-fbc-release 0.22.1 prod      # Create prod releases
/create-fbc-release 0.22.1           # Defaults to stage
```

**Prerequisites:**

- oc login (required for snapshot queries)
- Step 10 complete (component stage release)
- Step 11 complete (FBC catalog updated)
- FBC snapshots rebuilt (~15-30 min after Step 11)

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

# Verify orchestrator script exists
if [ ! -x "$GIT_ROOT/scripts/create-fbc-releases.sh" ]; then
  echo "❌ ERROR: Required orchestrator script not found"
  echo "This skill requires: scripts/create-fbc-releases.sh"
  exit 1
fi

# Delegate to orchestrator (passes all arguments)
exec "$GIT_ROOT/scripts/create-fbc-releases.sh" $ARGUMENTS
```
