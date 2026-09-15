---
name: konflux-bundle-setup
description: Automate Konflux bundle setup on new release branches - configures Tekton pipelines for bundle builds including infrastructure, OLM annotations, hermetic builds, and multi-platform support
version: 2.0.0
argument-hint: "[version]"
user-invocable: true
allowed-tools: Bash
---

# Konflux Bundle Setup

Automate the setup of Konflux CI/CD bundle builds on new release branches for Submariner.

**What this skill does:** Copies bundle infrastructure from previous release, adds OLM annotations,
configures hermetic builds, multi-platform support, file change filters, and updates task references.
Creates 6-9 commits.

**Invocation:**

```text
Claude: /konflux-bundle-setup 0.23
Codex:  $release-management:konflux-bundle-setup 0.23
```

Omit the version to auto-detect it from the branch. The equivalent Make form
is:

```text
make konflux-bundle-setup VERSION=0.23
```

**Requirements:** `~/go/src/submariner-io/submariner-operator` must exist. Auto-navigates if needed.

## Inputs and execution

The version is optional. Preserve a supplied version; otherwise run the script
without arguments and allow its documented branch detection. Do not invent a
version.

Resolve the release-management root before running the operation. If
`${CLAUDE_PLUGIN_ROOT}` has been expanded to an absolute path, use that plugin
root. Otherwise, locate the checkout containing this `SKILL.md` and
`scripts/konflux-bundle-setup.sh`. Verify the script exists and is executable.

Run `scripts/konflux-bundle-setup.sh` with the supplied version as one argument,
or with no arguments for auto-detection. Do not combine arguments into a shell
string or use `eval`.
