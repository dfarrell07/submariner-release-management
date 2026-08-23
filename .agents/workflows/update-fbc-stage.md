# Update FBC Catalog with Stage Bundle

**When:** After stage release completes (Step 10)

> **Automated:** `/autorelease` handles this step automatically. Follow the manual
> steps below only if debugging or running without the conductor.

## Process

Update catalog in FBC repo with bundle from completed stage release.

**Repo:** `~/konflux/submariner-operator-fbc`

**Workflow:** Follow `CLAUDE.md` in FBC repo → `.agents/workflows/update-catalog.md`

## Done When

For each OCP version (4-16 through 4-22):

```bash
# 1. Check latest snapshot created after catalog update
oc get snapshots -n submariner-tenant --sort-by=.metadata.creationTimestamp | grep "^submariner-fbc-4-XX" | tail -1

# 2. Verify both tests pass
SNAPSHOT="submariner-fbc-4-XX-xxxxx"
oc get snapshot $SNAPSHOT -n submariner-tenant -o jsonpath='{.metadata.annotations.test\.appstudio\.openshift\.io/status}' | jq -r '.[] | "\(.scenario): \(.status)"'
# Both must show: TestPassed
```

Record snapshot names for all OCP versions - needed for Step 12.

### Retrigger Failed Push Builds

If a push build fails due to an infra flake (e.g., `PipelineValidationFailed` with all tasks passing), retrigger
with a `/retest` comment on the HEAD commit of the target branch:

```bash
# Find the HEAD commit
gh api repos/stolostron/submariner-operator-fbc/commits/main --jq '.sha'

# Add /retest comment (retriggers all push pipelines for that commit)
gh api repos/stolostron/submariner-operator-fbc/commits/<sha>/comments -f body="/retest"
```

The retested build uses the same push pipeline and produces permanent images (no expiration).
