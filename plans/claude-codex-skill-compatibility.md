# Claude and Codex Skill Compatibility Plan

## Goal

Make every skill in `skills/` execute reliably from both Claude Code and Codex,
while keeping one shared skill implementation and preserving existing release
safety boundaries.

The repository-level Codex discovery work is complete: `.agents/skills` is a
relative symlink to `skills/`, and Codex currently discovers all 18 skills. The
remaining work is execution compatibility inside the skills and their backing
scripts.

## Current status

Phases 1 through 4 are complete. The compatibility contract, shared discovery,
portable delegates, caller-independent repository paths, namespaced Claude
examples, and public invocation documentation are implemented and covered by
offline tests. Installed-plugin execution remains in the final host matrix.

The remaining compatibility debt is confined to one complex skill:

- `konflux-ci-fix` still embeds a stateful workflow with Claude-specific input,
  prompting, and temporary-state assumptions.

`make test-skills` records five overlapping debt entries for that skill. That
count is a ratchet, not five separate features to build.

## Scope boundaries

In scope:

- Make shared skill instructions independent of either agent's argument
  interpolation and tool names.
- Make script resolution work from the repository and from an installed Claude
  plugin.
- Move deterministic operations out of long inline skill bodies where Codex
  cannot execute them reliably as one persistent shell session.
- Remove the nested Claude CLI dependency from release-note review.
- Add compatibility tests that do not contact Jira, GitHub, Konflux, or a
  registry.
- Keep Claude's plugin manifest, invocation syntax, and supported frontmatter
  working.

Out of scope:

- A native Codex plugin or marketplace package. Repository discovery already
  works; distribution outside a checkout is a separate requirement.
- Separate Claude and Codex copies of any skill, or generated copies requiring
  synchronization.
- Renaming skills, changing their release behavior, or redesigning release
  workflows unrelated to agent portability.
- Replacing an existing Claude workflow with a narrower Codex-compatible one.
- Building a generic dual-agent orchestration framework, generic review engine,
  or reusable plugin launcher.
- Adding Codex UI metadata or changing implicit-invocation policy. Neither is
  required for compatibility, and invocation policy should not change without
  an explicit product decision.
- Live release, Jira, push, PR, or cluster tests.

## Verified baseline

- `skills/` contains 18 unique skill directories with `SKILL.md` files.
- `.agents/skills -> ../skills` is tracked as a relative symlink and exposes all
  18 skills to Codex from the repository root and its subdirectories.
- Codex accepts the existing `name` and `description` fields and discovers the
  skills despite Claude-specific optional frontmatter.
- Claude supports plugin skills under `skills/`, namespaced
  `/release-management:skill-name` invocation,
  `$ARGUMENTS`, `allowed-tools`, `context: fork`, and plugin-relative path
  substitution. Supported optional frontmatter can remain, but shared skill
  execution must not depend on Claude's `$ARGUMENTS` substitution.
- `AGENTS.md` and `README.md` document Codex discovery and invocation. The
  legacy `$ARGUMENTS` paragraph in `AGENTS.md` is temporary; the discovery and
  safety guidance remains useful.
- The deterministic release implementations already live primarily under
  `scripts/`, which is the right shared boundary.

## Audit findings

### 1. One complex skill still uses Claude argument substitution

`konflux-ci-fix` still contains `$ARGUMENTS`. Claude replaces it before loading
the skill; Codex does not. The other 17 skills now use explicit named inputs and
direct argument forwarding.

The shared contract should be prose, not another magic variable:

1. Name required and optional inputs in the skill.
2. Use exactly the values supplied in the user's invocation or request.
3. Pass each value as a separate argument to the backing script.
4. Do not invent missing required values, use `eval`, or assume shell variables
   persist across tool calls.

Claude can continue to accept `/release-management:skill-name ...`; Codex can accept
`$release-management:skill-name ...`. The agent reads the same inputs from the
user request, so no shared executable block needs `$ARGUMENTS`.

### 2. Release-management script lookup is fixed

The simple skills and repository-owned delegates now resolve the installed
plugin or source checkout independently of the caller's working directory.
Offline tests cover the delegates that own release-management data. Do not
reopen this design unless a host acceptance test demonstrates a remaining
failure.

Keep this shared resolution rule in skill instructions:

1. When the host provides the installed plugin root, use it.
2. Otherwise locate the repository root containing both the selected skill and
   its referenced `scripts/` path.
3. Verify the exact backing script exists before invoking it.
4. Do not assume a home-directory checkout location.

For Claude, `${CLAUDE_PLUGIN_ROOT}` remains the authoritative installed plugin
location. For repository-scoped Codex, the discovered skill path and nearest
repository root identify the same checkout. State these as host alternatives in
the agent instruction; do not put the Claude substitution in a shell block
intended for both agents, and do not add a launcher whose own location would
need another host-specific resolver.

The former fixed `~/konflux/konflux-release-data` path in `add-team-member` was
different: it identified a target working repository, not the plugin root. Its
backing script now preserves that location as the default while accepting an
environment-provided target for testability and non-default checkouts.

### 3. One skill still embeds a long, stateful shell workflow

`konflux-ci-fix` is over 1,100 lines, uses `$ARGUMENTS`, Claude's
`AskUserQuestion` name, terminal `read -p`, and shared `/tmp/konflux-*` state.
Its `context: fork` field is valid for Claude but has no equivalent execution
effect in Codex. The workflow must not rely on the fork for correctness.

It should keep concise shared orchestration in `SKILL.md` and move repeatable
mechanics into tested scripts. Claude-only frontmatter may remain because it is
an optional Claude enhancement, not part of the correctness contract.

### 4. Release-note review is host-neutral

`scripts/release-notes/review-issue.sh` now prepares evidence without invoking a
model. The active Claude or Codex agent records decisions, and `review.sh apply`
validates and applies them serially.

The implemented boundary separates deterministic evidence and mutation from
model judgment:

- A prepare operation collects evidence for each issue and writes an isolated
  review bundle plus a manifest.
- The active host agent reviews each bundle and records a small structured
  decision containing issue key, `KEEP` or `REMOVE`, and a reason.
- An apply operation validates that decision against the manifest and performs
  the existing deterministic removal and commit behavior.
- Missing, malformed, mismatched, or unclear decisions fail safe by keeping the
  issue and returning a visible non-success result; they never remove an issue.
- Use a per-run `mktemp -d` directory and print it for recovery. Do not use a
  shared fixed `/tmp` filename.

This retains one review per issue without requiring either `claude -p`, nested
`codex`, or a host-specific subagent API. A host may parallelize evidence review
when it supports safe isolated workers, but parallelism is optional and cannot
alter the review contract. Apply decisions serially in manifest order so file
updates and commits cannot race.

### 5. Agent-specific syntax remains only in the unfinished skill

Public documentation and completed skills now use namespaced Claude examples.
When the remaining skill is rewritten, give it a compact pair when
direct invocation matters:

```text
Claude: /release-management:skill-name <inputs>
Codex:  $release-management:skill-name <inputs>
```

Use the name displayed by the client if it omits the plugin prefix. Do not
duplicate every example in both syntaxes; examples after the first pair can
show only the argument tail or the backing command.

## Target design

Every skill should fit one of five small patterns:

- **Thin script delegate:** `add-fbc-ocp-version`, `bundle-image-update`,
  `configure-downstream`, `create-component-release`, `create-fbc-release`,
  `create-release-tracker`, `fbc-update`, `get-fbc-urls`,
  `konflux-bundle-setup`, `konflux-component-setup`, `release-ls`,
  `rpm-lockfile-update`, `update-version-labels`, and `add-team-member`. Keep
  only inputs, safety boundaries, root resolution, and one backing-script call.
- **Release conductor:** `autorelease`. Use the same delegate contract plus its
  existing external-write authorization and stop rules.
- **Host-agent review:** `add-release-notes`. Use deterministic prepare/apply
  scripts with judgment performed by the active host agent.
- **Diagnostic orchestrator:** `konflux-ci-fix`. Preserve its current target
  selection and diagnosis behavior while scripts own deterministic inspection
  and mutation.
- **Knowledge:** `learn-release`. Keep portable routing to the existing workflow
  references.

No skill should require an agent to paste and execute a large shell program.
No backing script should select a model vendor.

## Implementation plan

### Phase 1: Add a compatibility contract test — complete

`scripts/lib/test-skills-compatibility.sh` now checks shared discovery,
frontmatter, referenced scripts, delegate mappings, Claude/Codex invocation
examples, and exact compatibility-debt sets. It allows supported Claude
frontmatter extensions. Implemented by `87d8def`.

### Phase 2: Normalize the simple skills — complete

The 13 thin delegates, `autorelease`, and `learn-release` now use named inputs,
direct argument forwarding, shared root resolution, and compact Claude/Codex
invocation pairs while preserving their interfaces and safety boundaries.
Implemented by `19f691f`, with namespace, plugin-root, argument-documentation,
and public-guide corrections in `cd5b00c`, `abf2fb9`, `8cf8f05`, and `472ce1c`.

### Phase 3: Extract `add-team-member` — complete

`add-team-member` is now a portable delegate to
`scripts/add-team-member.sh`. The script preserves its username and role
interface, contributor default, singular/plural roles, target default, RBAC
sorting, manifest rebuild, and local signed commit. It rejects dirty or invalid
targets, refuses to overwrite existing local or remote work branches, and never
pushes. Disposable-repository tests cover roles, validation, duplicates, target
resolution, generated output, branch collisions, and commit contents.

### Phase 4: Make release-note review host-neutral — complete

`review.sh prepare` now creates an isolated manifest and evidence bundle per
non-CVE issue. The active host agent writes structured KEEP/REMOVE decisions,
and `review.sh apply` validates and applies them serially with one signed commit
per removal. Missing, malformed, mismatched, stale, or unsafe inputs fail closed
without removing an issue; interrupted runs resume from recorded results and
recover committed removals. The existing release-note phases and version/stage
interface are unchanged. Offline tests use stubbed Jira/GitHub data and cover
the complete decision contract without a nested model CLI or host-specific API.

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
and no push. Use `plans/ec-fix-autorelease-integration.md` only as a reference
for the already-implemented task-bump helpers, not as the behavior contract for
this skill.

### Phase 6: Cross-agent acceptance and documentation cleanup

Run the validation ladder below. After it passes, remove the legacy
`$ARGUMENTS` workaround paragraph from `AGENTS.md`; retain the general rule to
pass user inputs unchanged and never invent required release values.

Namespaced invocations in `README.md` and `.claude/SKILLS.md` are already fixed.
Update them again only if Phases 3-5 change a documented argument or release-note
review instruction. Do not add another compatibility guide; this plan and the
skill bodies are sufficient.

## Validation ladder: small to large

Run each level before proceeding to the next so failures identify the smallest
broken contract. Run the focused levels during each phase. Run the full suite
once after the phase is complete; the commit hook provides the independent full
rerun, so do not add redundant full-suite repetitions.

1. **Single-skill syntax:** parse frontmatter and verify referenced files for
   each changed skill.
2. **Repository discovery:** run `make test-skills`; compare `skills/` and
   `.agents/skills/` inventories.
3. **Focused deterministic tests:** run the phase's test target in disposable
   repositories with network, push, and cluster commands stubbed. Verify input
   routing, commits, fail-safe behavior, resume behavior, and stop boundaries.
4. **Path and argument transport:** invoke changed delegates from the repository
   root and an unrelated directory. Verify exact argument vectors, including an
   omitted optional value, spaces, and shell metacharacters; never use `eval`.
5. **Full local suite:** run `make test` with no live credentials required.
6. **Manual host matrix:** in a disposable checkout, invoke every skill once
   from Claude and Codex. Use help, dry-run, fixtures, or a stubbed backing
   script for mutating skills. Also test Claude from an installed plugin while
   the current directory is a different repository, and Codex from both the
   repository root and a nested directory.

The manual matrix records discovery name, supplied inputs, resolved script,
stop boundary, and result. It must not apply Release resources, push branches,
write Jira, or publish messages.

## Completion criteria

- Claude and Codex discover the same 18 shared skills without copied skill
  trees.
- Every skill accepts its documented inputs in both invocation styles and
  forwards an identical argument vector.
- No shared executable instruction depends on `$ARGUMENTS`, a host-specific
  tool name, a fixed release-management checkout, or a nested model CLI.
- All deterministic mutations are implemented in tested scripts; skill bodies
  retain only judgment, routing, and safety boundaries.
- Claude plugin execution works outside the source checkout; repository-scoped
  Codex execution works from the root and nested directories.
- Existing authorization, gate, review, no-push, and no-apply boundaries are
  preserved.
- No existing Claude invocation form or supported workflow is removed merely to
  simplify Codex support.
- Focused tests and `make test` pass, followed by the non-mutating manual
  cross-agent matrix.

## Recommended commit sequence

Keep review and rollback simple with one concern per commit:

1. `tests: define shared skill compatibility contract` — complete
2. `skills: make simple delegates portable across Claude and Codex` — complete
3. `skills: move team-member updates into a tested script` — complete
4. `release-notes: use the active host agent for issue review` — complete
5. `konflux-ci-fix: make orchestration host-neutral`
6. `docs: finish Claude and Codex skill compatibility guidance`

## Design references

- [OpenAI: Build skills](https://learn.chatgpt.com/docs/build-skills)
- [Claude Code: Extend Claude with skills](https://code.claude.com/docs/en/skills)
- [Claude Code: Plugins reference](https://code.claude.com/docs/en/plugins-reference)
