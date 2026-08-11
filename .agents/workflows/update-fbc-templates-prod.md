# Update FBC Templates with Prod URLs

**When:** After FBC prod releases complete (Step 18), before quay.io URLs expire (~90 days)

## Process

Update FBC catalog templates to use prod registry.redhat.io bundle URLs instead of temporary quay.io URLs.

**Repo:** <https://github.com/stolostron/submariner-operator-fbc>
**Local:** `~/konflux/submariner-operator-fbc`

**Workflow:** `~/konflux/submariner-operator-fbc/.agents/workflows/update-prod-url.md`

## Why Optional

- Quay.io URLs valid for ~90 days after release
- Not urgent for current release
- Prevents future breakage when URLs expire
- Good practice: templates should reference stable prod URLs

## Done When

- Template file updated with registry.redhat.io URLs (renders to 7 OCP catalogs)
- `make build-catalogs` verified working
- Changes committed and pushed to FBC repo
