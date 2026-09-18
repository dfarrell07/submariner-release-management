---
name: add-team-member
description: Add user to Submariner team Konflux RBAC - updates permissions for Web UI and cluster access
version: 1.0.0
argument-hint: "<username> [admin|maintainer|contributor]"
user-invocable: true
allowed-tools: Bash
---

# Add Team Member to Submariner Konflux

Add a user to the Submariner tenant's Konflux RBAC and create a local signed
commit containing the source and generated manifest changes.

## Invocation

```text
Claude: /release-management:add-team-member alice maintainer
Codex:  $release-management:add-team-member alice maintainer
```

The username is required. The optional role accepts `admin`, `maintainer`, or
`contributor`, including their plural forms, and defaults to `contributor`.

## Permissions

- `admin`: Full resource and access-management permissions.
- `maintainer`: Create and update release resources; no secret management.
- `contributor`: Read-only access to the Web UI and namespace resources.

## Execution

Use exactly the username and optional role supplied by the user. Do not infer a
username or elevate the default role.

Resolve the release-management root before running the operation. If
`${CLAUDE_PLUGIN_ROOT}` has been expanded to an absolute path, use that plugin
root. Otherwise, locate the checkout containing this `SKILL.md` and
`scripts/add-team-member.sh`. Verify the script exists and is executable.

Run `scripts/add-team-member.sh`, passing the username and optional role as
separate arguments in that order. Do not combine arguments into a shell string
or use `eval`.

The target `konflux-release-data` worktree must be clean and contain the tenant
configuration. The script uses `$KONFLUX_RELEASE_DATA` when set and otherwise
defaults to `$HOME/konflux/konflux-release-data`. It creates a local feature
branch and signed commit. Do not push the branch, create a merge request, or
publish a message unless the user explicitly requests that separate action.
