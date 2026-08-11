# Apply FBC Releases

**Used by:** Step 13 (stage), Step 18 (prod)

## Process

Apply all FBC YAMLs to cluster (one per OCP version: 4-16 through 4-22).

**Repo:** `~/konflux/submariner-release-management`

## Apply Releases

Agent provides user with commands for each OCP version:

```bash
# For stage (Step 13):
make test-remote FILE=releases/fbc/4-XX/stage/submariner-fbc-4-XX-stage-YYYYMMDD-01.yaml
make apply FILE=releases/fbc/4-XX/stage/submariner-fbc-4-XX-stage-YYYYMMDD-01.yaml
make watch NAME=submariner-fbc-4-XX-stage-YYYYMMDD-01

# For prod (Step 18):
make test-remote FILE=releases/fbc/4-XX/prod/submariner-fbc-4-XX-prod-YYYYMMDD-01.yaml
make apply FILE=releases/fbc/4-XX/prod/submariner-fbc-4-XX-prod-YYYYMMDD-01.yaml
make watch NAME=submariner-fbc-4-XX-prod-YYYYMMDD-01
```

Replace `4-XX` with OCP version and `YYYYMMDD` with date from create step.

## Done When

All FBC releases running and completed successfully.

```bash
# Verify all releases on cluster
oc get releases -n submariner-tenant | grep -E "fbc.*(stage|prod)" | sort

# Verify files in repo (expect: 7 at Step 13 stage, 14 at Step 18 after prod added)
git ls-tree -r --name-only origin/main releases/fbc/ | grep -E "(stage|prod)" | wc -l
```
