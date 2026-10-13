# OCP 5 FBC completion and rollout

October 7 navigation: the dated preparation and validation records below are historical.
Use [current work](current-work.md) and the [consolidated rollout plan](ocp-5-0-fbc-rollout.md)
for current PR/configuration state and execution order. Catalog/tooling #76/#81 are merged;
pipeline #82 remains open with a missing build-account failure.
The original "nothing pushed" and "no catalog/PR" statements describe September 24, not current reality.

Updated 2026-09-24. Local implementation is complete: the reusable skill, real
5.0 catalog, tenant/admission resources and four-platform pipelines are committed.
The user authorized existing provisional inputs: minimum **0.24**, default channel
`stable-0.24`, head **0.24.1**. Complete preparation, authenticated FBC checks and
the real OCP 5.0 native image validation/gRPC test passed. See
[status and evidence](ocp-5-implementation-status.md). No new skill framework or
unanswered catalog-input question remains.

## Reproduce local preparation

Reuse these independent cached source pins and existing workspace. Keep the
task-owned `TMPDIR`: the system `/tmp` previously hit its quota.

```bash
export TMPDIR=/home/dfarrell07/konflux/ocp-5-skill-work/tmp
./skills/add-fbc-ocp-version/scripts/run.sh 5.0 \
  --min-supported-sub 0.24 \
  --release-data-repo /home/dfarrell07/konflux/konflux-release-data \
  --release-data-ref 8c18efee295889f5d86b03d16930a2f11977fd58 \
  --fbc-repo /home/dfarrell07/konflux/ocp-5-skill-work/fbc-tooling \
  --fbc-ref f641fb9 \
  --workspace /home/dfarrell07/konflux/ocp-5-work \
  --kustomize /home/dfarrell07/konflux/ocp-5-work/bin/kustomize \
  --phase prepare
./skills/add-fbc-ocp-version/scripts/run.sh 5.0 \
  --workspace /home/dfarrell07/konflux/ocp-5-work --phase test-image
```

The inclusive minimum produces `"5.0": "0.23"` in the drop-through map. The
catalog retains 0.24.0 and 0.24.1 with their existing digests and upgrade graph.
The 0.24.1 bundle's `v4.15-v4.19` declaration is unchanged; this provisional
catalog does not establish runtime compatibility on OCP 5.

## Remaining remote rollout

1. Refresh/rebase the separate configuration drafts when GitLab DNS is available;
   cached source pins are not fresh-main evidence. Review/publish the completed
   changes and reconcile configuration. Check required PR contexts and app IDs at
   the exact current head using effective rulesets as well as legacy protection.
2. After merge, run `--phase verify-live --expected-commit <merged-40-character-sha>`.
   Require matched admissions/account bindings, the original push build and tested
   snapshot, all four image platforms and catalog contents matching merged source.
3. Verify installation of the selected bundle on an observed 5.0.x cluster. Confirm
   profile access and actual install-task execution; use the existing explicit-bundle
   QE procedure if the generic ITS skips the released bundle. Update the bundle if
   compatibility testing requires it. Stage and prod must use the same QE-approved
   snapshot. Verify public-index membership before activating `5-0` in default scope.

Deployment, multiarch build, installation and release remain separate evidence
states. The [canonical workflow](../.agents/workflows/add-fbc-ocp-version.md)
contains their exact checks. The earlier four-batch plan is preserved at `296fca8`.
