# OCP 5 FBC completion and rollout

Historical September 24 preparation record. For current tracking and execution gates use the [work map](current-work.md) and [rollout
plan](ocp-5-0-fbc-rollout.md): ACM-48092 owns automation and ACM-48200 owns catalog delivery. PR #119 proposes retiring this record;
its old source pins and then-pending remote actions are not today's queue.

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

Use the current [rollout gates](ocp-5-0-fbc-rollout.md). The old separate drafts, DNS failure and four-batch sequence are historical;
reconcile the submitted MR and #82/#119/#120, including their unresolved pre-GA readiness path. Configuration, actual build,
installation/QE and publication remain distinct evidence states.
