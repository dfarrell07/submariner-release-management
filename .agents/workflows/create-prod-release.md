# Create Component Prod Release

**When:** After QE approval (following Step 14)

> **Automated:** `/autorelease` handles this step automatically. Follow the manual
> steps below only if debugging or running without the conductor.

## Process

Create prod YAML with QE-verified release notes.

### Workflow

1. **Read verified stage YAML**
   - Stage YAML has QE-verified release notes
   - Located in `releases/0.X/stage/submariner-0-X-Y-stage-*.yaml`

2. **Create prod YAML by copying stage**
   - Change `metadata.name` (stage → prod, update date if needed)
   - Change `spec.releasePlan` (stage-0-X → prod-0-X)
   - Keep `spec.snapshot` the same (tested snapshot from stage)
   - Keep `spec.data.releaseNotes` the same (verified notes from stage)
   - Save to `releases/0.X/prod/submariner-0-X-Y-prod-*.yaml`

3. **Commit prod YAML**
   - Commit prod YAML
   - User reviews and pushes
   - Documents what will be released to production

## Done When

Prod YAML created, committed, and pushed. Ready for Step 16 to apply to cluster.

```bash
# Verify file pushed to remote (origin/main advances only on an actual push)
git ls-tree -r --name-only origin/main releases/0.X/prod/submariner-0-X-Y-prod-*.yaml
```
