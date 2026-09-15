---
name: bundle-image-update
description: Update bundle component image SHAs from Konflux snapshots - automates SHA extraction, config file updates, bundle regeneration, and verification
version: 1.0.0
argument-hint: "[X.Y|X.Y.Z] [--snapshot name]"
user-invocable: true
allowed-tools: Bash
---

# Bundle Image Update

Update bundle component image SHAs from Konflux snapshots.

**What this skill does:** Queries Konflux for latest passing snapshot, extracts 7 component SHAs,
updates config files, regenerates bundle with make bundle, updates Dockerfile labels (version bumps),
verifies all SHAs match, and creates a single commit.

**Invocation:**

```text
Claude: /release-management:bundle-image-update 0.21.2
Codex:  $release-management:bundle-image-update 0.21.2
```

Additional argument forms:

```text
(none)                                      # Latest snapshot, SHA-only
--snapshot submariner-0-21-xxxxx            # Specific snapshot
make bundle-image-update VERSION=0.21.2
```

**Requirements:** `~/go/src/submariner-io/submariner-operator` must exist on a release branch.
Must be logged into Konflux cluster. Bash 4.0+.

## Inputs and execution

The version is optional and may be `X.Y` or `X.Y.Z`. The optional snapshot form
is `--snapshot <name>`. Preserve the user's argument order and allow the backing
script to perform documented auto-detection; do not invent a version or
snapshot.

Resolve the release-management root before running the operation. If
`${CLAUDE_PLUGIN_ROOT}` has been expanded to an absolute path, use that plugin
root. Otherwise, locate the checkout containing this `SKILL.md` and
`scripts/bundle-image-update.sh`. Verify the script exists and is executable.

Run `scripts/bundle-image-update.sh`, passing each supplied value as a separate
argument. Run it with no arguments when the user requests the auto-detected
form. Do not combine arguments into a shell string or use `eval`.
