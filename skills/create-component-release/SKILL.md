---
name: create-component-release
description: Create component release (stage or prod) with comprehensive verification
version: 2.0.0
argument-hint: "<version> [stage|prod] [--snapshot name]"
user-invocable: true
allowed-tools: Bash
---

# Create Component Release

Automates Step 8 (stage) and Step 15 (prod) of the Submariner release workflow.

**What it does:**

- Stage picks the newest of the last 20 push snapshots that passes its tests, has
  all 9 components and the newest bundle build, and whose component digests match
  that bundle's CSV. It reports each newer snapshot it skipped and why.
- `--snapshot <name>` (stage only) releases that snapshot instead. It gets the
  same checks and stops on a mismatch; it is never replaced.
- Prod reuses the stage snapshot and checks its digests again
- Generates 1 Release YAML (stage or prod)
- Validates YAML with make test-remote
- Automatically commits with descriptive message

**Invocation:**

```text
Claude: /release-management:create-component-release 0.22.1 stage
Codex:  $release-management:create-component-release 0.22.1 stage
```

The environment defaults to `stage` when omitted. `prod` copies the stage
notes, and a two-segment version such as `0.22` expands to `0.22.0`.

**Prerequisites:**

- oc login (required for snapshot queries)
- **For stage:** Step 7 complete (bundle SHAs updated) and `v$VERSION` on all five component repos
- **For prod:** Stage YAML exists with release notes (Steps 8-9 complete)

**Stops:** stage stops when no recent snapshot with the newest bundle matches its CSV. It shows
the newest candidate's mismatching components; the usual cause is an operator rebuilt after the
SHA bump (submariner-io/submariner-operator#4325), fixed by a new bundle SHA update. Stage with
`--snapshot`, and prod, stop when that snapshot doesn't match. A read failure stops: retry it.
Stage stops when the tag is missing: report that and stop. Set `ALLOW_PRE_TAG_CANDIDATE=true` only
when the user explicitly asks for a pre-tag candidate. A failed GitHub check always stops: retry it.
Prod stops when the stage YAML has no notes: report that and stop. Set
`ALLOW_EMPTY_RELEASE_NOTES=true` only when the user confirms the release has no issues or CVEs.
Both overrides warn.

## Inputs and execution

The version is required; the optional environment is `stage` or `prod`, and
`--snapshot <name>` is optional for stage. Pass `--snapshot` only when the user
names a snapshot. Use exactly the values supplied by the user and let the
backing script apply the documented stage default and version normalization.

Resolve the release-management root before running the operation. If
`${CLAUDE_PLUGIN_ROOT}` has been expanded to an absolute path, use that plugin
root. Otherwise, locate the checkout containing this `SKILL.md` and
`scripts/create-component-release.sh`. Verify the script exists and is
executable.

Run `scripts/create-component-release.sh`, passing the version, any supplied
environment and any `--snapshot <name>` as separate arguments in that order.
Do not combine arguments into a shell string or use `eval`.
