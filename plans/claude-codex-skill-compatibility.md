# Claude and Codex Skill Compatibility Plan

## Goal

Finish shared execution portability without changing existing release workflows, invocation forms or authorization boundaries. One
`skills/` tree is exposed through `.agents/skills`; no generated host-specific copies or orchestration framework are needed.

## Current status

Phases 1–4 are delivered: shared discovery, portable delegates/root resolution, add-team-member extraction and active-host release-note
review. `make test-skills` covers the shared contract and retains five overlapping debt entries, all in `konflux-ci-fix`. They are one
remaining workflow, not five new features. Installed-host execution remains separately unqualified.

The [earlier design and implementation
record](https://github.com/stolostron/submariner-release-management/blob/f071c65c288e2bf1b2fd8f2470e70d819ad2031a/plans/claude-codex-skill-compatibility.md)
retains completed phases, source commits and detailed findings. ACM-39738 covers broader skill contribution; delivery of shared
discovery does not complete that story or the remaining host matrix. Current tracking is in the [Jira queue](jira-update-queue.md).

## Scope boundaries

Preserve optional/order-independent arguments, supported Claude frontmatter/plugin discovery and namespaced invocation. Pass user
inputs unchanged as individual arguments; resolve scripts from the checkout or installed plugin independently of cwd. Do not invent
release values or rely on `$ARGUMENTS` expansion, terminal prompts, persistent shell state, fixed temporary files or nested model CLIs.

Use the deterministic scripts already present. Thin delegates, the conductor, knowledge routing and host-agent release-note review are
working patterns; do not replace them with a new universal framework. A task-version bump is narrower than general CI diagnosis. Keep
pushes, Jira writes, cluster changes and review/manual gates under their existing authorization rules.

## Implementation plan

### Phase 5: Make `konflux-ci-fix` host-neutral without narrowing it

Preserve the current Claude-facing contract: current-repository use, branch and
PR targets, repository shortcuts, explicit paths, and order-independent
arguments. The existing `tekton-task-version-bump.sh` is the autorelease
remediation path for stale task versions; it is not a replacement for the
broader `konflux-ci-fix` diagnosis workflow.

Extract the existing deterministic target resolution, evidence collection,
log parsing, task remediation, branch handling, and cleanup into
`scripts/konflux-ci-fix.sh`. Reuse `tekton-task-version-bump.sh`,
`parse-ec-log.sh`, and shared Git helpers where their contracts fit; do not
duplicate them or force unrelated CI failures through the task-bump path.

Compatibility-specific requirements are:

- Keep the existing optional, order-independent inputs and pass them as separate
  script arguments. Add an explicit log-path resume option only if the extracted
  workflow needs it; do not remove an existing invocation form.
- Replace `AskUserQuestion` and terminal `read -p` with a host-neutral
  stop result that reports the exact manual action and resume command.
- Preserve the existing decision gate before creating a fix branch. Resume the
  deterministic mutation only through an explicit action after the user chooses
  to proceed.
- Use a unique per-run directory for resumable evidence; print its path and
  validate it on resume. Do not use fixed `/tmp/konflux-*` files.
- Keep `context: fork` for Claude if useful, but ensure the flow also works
  inline in Codex and after conversation compaction.
- Keep mutation, retry, and stop boundaries unchanged.
- Reduce `SKILL.md` to inputs, script delegation, interpretation of structured
  stop results, and links to only the relevant workflow reference.

Add focused tests for every existing target form, missing prerequisites,
no-fix/manual-log stop, validated resume, successful deterministic fix, cleanup,
and no push. Use the existing task-bump/parser/deny helpers where their contracts fit;
the broader skill remains responsible for its existing diagnosis scope.

### Phase 6: Cross-agent acceptance and documentation cleanup

Run the validation ladder below. After it passes, remove the legacy
`$ARGUMENTS` workaround paragraph from `AGENTS.md`; retain the general rule to
pass user inputs unchanged and never invent required release values.

Namespaced invocations in `README.md` and `.claude/SKILLS.md` are already fixed.
Update them again only if Phases 3-5 change a documented argument or release-note
review instruction. Do not add another compatibility guide; this plan and the
skill bodies are sufficient.

## Validation ladder: small to large

Run focused checks during implementation, then `make test` once the change is complete:

1. Parse changed skill metadata, referenced paths and exact argument forwarding, including omitted values, spaces/metacharacters and
   unrelated cwd. Run `make test-skills`.
2. Exercise target routing, evidence/resume, meaningful failure cases, cleanup and stop boundaries in disposable repositories with
   external mutations stubbed.
3. Run the full repository suite.
4. Invoke every shared skill once from both Claude and Codex in the non-mutating host matrix: Claude installed-plugin execution from
   another repository, and Codex discovery/invocation from root and nested directories. Use fixtures/help/stubs for mutating
   operations. Record selected name/inputs, resolved script, result and stop boundary; no live release, Jira write, push or message is
   needed.

## Completion criteria

All 18 shared skills retain their documented interfaces and discoverability. Deterministic operations live in tested scripts;
active-host judgment stays in the skill. The konflux-ci-fix debt ratchet is empty, full tests pass and the installed-host matrix
establishes execution rather than discovery alone. Preserve existing workflow coverage and external-action boundaries.

## Recommended commit sequence

One focused konflux-ci-fix extraction with its contract checks, followed by documentation/host-matrix completion. Completed phases need
no new commits or duplicate Jira stories.
