---
name: rpm-lockfile-update
description: Update RPM lockfiles across Submariner repositories
version: 2.0.0
argument-hint: "[branch] [repo|component]"
user-invocable: true
allowed-tools: Bash
---

# RPM Lockfile Update

Regenerates RPM lockfiles in submariner and shipyard repositories by creating fix branches, running hermetic builds,
and committing updated lockfiles.

## Invocation

```text
Claude: /release-management:rpm-lockfile-update 0.21 submariner
Codex:  $release-management:rpm-lockfile-update 0.21 submariner
```

Additional argument forms:

```text
(none)                                      # Auto-detect branch, all repos
0.21                                        # Explicit branch, all repos
gateway                                     # Auto-detect branch, gateway only
make rpm-lockfile-update                         # Auto-detect branch
make rpm-lockfile-update COMPONENT=gateway       # Auto-detect, component filter
make rpm-lockfile-update BRANCH=0.21 COMPONENT=gateway  # Explicit branch
```

**Filter options:** all, submariner, shipyard, gateway, globalnet, route-agent, nettest

**Requirements:** Red Hat entitlements, `podman login registry.redhat.io`, `gh auth login`, Bash 4.0+

## Inputs and execution

The branch and repository/component filter are optional. Preserve exactly the
values and order supplied by the user; otherwise let the script perform its
documented branch and repository detection.

Resolve the release-management root before running the operation. If
`${CLAUDE_PLUGIN_ROOT}` has been expanded to an absolute path, use that plugin
root. Otherwise, locate the checkout containing this `SKILL.md` and
`scripts/rpm-lockfile-update.sh`. Verify the script exists and is executable.

Run `scripts/rpm-lockfile-update.sh`, passing each supplied value as a separate
argument, or no arguments for full auto-detection. Do not combine arguments into
a shell string or use `eval`.
