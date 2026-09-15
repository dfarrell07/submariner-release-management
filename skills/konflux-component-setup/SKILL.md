---
name: konflux-component-setup
description: Automate Konflux component setup on new release branches - configures Tekton pipelines, Dockerfiles, RPM lockfiles, and hermetic builds for Submariner components. Supports 8 component types. Arguments are optional and order-independent.
version: 2.0.0
argument-hint: "[repo-shortcut] [component-name] [version]"
user-invocable: true
allowed-tools: Bash
context: fork
---

# Konflux Component Setup

Automate the setup of Konflux CI/CD builds on new release branches for Submariner components.

**Handles 8 components** across 5 repositories (NOT bundle):

| Repository          | Component(s)                                                     |
|---------------------|------------------------------------------------------------------|
| submariner-operator | submariner-operator                                              |
| submariner          | submariner-gateway, submariner-globalnet, submariner-route-agent |
| lighthouse          | lighthouse-agent, lighthouse-coredns                             |
| shipyard            | nettest                                                          |
| subctl              | subctl                                                           |

**Invocation:**

```text
Claude: /konflux-component-setup operator 0.23
Codex:  $release-management:konflux-component-setup operator 0.23
```

Additional argument forms:

```text
submariner submariner-gateway 0.23
lighthouse lighthouse-agent 0.23
(none)                                      # Auto-detect from branch
make konflux-component-setup REPO=operator VERSION=0.23
```

**Shortcuts:** operator, submariner, lighthouse, shipyard, subctl

## Inputs and execution

The repository shortcut, component, and version are optional and
order-independent. Preserve exactly the values and order supplied by the user;
otherwise run without arguments and allow the script's documented detection.

Resolve the release-management root before running the operation. If
`${CLAUDE_PLUGIN_ROOT}` has been expanded to an absolute path, use that plugin
root. Otherwise, locate the checkout containing this `SKILL.md` and
`scripts/konflux-component-setup.sh`. Verify the script exists and is
executable.

Run `scripts/konflux-component-setup.sh`, passing each supplied value as a
separate argument, or no arguments for auto-detection. Do not combine arguments
into a shell string or use `eval`.
