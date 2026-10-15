<!-- markdownlint-disable MD013 -->

# Release tooling implementation handoff

Daniel's existing work is tracked in [ACM-39730 — Jira release tracking](https://redhat.atlassian.net/browse/ACM-39730), [ACM-39731 — autorelease](https://redhat.atlassian.net/browse/ACM-39731) and [ACM-39732 — production URL conversion](https://redhat.atlassian.net/browse/ACM-39732). Ownership was checked October 15, 2026. [Issue #64](https://github.com/stolostron/submariner-release-management/issues/64) retains the original conductor design. Jira owns acceptance and progress; this handoff preserves implementation details absent from those trackers.

## Tracker reconciliation

ACM-39730/39731 already record delivered tracking and orchestration. Their remaining retarget/parent-artifact follow-up needs an explicit intended version and candidate, preserving unaffected evidence and refreshing the parent's Key Artifacts after reconciliation. Use the [release-specific evidence](current-work.md#existing-release-work) before designing or running a retarget operation.

Review these current source boundaries while implementing that follow-up:

* [Tracker writes](../scripts/lib/jira-tracker.sh) are deliberately best-effort. The [conductor](../scripts/autorelease.sh) can advance after an unacknowledged write, and cache an open-PR comment after a failed post. Decide conductor acknowledgement/retry behavior without changing standalone callers accidentally.
* `_resolve_version` converts a failed Jira query to empty before fallback discovery. Preserve explicit versions and distinguish unavailable tracking from genuine absence.
* Both production generators select stage YAML lexically and only warn on missing/unreadable QE approval. Reconcile the actual successful, QE-approved snapshot before production; generated YAML is not that evidence.

## Production URL conversion

ACM-39732 explicitly requires a standalone script, skill and `fbcProdUrls` wiring. Existing fork candidate `3cabf0e1f7526d3ef554571ffbb0a95db33bf013` adds script/wiring/tests but no skill. A PR query for that head returned none at the October 15 review. Reconcile the candidate with current main in an isolated worktree.

* Convert the already released bundle without selecting a newer component snapshot. Require the applicable OCP scope and actual release/index evidence; the draft's preflight only warns on missing tracker snapshot data. Preserve unrelated and untracked work.
* FBC's `update-bundle.sh` selects/verifies a snapshot, runs a catalog scenario and audits every temporary bundle URL. Its audit treats non-timeout registry failures as unreleased. Reuse only the appropriate conversion behavior; distinguish failed reads from absence and compare final template/catalog content.
* Correct `verify_fbcProdUrls`: it reads local template text with unescaped version dots and a registry substring. Current-source fixture calls accept `submariner.v0x23y4` for 0.23.4 and `example.invalid/registry.redhat.io/bundle:unpublished`. Parse exact unique bundle and image identities; establish merged conversion and publication evidence separately. Existing auto-close checks are not proof of the conversion's merged state.
* Add the thin shared skill and update discovery/compatibility inventories. Reconcile the [workflow's optional timing](../.agents/workflows/update-fbc-templates-prod.md) with the conductor's required final step.

Validate wrong/duplicate identities, partial publication, failed reads, checkout preservation, retry and repeated no-op behavior. Use existing conductor, scope/publication, worktree and skill fixtures plus `make test`. Preserve the current review/manual gates: normal conductor execution writes Jira and attempts pushes/PRs, so it requires explicit authorization under AGENTS.md.
