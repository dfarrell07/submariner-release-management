<!-- markdownlint-disable MD013 -->

# Autorelease: current implementation and remaining work

Source review: October 7, 2026, release-management `2ecac9d`. This replaces the repeated completed-phase designs,
shelved apply/parallel proposals and obsolete invocation walkthroughs. Earlier implementation history remains in Git at `2ecac9d`;
the pre-edit working documents were also preserved locally. The scripts are the executable contract.
Current release evidence is in [current work](current-work.md), and posting/closure decisions in [the assigned-issue queue](jira-update-queue.md).

## Scope and authorization

The conductor prepares artifacts, records progress and verifies external state. Cluster apply/watch and QE are explicit handoffs.
Normal execution writes Jira and attempts pushes, PR creation and auto-merge setup at review stops;
AGENTS.md requires explicit authorization before that run. `--dry-run` is the read-only preview, with conditional verification and success assumptions.
A plan, a green unit suite or reaching a review stop does not establish release success.
Cluster apply automation remains shelved; no new apply, DAG, monitoring or parallel-conductor project is proposed here.

## Current step wiring

Source: [jira-tracker.sh](../scripts/lib/jira-tracker.sh) and [autorelease.sh](../scripts/autorelease.sh).
The metadata's automation level and the existence of a script/verifier are separate facts; `auto` on a hint does not make it a script.

| Step | Level | Script | External verifier |
| --- | --- | --- | --- |
| `createBranches` | review | — | `verify_createBranches` |
| `configureDownstream` | review | `scripts/configure-downstream.sh` | — |
| `tektonComponents` | review | `scripts/tekton-component-setup.sh` | — |
| `tektonBundle` | review | `scripts/konflux-bundle-setup.sh` | — |
| `rpmLockfiles` | review | `scripts/rpm-lockfile-update.sh` | `verify_rpmLockfiles` |
| `versionLabels` | review | `scripts/update-version-labels.sh` | `verify_versionLabels` |
| `tektonTasks` | review | `scripts/tekton-task-refs-update.sh` | `verify_tektonTasks` |
| `cveFixes` | review | `scripts/cve-fixes-update.sh` | `verify_cveFixes` |
| `ecFixes` | review | `scripts/tekton-task-version-bump.sh` | `verify_ecFixes` |
| `upstreamRelease` | gate | — | `verify_upstreamRelease` |
| `bundleShas` | review | `scripts/bundle-image-update.sh` | — |
| `componentStage` | review | `scripts/create-component-release.sh` | — |
| `releaseNotes` | review | `scripts/add-release-notes.sh` | — |
| `fbcCatalogUpdate` | review | `scripts/fbc-catalog-update.sh` | — |
| `fbcStageReleases` | review | `scripts/create-fbc-releases.sh` | — |
| `qeValidation` | gate | — | — |
| `componentProd` | review | `scripts/create-component-release.sh` | — |
| `fbcProdReleases` | review | `scripts/create-fbc-releases.sh` | — |
| `fbcProdUrls` | auto | — | `verify_fbcProdUrls` |

Y-stream-only: createBranches, configureDownstream, tektonComponents and tektonBundle. Z-stream-only: versionLabels.
Other steps are shared. Gate/hint steps can advance through verification; an in-progress scripted step with a verifier also checks external state before rerunning.
The old claims that scripts and verifiers never coexist, component fan-out is unimplemented, or build-readiness steps auto-chain are retired.

## Delivered behavior to retain

* `--complete`/`--refresh`, step ordering, tracker read validation, conditional dry-run, preflight reporting and propagation diagnostics exist.
  `find_next_step` refuses failed/empty/non-array tracker reads; `_resolve_version` has a separate fallback read path discussed below.
* Component fan-out, bundle setup, task-reference updates, CVE wrappers, EC task-version/parser/deny-rule handling and FBC catalog updates are implemented.
  Source details belong in scripts and their focused tests, not duplicate pseudocode here.
* PR-merge verifiers exist for task, RPM, version-label and CVE work; EC additionally checks its snapshot. They distinguish not done, failed preconditions and open PRs.
  `try_auto_verify` records evidence and deduplicates progress output. This does not prove a failed Jira write was persisted.
* Snapshot/time staleness warnings and tracker-vs-reality drift reporting exist. Warnings do not themselves invalidate a completed step.
* October 13: merged [#114](https://github.com/stolostron/submariner-release-management/pull/114) and [#117](https://github.com/stolostron/submariner-release-management/pull/117) require completed EC/FBC evidence, exact component tags and stage identities.
  Preserve provenance and the [manual recovery boundary](../.agents/workflows/create-fbc-stage-release.md#recover-a-policy-rejected-image); reuse these helpers instead of creating another checker.
* `bundleShas` and `componentStage` are review level. `assert_bundle_rebuilt` compares selected versus recorded bundle digests and stops on equality;
  missing bookkeeping remains a disclosed limitation, not proof of freshness. Bundle snapshot selection also warns when it predates the release tag.
* Prod paths reuse a stage snapshot; they do not prove that a lexically selected YAML is the one actually approved by QE.
* Checkout/worktree safety, original-ref restoration and review-stop push attempts are implemented. Version-label success-path stranding is fixed.
  Signal/crash recovery and unpublished external skill changes need their own evidence; do not generalize handled-path tests to every interruption.
* `fbcProdUrls` has a corrected template verifier and terminal handoff, but no script on main. Linear closeout expects conversion before the all-done path.
  The older workflow's optional/deferred wording needs reconciliation; it is not an alternative completion policy to silently adopt.
* Auto-close requires the shipped bundle, nonempty actual OCP scope and every in-scope production index. Unreachable/absent probes suppress it.
  `--close` is a write fallback requiring actual release verification and appropriate treatment of unrelated/test subtasks.
* `run_conductor` is extracted outside the testing guard and covered by `make test-conductor` integration tests.
  The older claim that dispatch routing is wholly untested is obsolete. Assess remaining coverage against the current suite before filing test work.

## Remaining work, in order

| Work | Concrete next action | Acceptance boundary |
| --- | --- | --- |
| QE installation of the staged 0.23.4 catalogs | Use the [verified handoff](../releases/fbc/qe-0.23.4-stage-20261012.md) for all six applicable targets | Select the intended channel/CSV and approved stage mirrors; installation/QE remains separate from successful publication |
| Retarget and parent artifacts | Reconcile ACM-44527/ACM-45070 observations before designing an explicit retarget operation | Preserve version/snapshot identity, invalidate only affected evidence, refresh parent artifacts and read back tracker state |
| Prod URL conversion, existing ACM-39732 | Reconcile fork candidate `3cabf0e` in an isolated worktree | Actual OCP scope and QE-approved snapshot/index evidence; conversion distinct from selecting a new bundle; original/untracked work preserved. See [candidate review](current-work.md#unpublished-tooling-and-stale-roadmap-entries) |
| Skill execution portability | Finish konflux-ci-fix normalization and installed-host matrix in [compatibility plan](claude-codex-skill-compatibility.md) | Five overlapping known debt entries removed and meaningful Claude/Codex execution evidence, beyond discovery tests |
| Addon setup proposal | Resolve current ART/addon ownership and supported branch/version inputs before using [addon proposal](addon-tekton-setup.md) | No `tektonAddon` exists today; do not blindly derive ACM 5.x from the old arithmetic mapping |

These are existing scopes, not a request to create another set of Jira stories. QE validation does not depend on the proposed S/K children.
Historical roadmap items 1–9 describe delivered work; they are removed from the active backlog rather than renumbered into new work.

## Source risks requiring a focused follow-up

These observations preserve review questions from the October 7 roadmap. The reproduced FBC marker/identity issue is fixed in main;
recheck the remaining observations and establish meaningful failure cases before changing behavior.

* **Jira write acknowledgement.** `update_step` deliberately returns success on tracking failures. `try_auto_verify` can return verified success after that call,
  and its caller advances in memory. Preserve best-effort behavior for standalone scripts while considering explicit write/read-back acknowledgement at conductor boundaries.
  Its open-PR comment cache is also written after a best-effort comment attempt; ensure a failed post can be retried.
* **Version discovery read failure.** `_resolve_version` still converts a failed tracker query to an empty string before downstream/upstream fallbacks.
  Distinguish an unavailable source from a genuinely absent tracker; explicit supplied versions must retain their existing behavior.
* **Stage snapshot identity.** Both production generators choose stage YAML with lexical `sort | tail -1`.
  Multiple historical or redo files can select the wrong candidate. Resolve actual applied/QE-approved identity or reject ambiguity;
  stage/prod must reference the same approved snapshot for every target.
* **Review redo and partial recovery.** `print_review_stop` supplies review/pending-action guidance but does not expose a distinct redo path.
  `--refresh` may leave duplicate generated YAMLs and does not necessarily invalidate a decorating step's producer.
  In-progress scripted steps without a verifier can rerun; preserve untracked/partial output and avoid creating duplicate releases or PRs.
* **Verification return codes.** `try_auto_verify` marks a step attempted before running its verifier, so same-run re-entry returns not-done.
  Recheck retry/wait/precondition routing in the current integration harness before changing this guard.
* **Provenance and freshness.** Tag existence and a tag-time warning are not component-image provenance. A changed bundle digest is not by itself proof that every
  `relatedImages` pin belongs to the intended rebuilt release. Preserve source/snapshot/digest attribution at review and release gates.
* **Concurrent execution.** No conductor lock was found. Different patch releases of one minor share branches and snapshot inputs as well as identical-version runs.
  Before implementing concurrency, define lock scope and verify no repo/STEP_DATA/push-log collisions.
* **Rulesets and task trust.** Historical FBC topic-branch rejection and allowlist incidents need fresh ruleset/app-id/deny/expiry reads.
  Do not prescribe an admin push workaround or reuse an expired trusted pin from an incident account.

## Implementation contract and validation

Scripts validate inputs and applicable scope before changes, preserve the original directory/ref and unrelated work,
and expose reviewable artifacts plus pending push/apply actions. A tracking write records only the evidence actually observed;
local creation, PR merge, build, install, QE and publication are separate states. Network/auth failures must not become absence or completion.
Verifier bodies read external state; the conductor wrapper can write their results. Exit codes and completion semantics follow each current script,
not an old universal exit-0/mark-complete assumption. EC's nothing-to-update return remains a separate diagnostic stop.

For any implementation change, run its focused target plus `make test`.
The existing targets include `test-autorelease`, `test-conductor`, `test-tracker`, `test-worktree-safety`, `test-component`,
`test-fbc-snapshot`, `test-fbc-scope`, `test-prod-bundle`, `test-deny-rules`, `test-version-bump` and `test-skills`.
Use failure/read/write-acknowledgement and actual routing scenarios where they establish behavior; avoid test counts as a release-readiness claim.
Normal conductor, cluster apply, pushes and Jira transitions were not executed by this documentation review.
