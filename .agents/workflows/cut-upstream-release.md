# Cut Upstream Release

**When:** Y-stream (0.20 → 0.21) and Z-stream (0.20.1 → 0.20.2) releases

## Process

Create upstream release tags across all Submariner repos using the releases tool.

**Repo:** <https://github.com/submariner-io/releases>
**Local:** `~/go/src/submariner-io/releases`

**Workflow:** Follow `README.md` in that repo. Key steps:

1. Ensure the upstream release branches exist on all repos (Step 1 prerequisite for
   Y-stream; for Z-stream, branches already exist from the Y-stream setup).

2. Run the releases tool to create the `v$VERSION` tag on each upstream repo and
   trigger the build pipelines. From `~/go/src/submariner-io/releases`:

   ```bash
   # Replace 0.X.Y with the actual version (e.g. 0.24.1)
   make release VERSION=0.X.Y
   ```

3. Verify the tag exists on the primary repo before declaring done:

   ```bash
   gh release view v0.X.Y --repo submariner-io/submariner-operator
   # Should show the release with the correct tag
   ```

4. Verify the tag was created on all other repos:

   ```bash
   for repo in submariner lighthouse shipyard subctl; do
     echo -n "$repo: "
     git ls-remote --tags https://github.com/submariner-io/$repo refs/tags/v0.X.Y \
       | grep -q refs/tags && echo "tag exists" || echo "MISSING"
   done
   ```

5. Monitor the Konflux build pipelines triggered by the tag push. Images are
   published to `quay.io/submariner/*` when the pipelines complete.

## Done When

`v$VERSION` tag exists on `submariner-operator` and all other upstream repos:

```bash
gh release view v0.X.Y --repo submariner-io/submariner-operator
# Should show: tag: v0.X.Y  (not 404)

git ls-remote --tags https://github.com/submariner-io/submariner-operator refs/tags/v0.X.Y
# Should show: <sha>  refs/tags/v0.X.Y
```
