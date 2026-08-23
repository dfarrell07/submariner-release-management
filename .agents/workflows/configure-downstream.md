# Configure Downstream Release

**When:** Y-stream only (0.20 → 0.21)

> **Automated:** `/autorelease` handles this step automatically. Follow the manual
> steps below only if debugging or running without the conductor.

**Prerequisites:** Step 1 (Create Upstream Release Branch) must complete first. This step triggers the Konflux bot to
detect new branches and generate Tekton config PRs for Step 3. If branches don't exist, manual bot re-triggering via UI
would be required.

## Process

Configure Konflux for new Submariner version.

**Repo:** <https://gitlab.cee.redhat.com/releng/konflux-release-data>
**Local:** `~/konflux/konflux-release-data`

**Workflow:** `~/konflux/konflux-release-data/tenants-config/cluster/kflux-prd-rh02/tenants/submariner-tenant/CLAUDE.md`

## Done When

- PR merged in konflux-release-data repo with new release plans
- ReleasePlan files exist in konflux-release-data repo:

  ```bash
  cd ~/konflux/konflux-release-data
  git ls-tree -r --name-only origin/main tenants-config/cluster/kflux-prd-rh02/tenants/submariner-tenant/overlay/application-submariner/ | grep "0-X-overlay"
  # Should show multiple files in 0-X-overlay directory including release-plan patches
  # If empty or stale, fetch first (requires VPN): git fetch origin
  ```

- ArgoCD has deployed ReleasePlans to cluster (requires `oc login --web https://api.kflux-prd-rh02.0fk9.p1.openshiftapps.com:6443/`):

  ```bash
  oc get releaseplans -n submariner-tenant | grep -E "stage-0-X|prod-0-X"
  # Should show: submariner-release-plan-stage-0-X and submariner-release-plan-prod-0-X
  ```
