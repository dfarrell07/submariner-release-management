# Update Component Version Labels

**When:** Z-stream (0.21.1 → 0.21.2) before cutting upstream release

**Note:** For Y-stream (0.21 → 0.22), initial versions are set as part of Step 3 (Fix Tekton Config PRs).

## Process

Update Konflux Dockerfile `version` labels and compiled `-X` versions to match the upcoming release version.
This enables `{{ labels.version }}`
tag expansion in Konflux ReleasePlanAdmission.

**Repos with components** (all in <https://github.com/submariner-io>):

| Repo                  | Files | Component(s)                                                      |
| --------------------- | ----- | ----------------------------------------------------------------- |
| `submariner-operator` | 2     | submariner-operator, submariner-bundle                            |
| `submariner`          | 3     | submariner-gateway, submariner-globalnet, submariner-route-agent  |
| `lighthouse`          | 2     | lighthouse-agent, lighthouse-coredns                              |
| `shipyard`            | 1     | nettest                                                           |
| `subctl`              | 1     | subctl                                                            |

**Total:** 9 Dockerfiles across 5 repos

**Local:** `~/go/src/submariner-io/`

### Determine Version

Check current and next version:

```bash
cd ~/go/src/submariner-io/submariner-operator
git fetch origin
git tag -l "v0.21*" | sort -V | tail -3  # Shows: v0.21.0, v0.21.1, v0.21.2
# Next release: v0.21.3
```

### Update Each Repo

For each repo, update the LABEL `version` line and the ldflags `-X` version values. `make update-version-labels`
does both, and bundle SHA updates stop if they disagree.

**Bundle note:** `bundle.Dockerfile.konflux` has 3 version labels with `LABEL` prefix:

```bash
# In submariner-operator repo, also update bundle (different format):
sed -i \
  -e 's/^LABEL csv-version="0.21.2"/LABEL csv-version="0.21.3"/' \
  -e 's/^LABEL release="v0.21.2"/LABEL release="v0.21.3"/' \
  -e 's/^LABEL version="v0.21.2"/LABEL version="v0.21.3"/' \
  bundle.Dockerfile.konflux
```

```bash
# Example for submariner repo (3 files), bumping 0.21.2 → 0.21.3
cd ~/go/src/submariner-io/submariner
git checkout origin/release-0.21 -b fix-version-labels-0.21.3

# Update the version label and compiled version (gitCommitHash stays as is)
sed -i -E -e 's/^( *)version="v0.21.2"/\1version="v0.21.3"/' \
  -e 's#(-X[ =][^ "\\=]*[vV]ersion=)[^ "\\]+#\1v0.21.3#' \
  package/Dockerfile.submariner-gateway.konflux \
  package/Dockerfile.submariner-globalnet.konflux \
  package/Dockerfile.submariner-route-agent.konflux

git add -A && git commit -s -m "Align component versions to v0.21.3

Match image labels and compiled Go versions."

git push origin fix-version-labels-0.21.3 && gh pr create \
  --base release-0.21 --head fix-version-labels-0.21.3 \
  --title "Align component versions to v0.21.3" \
  --body "Match image labels and compiled Go versions." --assignee @me
```

Repeat for all 5 repos:

| Repo                  | Dockerfile path(s)                                                                 |
| --------------------- | ---------------------------------------------------------------------------------- |
| `submariner-operator` | `package/Dockerfile.submariner-operator.konflux`, `bundle.Dockerfile.konflux`      |
| `submariner`          | `package/Dockerfile.submariner-{gateway,globalnet,route-agent}.konflux`            |
| `lighthouse`          | `package/Dockerfile.lighthouse-{agent,coredns}.konflux`                            |
| `shipyard`            | `package/Dockerfile.nettest.konflux`                                               |
| `subctl`              | `package/Dockerfile.subctl.konflux`                                                |

### Wait for Rebuilds

After PRs merge, wait for Konflux to rebuild (~15-30 min):

```bash
oc get snapshots -n submariner-tenant --sort-by=.metadata.creationTimestamp | grep "submariner-0-21" | tail -3
```

## Done When

Verify one built image has correct label:

```bash
SNAPSHOT=$(oc get snapshots -n submariner-tenant --sort-by=.metadata.creationTimestamp | grep "submariner-0-21" | tail -1 | awk '{print $1}')
IMAGE=$(oc get snapshot $SNAPSHOT -n submariner-tenant -o jsonpath='{.spec.components[?(@.name=="lighthouse-agent-0-21")].containerImage}')
skopeo inspect "docker://$IMAGE" | jq -r '.Labels.version'
# Should show: v0.21.3
```

Verify the compiled version too. A correct label does not prove it:

```bash
mkdir -p /tmp/lighthouse-agent
oc image extract "$IMAGE" --filter-by-os=linux/amd64 --path "/usr/local/bin/:/tmp/lighthouse-agent/" --confirm
go version -m /tmp/lighthouse-agent/* | grep -o -- '-X main.version=[^ "]*'
# Should show: -X main.version=v0.21.3
```

**Next:** Proceed to Step 6 (Cut Upstream Release).
