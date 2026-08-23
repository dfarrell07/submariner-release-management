# Create FBC Prod Releases

**When:** After QE approval (Step 14 complete)

> **Automated:** `/autorelease` handles this step automatically. Follow the manual
> steps below only if debugging or running without the conductor.

## Process

Create production Release CRs by copying stage YAMLs and changing 2 fields.

**Key concept:** Prod FBC releases use SAME snapshots as stage. Catalog already has bundle with quay.io URL which works for both
stage and prod (bundle is mirrored). Catalog update to registry.redhat.io URL happens much later when quay.io images are cleaned up
(months after release).

**Repo:** `~/konflux/submariner-release-management`

## Creating Prod YAMLs

Agent creates prod YAML for each OCP version (4-16 through 4-22):

```bash
# Copy from stage
cp releases/fbc/4-XX/stage/submariner-fbc-4-XX-stage-YYYYMMDD-01.yaml \
   releases/fbc/4-XX/prod/submariner-fbc-4-XX-prod-YYYYMMDD-01.yaml

# Edit 2 fields:
#   metadata.name: submariner-fbc-4-XX-stage-YYYYMMDD-01 → submariner-fbc-4-XX-prod-YYYYMMDD-01
#   spec.releasePlan: submariner-fbc-release-plan-stage-4-XX → submariner-fbc-release-plan-prod-4-XX
# Keep spec.snapshot identical (same as stage)
```

## Commit

```bash
git add releases/fbc/
git commit -s -m "Add FBC prod releases"
```

User reviews commit, then pushes.

## Done When

FBC prod YAMLs created, committed, and pushed. Ready for Step 18 to apply to cluster.

```bash
# Verify files pushed to remote (expect: 4-16 through 4-22)
git ls-tree -r --name-only origin/main releases/fbc/*/prod/*.yaml
```
