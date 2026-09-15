# Claude and Codex Skill Compatibility Plan

## Goal

Make every skill in `skills/` execute reliably from both Claude Code and Codex,
while keeping one shared skill implementation and preserving existing release
safety boundaries.

The repository-level Codex discovery work is complete: `.agents/skills` is a
relative symlink to `skills/`, and Codex currently discovers all 18 skills. The
remaining work is execution compatibility inside the skills and their backing
scripts.

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
  substitution. These fields can remain for Claude.
- `AGENTS.md` and `README.md` document Codex discovery and invocation. They are
  a temporary compatibility aid, not a substitute for portable skill bodies.
- The deterministic release implementations already live primarily under
  `scripts/`, which is the right shared boundary.

## Audit findings

### 1. Claude argument substitution appears in executable instructions

Seventeen skills contain `$ARGUMENTS`. Claude replaces it before loading the
skill; Codex does not. In 16 skills it is used directly in shell or input
parsing, so Codex would otherwise execute an unset variable, drop arguments, or
reconstruct a command ad hoc. `learn-release` uses it only to select content,
but still presents an unresolved token to Codex.

`autorelease` no longer uses `$ARGUMENTS`, but its `RELEASE_ARGS` shell-array
example still requires the agent to synthesize state before running the shown
block. It should use the same direct, host-neutral input contract as the other
skills.

The shared contract should be prose, not another magic variable:

1. Name required and optional inputs in the skill.
2. Use exactly the values supplied in the user's invocation or request.
3. Pass each value as a separate argument to the backing script.
4. Do not invent missing required values, use `eval`, or assume shell variables
   persist across tool calls.

Claude can continue to accept `/release-management:skill-name ...`; Codex can accept
`$release-management:skill-name ...`. The agent reads the same inputs from the
user request, so no shared executable block needs `$ARGUMENTS`.

### 2. Script lookup assumes the current checkout

Most thin skills use `git rev-parse --show-toplevel`. That works when Codex is
started in this repository, but an installed Claude plugin may run while the
working directory is another repository. `release-ls` is worse: it hard-codes
`~/konflux/submariner-release-management`.

Use this shared resolution rule in skill instructions:

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

Paths to external working repositories, such as `konflux-release-data`, are
runtime inputs and should be resolved or accepted by their backing scripts, not
confused with the release-management plugin root.

### 3. Two skills embed long, stateful shell workflows

`add-team-member` embeds roughly 200 lines of mutating shell. It parses
`$ARGUMENTS`, hard-codes the `konflux-release-data` checkout, and requires the
agent to execute one large block without losing state.

`konflux-ci-fix` is over 1,100 lines, uses `$ARGUMENTS`, Claude's
`AskUserQuestion` name, terminal `read -p`, and shared `/tmp/konflux-*` state.
Its `context: fork` field is valid for Claude but has no equivalent execution
effect in Codex. The workflow must not rely on the fork for correctness.

Both should keep concise shared orchestration in `SKILL.md` and move repeatable
mechanics into tested scripts. Claude-only frontmatter may remain because it is
an optional Claude enhancement, not part of the correctness contract.

### 4. Release-note review invokes Claude directly

`scripts/release-notes/review-issue.sh` calls `claude -p`. As a result, invoking
`add-release-notes` from Codex still requires a separately installed and
authenticated Claude CLI. This is the clearest remaining host-agent coupling.

Separate deterministic evidence and mutation from model judgment:

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

### 5. Agent-specific syntax is presented as if universal

Most usage examples show only Claude's bare `/skill-name` syntax. Plugin
examples should show one compact namespaced pair when direct invocation matters:

```text
Claude: /release-management:skill-name <inputs>
Codex:  $release-management:skill-name <inputs>
```

Use the name displayed by the client if it omits the plugin prefix. Do not
duplicate every example in both syntaxes; examples after the first pair can
show only the argument tail or the backing `make` command.

## Target design

Every skill should fit one of four small patterns:

- **Thin script delegate:** `add-fbc-ocp-version`, `bundle-image-update`,
  `configure-downstream`, `create-component-release`, `create-fbc-release`,
  `create-release-tracker`, `fbc-update`, `get-fbc-urls`,
  `konflux-bundle-setup`, `konflux-component-setup`, `release-ls`,
  `rpm-lockfile-update`, and `update-version-labels`. Keep only inputs, safety
  boundaries, root resolution, and one backing-script call.
- **Release conductor:** `autorelease`. Use the same delegate contract plus its
  existing external-write authorization and stop rules.
- **Host-agent review:** `add-release-notes`. Use deterministic prepare/apply
  scripts with judgment performed by the active host agent.
- **Knowledge/orchestration:** `learn-release`, `add-team-member`, and
  `konflux-ci-fix`. Keep portable routing in the skill and deterministic
  mutations in scripts.

No skill should require an agent to paste and execute a large shell program.
No backing script should select a model vendor.

## Implementation plan

### Phase 1: Add a compatibility contract test

Create `scripts/lib/test-skills-compatibility.sh`, wire it as
`make test-skills`, and include it in `make test`.

The static test should verify:

- `.agents/skills` is the expected relative symlink and resolves to `skills/`.
- Both paths expose the same 18 skill directories.
- Every directory has parseable YAML frontmatter with matching `name`, a
  non-empty `description`, and no duplicate name.
- Every local script explicitly referenced by a skill exists.
- Shared executable instructions do not contain `$ARGUMENTS`,
  `AskUserQuestion`, a fixed release-management checkout path, or a direct
  model-CLI invocation such as `claude -p` or `codex exec`. Invocation examples
  are documentation and remain allowed.
- Shared skill workflows do not use terminal prompts or fixed shared temporary
  state that depends on one persistent shell session.
- Usage sections do not present slash-only invocation as universal.

Do not reject valid Claude extension fields. The test protects the shared
subset while allowing `argument-hint`, `allowed-tools`, `user-invocable`, and
`context: fork` to remain.

Because this test lands before the known violations are removed, encode the
current violations as an exact compatibility-debt ratchet. New violations fail
the test. Each later phase removes the entries it fixes, and all debt sets must
be empty before this plan is complete. Do not add broad exclusions or keep
resolved entries merely to make the test pass.

### Phase 2: Normalize the simple skills

Update the 13 thin delegates, `autorelease`, and `learn-release`:

- Replace `$ARGUMENTS` and `RELEASE_ARGS` executable examples with explicit
  named-input instructions and direct argument forwarding.
- Apply the shared script-root resolution rule and remove the hard-coded
  `release-ls` path.
- Add one Claude/Codex invocation pair per skill where useful.
- Preserve existing required arguments, defaults implemented by scripts,
  prerequisites, mutation warnings, and Claude frontmatter.
- Keep descriptions unless a demonstrated discovery ambiguity requires a
  narrow correction; description rewriting is not part of this effort.

Extend the static compatibility contract with the exact skill-to-script mapping
and both invocation forms. Skill bodies are declarative prose, so executable
stub tests cannot exercise their argument handoff without launching a host
agent. Verify exact runtime `argv`, including an omitted optional value, spaces,
and shell metacharacters, in the cross-agent acceptance matrix; no test may use
`eval`.

### Phase 3: Extract `add-team-member`

Move its deterministic implementation to `scripts/add-team-member.sh` and
reduce the skill to inputs, prerequisites, authorization boundary, and script
delegation.

The script should:

- Accept username, optional role, and an optional or environment-provided
  `konflux-release-data` path.
- Preserve contributor as the least-privilege default and all current input
  validation.
- Refuse a dirty target worktree, preserve alphabetical RBAC output, rebuild
  manifests, and create the same signed commit.
- Never push or publish a message.

Add focused tests using a disposable fake `konflux-release-data` repository.
Cover all roles, the default role, invalid users and roles, duplicate users,
dirty worktrees, missing structure, generated output, and commit contents.

### Phase 4: Make release-note review host-neutral

Refactor `review.sh` and `review-issue.sh` around the prepare/decision/apply
contract described above. Retain `review-prompt.md` as the common review
criteria, but remove the `claude -p` invocation and model flags from scripts.

Update `add-release-notes/SKILL.md` to:

1. Run the existing collection, filter, apply, and CVE verification phases.
2. Prepare per-issue review bundles.
3. Review each bundle with the active agent against `review-prompt.md`.
4. Submit structured decisions to the deterministic apply operation.
5. Summarize kept, removed, failed, and unreviewed issues and stop for human
   review before any push.

Preserve the invariant that CVE issues are never sent through the removable
non-CVE review path. Preserve one signed commit per removal so each decision is
independently reversible.

Extend `scripts/release-notes/test-workflow.sh` with stubbed Jira/GitHub data.
Test prepare output, CVE exclusion, valid KEEP and REMOVE decisions, issue-key
mismatch, malformed verdicts, missing decisions, command-like reason text,
partial interruption and resume, and concurrent run-directory isolation.

### Phase 5: Finish the `konflux-ci-fix` conversion

Do not create a second CI-fix implementation. Complete the thin-skill rewrite
already described in `plans/ec-fix-autorelease-integration.md`, using the
existing `tekton-task-version-bump.sh`, `parse-ec-log.sh`, and their tests as
the deterministic path.

Compatibility-specific requirements are:

- Replace `$ARGUMENTS` parsing with named user inputs passed as separate script
  arguments.
- Replace `AskUserQuestion` and terminal `read -p` with a host-neutral
  instruction to report the exact manual action and wait for the user's next
  message.
- Replace fixed `/tmp/konflux-*` files with a unique run directory when any
  residual state is necessary.
- Keep `context: fork` for Claude if useful, but ensure the flow also works
  inline in Codex and after conversation compaction.
- Keep mutation, retry, and stop boundaries unchanged.
- Reduce `SKILL.md` to orchestration and links to only the relevant workflow
  reference; do not migrate unrelated EC behavior as part of compatibility.

Add focused tests for input routing, missing prerequisites, no-fix/manual-log
stop, resumable log parsing, successful deterministic fix, and no push.

### Phase 6: Cross-agent acceptance and documentation cleanup

Run the validation ladder below. After it passes, remove the legacy
`$ARGUMENTS` workaround paragraph from `AGENTS.md`; retain the general rule to
pass user inputs unchanged and never invent required release values.

Update `README.md` and `.claude/SKILLS.md` only where their invocation or
release-note reviewer wording is stale. Do not add another compatibility guide;
this plan and the skill bodies are sufficient.

## Validation ladder: small to large

Run each level before proceeding to the next so failures identify the smallest
broken contract.

1. **Single-skill syntax:** parse frontmatter and verify referenced files for
   each changed skill.
2. **Repository discovery:** run `make test-skills`; compare `skills/` and
   `.agents/skills/` inventories.
3. **Argument transport:** invoke stub backing scripts with exact argument
   vectors, including spaces and metacharacters, from the repository root and a
   nested directory.
4. **Focused deterministic tests:** run the test target for each changed script
   (`add-team-member`, release notes, EC fix, and existing delegate tests).
5. **Read-only skill smoke tests:** invoke `learn-release` and `release-ls`
   through both hosts against fixtures or stubbed commands. Confirm the same
   inputs and materially equivalent outcome.
6. **Mutating dry-run/disposable tests:** invoke delegate and orchestration
   skills in temporary repositories with network and push commands stubbed.
   Confirm authorization stops, commits, resume behavior, and exact argv.
7. **Full local suite:** run `make test` with no live credentials required.
8. **Manual host matrix:** in a disposable checkout, invoke every skill once
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
- Focused tests and `make test` pass, followed by the non-mutating manual
  cross-agent matrix.

## Recommended commit sequence

Keep review and rollback simple with one concern per commit:

1. `tests: define shared skill compatibility contract`
2. `skills: make simple delegates portable across Claude and Codex`
3. `skills: move team-member updates into a tested script`
4. `release-notes: use the active host agent for issue review`
5. `konflux-ci-fix: make orchestration host-neutral`
6. `docs: finish Claude and Codex skill compatibility guidance`

## Design references

- [OpenAI: Build skills](https://learn.chatgpt.com/docs/build-skills)
- [Claude Code: Extend Claude with skills](https://code.claude.com/docs/en/skills)
- [Claude Code: Plugins reference](https://code.claude.com/docs/en/plugins-reference)
