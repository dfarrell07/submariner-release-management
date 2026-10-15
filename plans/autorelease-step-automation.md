<!-- markdownlint-disable MD013 -->

# Release tooling implementation handoff

[ACM-39732 — production URL conversion](https://redhat.atlassian.net/browse/ACM-39732), [ACM-39730 — Jira tracking](https://redhat.atlassian.net/browse/ACM-39730) and [ACM-39731 — autorelease](https://redhat.atlassian.net/browse/ACM-39731) own acceptance and progress. Follow the [work order](current-work.md#suggested-work-order); this handoff retains implementation findings absent from those trackers. [Issue #64](https://github.com/stolostron/submariner-release-management/issues/64) retains the original conductor design.

## Production URL conversion

ACM-39732 requires a standalone script, shared skill and `fbcProdUrls` wiring. Reconcile fork candidate `3cabf0e1f7526d3ef554571ffbb0a95db33bf013` with current main in an isolated worktree; it has script/wiring/tests but lacks the skill and discovery/compatibility inventory updates.

* Convert the already released bundle using its applicable OCP scope and actual release/index evidence. The candidate only warns on missing tracker snapshot data. Preserve unrelated and untracked work.
* Reuse FBC URL conversion without rerunning `update-bundle.sh`'s snapshot selection and catalog scenario. Its audit treats non-timeout registry failures as unreleased: distinguish failed reads from absence and review the final template/catalog diff.
* Fix [the conductor's](../scripts/autorelease.sh) `verify_fbcProdUrls`: local text matching accepts `submariner.v0x23y4` for 0.23.4 and `example.invalid/registry.redhat.io/bundle:unpublished`. Require exact, unique bundle/image identities and distinguish merged conversion from publication; existing auto-close checks do not prove the conversion merged.
* Reconcile the [workflow's optional timing](../.agents/workflows/update-fbc-templates-prod.md) with the conductor's required final step before wiring execution.

Use existing conductor, scope/publication, worktree and skill fixtures to cover wrong/duplicate identities, partial publication, failed reads, checkout preservation, retries and repeated no-ops; run `make test`. Preserve review/manual gates and the [authorization boundary](../AGENTS.md).

## Tracker reconciliation

ACM-39730/39731 retain the retarget/parent-artifact follow-up. Identify the intended version and candidate from the [release evidence](current-work.md#existing-release-work), preserve unaffected evidence and refresh the parent's Key Artifacts.

Review these source concerns within that work before deciding fixes:

* [Tracker writes](../scripts/lib/jira-tracker.sh) are best-effort; the conductor can advance after an unacknowledged write and cache an open-PR comment after a failed post. Decide acknowledgement/retry behavior while preserving standalone callers.
* `_resolve_version` treats a failed Jira query as empty before fallback. Preserve explicit versions and distinguish unavailable tracking from absence.
* [Component](../scripts/create-component-release.sh) and [FBC](../scripts/create-fbc-releases.sh) production preparation select stage YAML lexically and only warn on missing/unreadable QE approval. Require the actual successful, QE-approved snapshot before production; generated YAML alone is insufficient.
