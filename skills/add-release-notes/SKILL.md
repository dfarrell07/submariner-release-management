---
name: add-release-notes
description: Add release notes from Jira, then review each non-CVE issue with the active agent
version: 3.0.0
argument-hint: "<version> [--stage-yaml PATH]"
user-invocable: true
allowed-tools: Bash, Read, Write
---

# Add and Review Release Notes

Collect and filter Jira issues, apply them to the component stage release, verify
CVE fixes, then review each non-CVE issue with the active Claude or Codex agent.

## Invocation

```text
Claude: /release-management:add-release-notes 0.24.1
Codex:  $release-management:add-release-notes 0.24.1
```

The release version is required. `--stage-yaml PATH` optionally selects a
specific stage release. Use exactly the values supplied by the user and do not
infer a version or target file.

## Workflow

Resolve the release-management root first. If `${CLAUDE_PLUGIN_ROOT}` has been
expanded to an absolute path, use that plugin root. Otherwise, locate the
checkout containing this `SKILL.md`, `scripts/add-release-notes.sh`, and
`scripts/release-notes/review.sh`. Verify both scripts are executable.

1. Run `scripts/add-release-notes.sh` with the version and optional
   `--stage-yaml` arguments as separate values. This performs collection,
   filtering, auto-apply, and CVE verification using the existing workflow.
2. Run `scripts/release-notes/review.sh prepare` with the same inputs. Record the
   printed `REVIEW_RUN_DIR`; it is required for review and recovery. If the
   command instead prints `REVIEW_STATUS=no-reviewable-issues`, report that
   there are no non-CVE issues to review and stop without running apply.
3. Read `manifest.json` and every evidence bundle listed in it. Each bundle
   contains the review criteria and issue evidence. Review only those manifest
   entries. CVE issues are excluded by preparation and must never receive
   removable review decisions.
4. For each issue, write the decision JSON at the manifest's exact `decision`
   path. Use the issue key from the manifest, `KEEP` or `REMOVE`, and a non-empty
   one-line reason grounded in the evidence. Default to `KEEP` when uncertain.
5. Run `scripts/release-notes/review.sh apply REVIEW_RUN_DIR`. It validates and
   applies decisions serially, creating one signed commit per removal. If it
   reports failed or unreviewed issues, correct only their decision files and
   rerun the same apply command.

Do not invoke another model CLI or invent decisions for unread bundles. Do not
push, amend unrelated commits, update Jira, or publish messages. Stop after the
apply summary so the user can review the release notes and removal commits.
