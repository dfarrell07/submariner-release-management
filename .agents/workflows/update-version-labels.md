# Update Component Versions

**When:** Every release, before cutting the upstream release. A Z-stream (0.21.1 → 0.21.2) always needs new versions.
A Y-stream (0.21 → 0.22) gets its initial versions in Step 3 (Fix Tekton Config PRs), but they can be copied from the
previous release (0.25.0 images reported v0.24.2), so check them here.

`/autorelease` runs this step on both streams. It opens PRs only for repos whose release branch is wrong, waits for
them to merge, and completes once every repo matches, straight away if none needed changes.

| Repo | Component Dockerfiles |
| --- | --- |
| `submariner-operator` | operator |
| `submariner` | gateway, globalnet, route-agent |
| `lighthouse` | agent, coredns |
| `shipyard` | nettest |
| `subctl` | subctl |

The eight component Dockerfiles must have matching image labels and, for Go builds, compiled versions. The shared version helper
sets Go version linker assignments, including the operator's default component image versions, to the literal target
release. It preserves source-branch arguments and commit identifiers. This avoids a pipeline's `BASE_BRANCH` override
silently compiling branch-named binaries into release-labeled images.

Bundle metadata belongs to Step 7: `bundle-image-update.sh` regenerates the CSV and updates its Dockerfile labels
in the same operation. Changing bundle labels alone creates an image whose declared version disagrees with its CSV.

After review and merge, verify the rebuilt images for the exact candidate: inspect image labels and compiled binary
versions. Source checks and PR merges establish readiness to rebuild; they do not prove the resulting image payloads.

**Next:** Complete the remaining build-readiness steps before cutting upstream release.
