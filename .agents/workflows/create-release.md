# Create Component Stage Release

**When:** After bundle SHAs updated (Step 7)

> **Automated:** `/autorelease` handles this step automatically. Follow the manual
> steps below only if debugging or running without the conductor.

## Process

Create basic Release CR YAML for stage release (without release notes).

**Repo:** <https://github.com/stolostron/submariner-release-management> (this repo)
**Local:** `~/konflux/submariner-release-management`

**Output:** `releases/0.X/stage/`

**Note:** Release notes added in Step 9, applied in Step 10, then prod (Step 15) copies complete stage YAML

### Finding Snapshots

```bash
oc get snapshots -n submariner-tenant --sort-by=.metadata.creationTimestamp
oc get snapshot <name> -n submariner-tenant \
  -o jsonpath='{.metadata.annotations.test\.appstudio\.openshift\.io/status}' \
  | jq
```

Look for snapshots where all tests show `"status": "TestPassed"`.

### Creating Release YAML

1. Copy existing stage YAML
2. Update `metadata.name` and `spec.snapshot`
3. Remove `spec.data.releaseNotes` section (if present from copied YAML)
4. Commit and push base stage YAML

**Next:** Proceed to Step 9 to add release notes

**Important:** Don't apply yet - Step 10 will apply after notes are added.

### Validation

Releases: `make test` (local validation only)

Markdown: `npx markdownlint-cli2 "**/*.md"`

## Done When

Base stage YAML created, committed, and pushed. Step 9 will add notes and commit again, then Step 10 will apply.

```bash
# Verify file pushed to remote (origin/main advances only on an actual push)
git ls-tree -r --name-only origin/main releases/0.X/stage/submariner-0-X-Y-stage-*.yaml
```
