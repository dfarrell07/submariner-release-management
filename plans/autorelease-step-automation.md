<!-- markdownlint-disable MD013 -->

# Autorelease: current implementation and remaining work

Source checked October 15, 2026 against main `f071c65c`. The scripts define behavior; this plan retains missing wiring and concrete review questions. [Current work](current-work.md) routes release evidence and [Jira tracking](jira-update-queue.md) records workflow decisions.

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

## Delivered behavior to retain

Main includes tracker integration, component fan-out, worktree restoration, task/CVE/EC remediation, active-host release-note review and the completed EC/FBC/exact-artifact gates from #114/#117. Reuse those scripts and the [recovery workflow](../.agents/workflows/create-fbc-stage-release.md#recover-a-policy-rejected-image). Source setup, PR merge, build, installation, QE and publication remain distinct evidence states.

EC task-bump return codes are 0 for committed updates, 1 for failure/remaining active denial, and 2 for a manual diagnostic stop. Shared [log parsing](../scripts/lib/parse-ec-log.sh) and [deny-rule checks](../scripts/lib/deny-rules.sh) handle diagnosis; unavailable policy data is unchecked. The [historical records](jira-audit-records.md#historical-source-index) retain the delivered EC/deny designs without a second implementation backlog.

## Remaining work, in order

| Work | Concrete next action | Acceptance boundary |
| --- | --- | --- |
| QE installation of the staged 0.23.4 catalogs | Use the [verified handoff](../releases/fbc/qe-0.23.4-stage-20261012.md) for all six applicable targets | Select the intended channel/CSV and approved stage mirrors; installation/QE remains separate from successful publication |
| Retarget and parent artifacts | Reconcile ACM-44527/ACM-45070 observations before designing an explicit retarget operation | Preserve version/snapshot identity, invalidate only affected evidence, refresh parent artifacts and read back tracker state |
| Prod URL conversion, existing ACM-39732 | Review the existing candidate and verifier together; see [handoff](#production-url-conversion) | Standalone script/skill and conductor wiring, exact released-bundle conversion, preserved content/worktrees and verified merged output |
| Skill execution portability | Finish konflux-ci-fix normalization and installed-host matrix in [compatibility plan](claude-codex-skill-compatibility.md) | Five overlapping known debt entries removed and meaningful Claude/Codex execution evidence, beyond discovery tests |
| Addon setup proposal | Resolve current ART/addon ownership and supported branch/version inputs before using [addon proposal](addon-tekton-setup.md) | No `tektonAddon` exists today; do not blindly derive ACM 5.x from the old arithmetic mapping |

These are existing scopes; completed implementation designs and unselected retrospective story splits are not prerequisites.

## Production URL conversion

Fork candidate `3cabf0e1f7526d3ef554571ffbb0a95db33bf013` adds `scripts/update-fbc-prod-urls.sh`, conductor wiring and tests. No PR was returned for that head; it has no standalone skill, which ACM-39732 explicitly requires. Reconcile against main in an isolated worktree before proposing it.

* Select actual applicable OCP scope, successful production/index evidence and the QE-approved stage identity. The draft's preflight only warns on missing tracker snapshot data; it never verifies successful Releases. One OCP Release cannot establish completion for every target. Preserve unrelated/untracked work; move tracker writes after validated prerequisites.
* Convert the already released bundle without selecting a newer component snapshot. FBC main's `update-bundle.sh` selects/verifies a snapshot, runs a catalog scenario and audits **all** temporary bundle URLs. Its audit treats non-timeout registry errors as unreleased; distinguish authentication/network failures from genuine absence before reusing it. Compare final template/catalog contents and digests, including unrelated entries.
* Correct `verify_fbcProdUrls` before relying on it at the conductor boundary. It reads local template text, uses a version regex with unescaped dots and a registry substring, and does not check merge/publication. Isolated calls on current source return success for `submariner.v0x23y4` requested as 0.23.4 and for `example.invalid/registry.redhat.io/bundle:unpublished`. Parse exact unique bundle identity and image registry/repository/digest; verify the intended merged template and required release/index evidence separately.
* Supply the standalone shared skill/delegate and update discovery/compatibility inventories when it is added. Reconcile the old workflow's optional/deferred wording with the conductor's required final completion step; retain the review boundary.

Before wiring, prove wrong/duplicate versions, misleading registries, unmerged local changes, partial OCP publication and failed reads cannot complete the step. Cover stable candidate selection, isolated dirty/untracked work, failure recovery and a repeated no-op. Run `test-autorelease`, relevant scope/publication/worktree/skill checks and `make test`; inspect the actual generated diff before any external action.

## Source risks requiring a focused follow-up

These source observations identify review questions, not authorization for an implementation change. Establish a meaningful failure case and reconcile current tests before fixing one.

* **Jira write acknowledgement.** `update_step` deliberately returns success on tracking failures. `try_auto_verify` can return verified success after that call,
  and its caller advances in memory. Preserve best-effort behavior for standalone scripts while considering explicit write/read-back acknowledgement at conductor boundaries.
  Its open-PR comment cache is also written after a best-effort comment attempt; ensure a failed post can be retried.
* **Version discovery read failure.** `_resolve_version` still converts a failed tracker query to an empty string before downstream/upstream fallbacks.
  Distinguish an unavailable source from a genuinely absent tracker; explicit supplied versions must retain their existing behavior.
* **Stage snapshot identity.** Both production generators choose stage YAML with lexical `sort | tail -1`.
  Multiple historical or redo files can select the wrong candidate. Resolve actual applied/QE-approved identity or reject ambiguity;
  stage/prod must reference the same approved snapshot for every target. Both generators deliberately treat missing/unreadable QE sign-off as advisory and can still generate/commit YAML; validate approval and exact identity at the human apply gate. Generated files and their console wording are not QE evidence.
* **Review redo and partial recovery.** `print_review_stop` supplies review/pending-action guidance but does not expose a distinct redo path.
  `--refresh` may leave duplicate generated YAMLs and does not necessarily invalidate a decorating step's producer.
  In-progress scripted steps without a verifier can rerun; preserve untracked/partial output and avoid creating duplicate releases or PRs.
* **Verification return codes.** `try_auto_verify` marks a step attempted before running its verifier, so same-run re-entry returns not-done.
  Recheck retry/wait/precondition routing in the current integration harness before changing this guard.
* **Provenance and freshness.** Tag existence and a tag-time warning are not component-image provenance. A changed bundle digest is not by itself proof that every
  `relatedImages` pin belongs to the intended rebuilt release. Preserve source/snapshot/digest attribution at review and release gates.
* **Concurrent execution.** No conductor lock was found. Different patch releases of one minor share branches and snapshot inputs as well as identical-version runs.
  Before implementing concurrency, define lock scope and verify no repo/STEP_DATA/push-log collisions.
* **Rulesets and task trust.** Historical FBC topic-branch rejection and allowlist incidents need current ruleset/app-id and resolved policy/trust/deny evidence; bundle expiry alone does not establish the active policy gate.
  Do not prescribe an admin push workaround or reuse an expired trusted pin from an incident account.

## Implementation contract and validation

Implementation changes must validate inputs and applicable scope, preserve the original directory/ref and unrelated work,
and expose reviewable artifacts plus pending external actions. A tracking write records only the evidence actually observed;
local creation, PR merge, build, install, QE and publication are separate states. Network/auth failures must not become absence or completion.
Verifier bodies read external state; the conductor wrapper can write their results. Exit codes and completion semantics follow each current script,
not an old universal exit-0/mark-complete assumption. EC's nothing-to-update return remains a separate diagnostic stop.

For any implementation change, run its focused target plus `make test`.
The existing targets include `test-autorelease`, `test-conductor`, `test-tracker`, `test-worktree-safety`, `test-component`,
`test-fbc-snapshot`, `test-fbc-scope`, `test-prod-bundle`, `test-deny-rules`, `test-version-bump` and `test-skills`.
Use failure/read/write-acknowledgement and actual routing scenarios where they establish behavior; avoid test counts as a release-readiness claim.
The entitlement fixture intermittently fails different assertions under highly parallel full-suite runs while all 127 checks pass in isolation and the full suite passed with four-CPU affinity. Its `printf | grep -q` assertions run under `pipefail`; reproduce the failed assertion before a separate test-harness fix. This is not evidence of a product entitlement defect. No conductor or release operation was run by this review.
