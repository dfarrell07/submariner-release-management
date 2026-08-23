# Update Bundle SHAs

**When:**

- **Step 3b (Y-stream only):** Initial SHA update before bundle Konflux setup
- **Step 7 (Y and Z stream):** Pre-release SHA update to get latest component builds

> **Automated:** `/autorelease` handles this step automatically (Step 7 path). Follow
> the manual steps below only if debugging or running without the conductor.

## Process

Update bundle CSV with component image SHAs from Konflux snapshot builds.

**Repo:** <https://github.com/submariner-io/submariner-operator>
**Local:** `~/go/src/submariner-io/submariner-operator`

**Workflow:** `.agents/workflows/bundle-sha-update.md`

**Important:** Bundle must use `registry.redhat.io/rhacm2/*` URLs (not `quay.io/submariner/*`) for EC to pass. The workflow handles this correctly.

## Done When

Workflow verification script outputs: `✅ All SHAs verified - bundle matches snapshot!`
