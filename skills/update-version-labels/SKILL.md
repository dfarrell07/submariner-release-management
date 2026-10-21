---
name: update-version-labels
description: Align Konflux component image labels and compiled Go versions across Submariner repositories
version: 1.0.0
argument-hint: "<version> [repo]"
user-invocable: true
allowed-tools: Bash
---

# Update Version Labels

Updates image labels and compiled Go versions across 5 upstream repos (8 component Dockerfiles).
The compiler receives the literal release version, independently of pipeline `BASE_BRANCH` overrides.
Required for Z-stream releases before cutting upstream release.

Bundle Dockerfile labels stay with the committed CSV until `bundle-image-update` regenerates both.

## Invocation

```text
Claude: /release-management:update-version-labels 0.23.1 subctl
Codex:  $release-management:update-version-labels 0.23.1 subctl
```

Omit the repository to update all five. Equivalent Make forms are:

```text
make update-version-labels VERSION=0.23.1        # All 5 repos
make update-version-labels VERSION=0.23.1 REPO=subctl  # Single repo
```

**Repos:** submariner-operator, submariner, lighthouse, shipyard, subctl

**Requirements:** `git`, SSH key for git fetch

## Inputs and execution

The version is required; the repository filter is optional. Use exactly the
values supplied by the user and do not infer a release version.

Use the release-management checkout selected for this task. Otherwise, use an
absolute `${CLAUDE_PLUGIN_ROOT}` or locate the checkout containing this `SKILL.md` and
`scripts/update-version-labels.sh`. Verify the script exists and is executable.

For an update invocation, run `scripts/update-version-labels.sh`, passing the version and any supplied
repository as separate arguments in that order. Do not combine arguments into a
shell string or use `eval`.

At review, inspect the updated components' rebuilt image labels and binary versions (including
the operator's default image versions). Merged PRs and version checks establish
readiness to rebuild; verify the resulting image payloads before advancing.
Expected release-branch Go lint failures and unrelated vulnerability checks are
outside this step.
