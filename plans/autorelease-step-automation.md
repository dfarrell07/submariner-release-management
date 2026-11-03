<!-- markdownlint-disable MD013 -->

# Release tooling implementation handoff

[ACM-39732 — production URL conversion](https://redhat.atlassian.net/browse/ACM-39732), [ACM-39730 — Jira tracking](https://redhat.atlassian.net/browse/ACM-39730) and [ACM-39731 — autorelease](https://redhat.atlassian.net/browse/ACM-39731) own acceptance and progress. Refresh those trackers before selecting work; this handoff retains implementation findings absent from them. Source findings below were rechecked against main on November 4, 2026, after #124 merged. [Issue #64](https://github.com/stolostron/submariner-release-management/issues/64) retains the original conductor design.

## Production URL conversion

ACM-39732 requires a standalone script, shared skill and `fbcProdUrls` wiring. Reconcile [fork candidate `3cabf0e1`](https://github.com/dfarrell07/submariner-release-management/commit/3cabf0e1f7526d3ef554571ffbb0a95db33bf013) with current main in an isolated worktree; it has script/wiring/tests but lacks the skill and discovery/compatibility inventory updates.

* Convert the already released bundle using its applicable OCP scope and actual release/index evidence. The candidate only warns on missing tracker snapshot data. Preserve unrelated and untracked work.
* Reuse FBC URL conversion without rerunning `update-bundle.sh`'s snapshot selection and catalog scenario. Preserve the current `prod_bundle_status` distinction between released, absent and inconclusive registry reads, and review the final template/catalog diff.
* Reuse [#124's merged verifier](https://github.com/stolostron/submariner-release-management/pull/124) when wiring conversion. It requires one exact bundle entry with an immutable production image in canonical upstream `main` and records `templateRevision`. Source conversion and registry publication are separate; retain both checks before closeout.
* Reconcile the [workflow's optional timing](../.agents/workflows/update-fbc-templates-prod.md) with the conductor's required final step before wiring execution.

Use existing conductor, scope/publication, worktree and skill fixtures to cover wrong/duplicate identities, partial publication, failed reads, checkout preservation, retries and repeated no-ops; run `make test`. Preserve review/manual gates and the [authorization boundary](../AGENTS.md).

## Tracker reconciliation

ACM-39730/39731 retain the retarget/parent-artifact follow-up. Identify the intended version and candidate from the [release evidence](current-work.md#existing-release-work), preserve unaffected evidence and refresh the parent's Key Artifacts.

Review these source concerns within that work before deciding fixes:

* Build further tracker work on [#124's merged write, readiness and recovery safeguards](https://github.com/stolostron/submariner-release-management/pull/124). Preserve best-effort [standalone writes](../scripts/lib/jira-tracker.sh) while requiring durable completion at conductor boundaries.
* `_resolve_version` treats a failed Jira query as empty before fallback. Preserve explicit versions and distinguish unavailable tracking from absence.
* [Component](../scripts/create-component-release.sh) and [FBC](../scripts/create-fbc-releases.sh) production preparation select stage YAML lexically and only warn on missing/unreadable QE approval. Require the actual successful, QE-approved snapshot before production; generated YAML alone is insufficient.

## Skill execution portability

The [compatibility tests](../scripts/lib/test-skills-compatibility.sh) retain five overlapping debt categories for [konflux-ci-fix](../skills/konflux-ci-fix/SKILL.md). When moving host-specific execution into scripts, preserve its PR, branch and repository diagnosis inputs, decision and mutation boundaries, and isolated, resumable evidence. A narrow task-bump helper does not replace that scope. The [archived design](https://github.com/stolostron/submariner-release-management/blob/77c856ee43238a92a4c88a3b4be2f5e2bd24b5c4/plans/claude-codex-skill-compatibility.md) retains the unfinished non-mutating Claude/Codex acceptance matrix for checkout and installed-plugin hosts; discovery tests alone do not qualify execution portability.
