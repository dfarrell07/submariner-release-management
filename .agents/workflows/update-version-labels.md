# Update Component Versions

**When:** Z-stream releases, before cutting upstream release. Y-stream initial versions are set by component setup.

Use the `update-version-labels` skill or `scripts/update-version-labels.sh`, passing the requested full release version
and optional repository filter. The script fetches current source branches, prepares signed-off commits and emits
publication commands. Autorelease executes those commands and stops for review.

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
