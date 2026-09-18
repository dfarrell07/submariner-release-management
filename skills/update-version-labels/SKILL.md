---
name: update-version-labels
description: Update Konflux Dockerfile version labels across Submariner repositories
version: 1.0.0
argument-hint: "<version> [repo]"
user-invocable: true
allowed-tools: Bash
---

# Update Version Labels

Updates Dockerfile `version` labels across 5 upstream repos (9 Dockerfiles) so Konflux's `{{ labels.version }}` tag
expansion produces correct image tags. Required for Z-stream releases before cutting upstream release.

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

Resolve the release-management root before running the operation. If
`${CLAUDE_PLUGIN_ROOT}` has been expanded to an absolute path, use that plugin
root. Otherwise, locate the checkout containing this `SKILL.md` and
`scripts/update-version-labels.sh`. Verify the script exists and is executable.

Run `scripts/update-version-labels.sh`, passing the version and any supplied
repository as separate arguments in that order. Do not combine arguments into a
shell string or use `eval`.
