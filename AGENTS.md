# Submariner Release Management

This repository orchestrates Submariner releases through Konflux.

## Agent workflow

- Use the skills in `.agents/skills` for reusable release operations.
- Use `.agents/workflows` as detailed reference material for manual or gated steps.
- Treat `scripts/` as the deterministic implementation of release operations.
- Inspect release state and prerequisites before making changes.
- Stop at review, gate, or manual steps and report the exact next action.
- Do not apply Release resources, push branches, or publish external messages unless
  the user explicitly requests that action.

## Common invocations

Codex invokes skills with `$skill-name`; Claude invokes the same skills with
`/skill-name`. Use the name shown in the agent's skill selector; plugin-scoped
names include the `release-management:` prefix.

- `$release-management:autorelease <version> [--dry-run]` runs ready automated release steps.
- `$release-management:release-ls <version>` reports release progress and blockers.
- `$release-management:learn-release overview` explains the release workflow.

When a skill needs arguments, use the user's supplied arguments directly and pass
them to the referenced script. Do not invent missing release versions or target
environments.

Legacy skills use `$ARGUMENTS` as an instruction placeholder, not a shell
variable supplied by Codex. Adapt command examples to pass the user's arguments
as individually quoted values or a Bash array bound in the same call. For inline
workflows, bind their named inputs explicitly instead of parsing `$ARGUMENTS`.
Do not use `eval` or assume exports/cwd persist between tool calls. Resolve
scripts from this checkout, not a hard-coded home path.

`scripts/autorelease.sh` writes to Jira and attempts automatic pushes, PR
creation, and PR auto-merge setup at review stops. A normal invocation therefore
requires explicit authorization for those external actions before starting.
Without it, offer `--dry-run` and report the prerequisite; do not run the mutating
conductor or change its policy to bypass the review boundary.

## Validation

Run `make test` for repository changes. Run the focused test target when changing
an individual script or skill, such as `make test-autorelease` for the release
conductor.
