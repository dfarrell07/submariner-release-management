#!/usr/bin/env bash
# Tests for the pinned base image refresh (stubbed skopeo, disposable repos, no network)
# Run: ./scripts/lib/test-pinned-base.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCKFILE_SCRIPT="$SCRIPT_DIR/../rpm-lockfile-update.sh"

PASS=0; FAIL=0
TMP=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$TMP"' EXIT

assert_eq() {
  if [ "$2" = "$3" ]; then echo "  ✓ $1"; PASS=$((PASS + 1))
  else echo "  ✗ $1"; echo "    got:  '$2'"; echo "    want: '$3'"; FAIL=$((FAIL + 1)); fi
}
assert_contains() {
  if [[ "$2" == *"$3"* ]]; then echo "  ✓ $1"; PASS=$((PASS + 1))
  else echo "  ✗ $1 (missing: '$3')"; echo "    in: $2"; FAIL=$((FAIL + 1)); fi
}
assert_not_contains() {
  if [[ "$2" != *"$3"* ]]; then echo "  ✓ $1"; PASS=$((PASS + 1))
  else echo "  ✗ $1 (unexpectedly found: '$3')"; FAIL=$((FAIL + 1)); fi
}

hex() { printf "%.0s$1" {1..64}; }
OLD="sha256:$(hex a)"
NEW="sha256:$(hex b)"
OTHER="sha256:$(hex c)"
PIN="FROM --platform=\${TARGETPLATFORM} registry.redhat.io/ubi9@$OLD"
PIN_NEW="FROM --platform=\${TARGETPLATFORM} registry.redhat.io/ubi9@$NEW"
ALL_ARCHES='{"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[
  {"platform":{"os":"linux","architecture":"amd64"}},{"platform":{"os":"linux","architecture":"arm64"}},
  {"platform":{"os":"linux","architecture":"s390x"}},{"platform":{"os":"linux","architecture":"ppc64le"}},
  {"platform":{"os":"unknown","architecture":"unknown"}}]}'
ONE_ARCH='{"mediaType":"application/vnd.oci.image.manifest.v1+json","config":{},"layers":[]}'
WINDOWS_PPC='{"manifests":[{"platform":{"os":"linux","architecture":"amd64"}},{"platform":{"os":"linux","architecture":"arm64"}},
  {"platform":{"os":"linux","architecture":"s390x"}},{"platform":{"os":"windows","architecture":"ppc64le"}}]}'

# Fresh sandbox with a stub skopeo. It logs one call per line. A raw read of a tag gets a
# single-arch manifest, so only a check of the resolved digest itself can pass.
new_sandbox() {
  SB="$TMP/sb$((++N))"
  mkdir -p "$SB/bin" "$SB/home/.docker" "$SB/base"
  export HOME="$SB/home" PATH="$SB/bin:$ORIG_PATH" SUBMARINER_BASE="$SB/base"
  export GIT_CONFIG_GLOBAL="$SB/gitconfig" GIT_CONFIG_NOSYSTEM=1
  export SKOPEO_LOG="$SB/skopeo.log" UPDATER_LOG="$SB/updater.log"
  export STUB_DIGEST="$NEW" STUB_RAW="$ALL_ARCHES" STUB_ONE_ARCH="$ONE_ARCH" UPDATER_MODE=noop
  unset STUB_INSPECT_RC STUB_RAW_RC STUB_FAIL_REPO
  git config --file "$GIT_CONFIG_GLOBAL" user.name "Test User"
  git config --file "$GIT_CONFIG_GLOBAL" user.email "test@example.com"
  echo '{"auths":{"registry.redhat.io":{}}}' > "$HOME/.docker/config.json"
  cat > "$SB/bin/skopeo" <<'STUB'
#!/bin/bash
echo "$*" >> "$SKOPEO_LOG"
ref="${*: -1}"
[ -z "${STUB_FAIL_REPO:-}" ] || [[ "$ref" != *"/$STUB_FAIL_REPO:"* ]] || { echo "stub: denied $ref" >&2; exit 1; }
case " $* " in
  *" --raw "*)
    [ "${STUB_RAW_RC:-0}" = 0 ] || { echo "stub: raw failed" >&2; exit "$STUB_RAW_RC"; }
    case "$ref" in
      *@*) printf '%s\n' "$STUB_RAW" ;;
      *) printf '%s\n' "$STUB_ONE_ARCH" ;;
    esac
    ;;
  *)
    [ "${STUB_INSPECT_RC:-0}" = 0 ] || { echo "stub: unauthorized" >&2; exit "$STUB_INSPECT_RC"; }
    jq -n --arg d "$STUB_DIGEST" '{Name: "x", Digest: $d}'
    ;;
esac
STUB
  chmod +x "$SB/bin/skopeo"
  : > "$SKOPEO_LOG"
}

# A plain directory of Dockerfiles for the helper alone. write_dockerfile NAME LINE...
new_workdir() { new_sandbox; mkdir -p "$SB/work/package"; cd "$SB/work"; }
write_dockerfile() { local f="package/$1"; shift; printf '%s\n' "$@" > "$f"; }

# Run the helper in a subshell. Sets OUT, RC and CHANGED.
refresh() {
  local result="$SB/result"
  OUT=$(
    # shellcheck source=pinned-base.sh
    source "$SCRIPT_DIR/pinned-base.sh"
    rc=0
    pinned_base_refresh "$1" 2>&1 || rc=$?
    printf '%s\n%s\n' "$rc" "${PINNED_BASE_CHANGED[*]:-}" > "$result"
  )
  { read -r RC; read -r CHANGED; } < "$result"
  CALLS=$(cat "$SKOPEO_LOG")
}

# Disposable repo under SUBMARINER_BASE, set up like a release repo. The updater only exists
# on origin/devel, as in test-worktree-safety. It records the FROM lines it can see, so tests
# can tell what the lockfiles would be resolved against. new_repo NAME [FILE LINE]...
new_repo() {
  local dir="$SUBMARINER_BASE/$1"
  shift
  mkdir -p "$dir/package" "$dir/.rpm-lockfiles/nettest" "$dir/.rpm-lockfiles/gateway"
  git init -q -b original "$dir"
  (
    cd "$dir"
    git config core.hooksPath /dev/null
    git config commit.gpgsign false
    echo 'baseline lockfile' > .rpm-lockfiles/nettest/rpms.lock.yaml
    echo 'baseline lockfile' > .rpm-lockfiles/gateway/rpms.lock.yaml
    while [ "$#" -gt 0 ]; do
      printf 'ARG BASE_BRANCH=release-0.25\n\n%s\nARG BASE_BRANCH\n' "$2" > "package/$1"
      shift 2
    done
    git add -A
    git commit -qm base
    git branch release-0.25
    git checkout -qb devel
    cat > .rpm-lockfiles/update-lockfile.sh <<'FIXTURE'
#!/bin/bash
echo "ARGS $*" >> "$UPDATER_LOG"
grep -h '^FROM' package/*.konflux >> "$UPDATER_LOG" 2>/dev/null
case "$UPDATER_MODE" in
  lock) echo 'updated lockfile' > .rpm-lockfiles/nettest/rpms.lock.yaml ;;
  scratch) echo 'updated lockfile' > .rpm-lockfiles/nettest/rpms.lock.yaml; echo x > .rpm-lockfiles/nettest/scratch ;;
  fail) exit 1 ;;
esac
exit 0
FIXTURE
    git add -A
    git commit -qm 'Fixture updater'
    git update-ref refs/remotes/origin/devel HEAD
    git checkout -q original
  )
}

# Run update_lockfiles and print_summary in a subshell. Sets OUT, UPDATED, SKIPPED, FAILED, SUMMARY_RC.
run_update() {
  local result="$SB/update-result"
  OUT=$(
    # shellcheck source=../rpm-lockfile-update.sh
    source "$LOCKFILE_SCRIPT"
    # shellcheck disable=SC2034  # read by update_lockfiles
    BRANCH=release-0.25 VERSION=0.25.1 COMPONENT_FILTER="$1"
    get_gh_user() { echo test-user; }
    fork_remote() { echo fork; }
    update_lockfiles 2>&1
    rc=0
    print_summary || rc=$?
    printf '%s\n%s\n%s\n%s\n' "${REPOS_UPDATED[*]:-}" "${REPOS_SKIPPED[*]:-}" "${REPOS_FAILED[*]:-}" "$rc" > "$result"
  )
  { read -r UPDATED; read -r SKIPPED; read -r FAILED; read -r SUMMARY_RC; } < "$result"
  CALLS=$(cat "$SKOPEO_LOG")
}

ORIG_PATH="$PATH"; N=0
FIX=update-rpm-lockfiles-0.25.1

echo "=== a pinned line is rewritten and the rest kept ==="
new_workdir
write_dockerfile Dockerfile.nettest.konflux "ARG BASE_BRANCH=release-0.25" "" "$PIN" "ARG BASE_BRANCH" "LABEL base=\"registry.redhat.io/ubi9@$OLD\""
chmod 755 package/Dockerfile.nettest.konflux
refresh all
assert_eq "succeeds" "$RC" "0"
assert_eq "exact file after rewrite" "$(cat package/Dockerfile.nettest.konflux)" \
  "$(printf '%s\n' "ARG BASE_BRANCH=release-0.25" "" "$PIN_NEW" "ARG BASE_BRANCH" "LABEL base=\"registry.redhat.io/ubi9@$OLD\"")"
assert_eq "reports the file as changed" "$CHANGED" "package/Dockerfile.nettest.konflux"
assert_contains "prints the old digest" "$OUT" "old: $OLD"
assert_contains "prints the new digest" "$OUT" "new: $NEW"
assert_contains "resolves <repo>:latest without listing tags" "$CALLS" "inspect --no-tags --authfile $HOME/.docker/config.json docker://registry.redhat.io/ubi9:latest"
assert_contains "checks the resolved digest itself" "$CALLS" "inspect --raw --authfile $HOME/.docker/config.json docker://registry.redhat.io/ubi9@$NEW"
assert_eq "file mode kept" "$(stat -c %a package/Dockerfile.nettest.konflux 2>/dev/null || stat -f %Lp package/Dockerfile.nettest.konflux)" "755"

new_workdir
write_dockerfile Dockerfile.x.konflux \
  "from registry.redhat.io/ubi9/go-toolset@$OLD AS builder" \
  "  FROM  --platform=\$BUILDPLATFORM   --foo=bar  registry.redhat.io/ubi9@$OTHER   AS  final"
refresh all
assert_eq "stage name, spacing, nested repo and lower-case FROM kept" "$(cat package/Dockerfile.x.konflux)" \
  "$(printf '%s\n' "from registry.redhat.io/ubi9/go-toolset@$NEW AS builder" \
    "  FROM  --platform=\$BUILDPLATFORM   --foo=bar  registry.redhat.io/ubi9@$NEW   AS  final")"
assert_contains "nested repo resolved at its own path" "$CALLS" "docker://registry.redhat.io/ubi9/go-toolset:latest"

new_workdir; rm "$HOME/.docker/config.json"
write_dockerfile Dockerfile.x.konflux "$PIN"
refresh all
assert_eq "works without the auth file" "$RC" "0"
assert_not_contains "no --authfile when there is no auth file" "$CALLS" "--authfile"

new_workdir
write_dockerfile Dockerfile.x.konflux "$PIN"
export STUB_DIGEST="$OLD"
refresh all
assert_eq "already current: succeeds" "$RC" "0"
assert_eq "already current: nothing reported changed" "$CHANGED" ""
assert_contains "already current: says so" "$OUT" "already current: $OLD"

echo "=== everything else is left alone ==="
new_workdir
LEFT_ALONE=(
  "FROM --platform=\${BUILDPLATFORM} registry.redhat.io/ubi9/go-toolset:latest AS builder"
  "FROM --platform=\${TARGETPLATFORM} registry.redhat.io/ubi9:latest"
  "FROM registry.redhat.io/ubi9"
  "FROM quay.io/konflux/ubi9@$OLD"
  "FROM registry.access.redhat.com/ubi9@$OLD"
  "FROM registry.redhat.io.example.com/ubi9@$OLD"
  "FROM notregistry.redhat.io/ubi9@$OLD"
  "FROM registry.redhat.io/ubi9:9.6@$OLD"
  "FROM registry.redhat.io/ubi9@sha256:abc123"
  "# FROM registry.redhat.io/ubi9@$OLD"
  "RUN echo FROM registry.redhat.io/ubi9@$OLD"
)
write_dockerfile Dockerfile.x.konflux "${LEFT_ALONE[@]}"
BEFORE=$(cat package/Dockerfile.x.konflux)
refresh all
assert_eq "succeeds" "$RC" "0"
assert_eq ":latest, other registries, tag-and-digest and comments unchanged" "$(cat package/Dockerfile.x.konflux)" "$BEFORE"
assert_eq "skopeo not called" "$CALLS" ""
assert_eq "nothing reported changed" "$CHANGED" ""

new_workdir
write_dockerfile Dockerfile.konflux-notes "$PIN"
write_dockerfile Dockerfile.nettest "$PIN"
refresh all
assert_eq "files not matching Dockerfile*.konflux unchanged" "$(cat package/Dockerfile.nettest)" "$PIN"
assert_eq "no Dockerfile*.konflux: skopeo not called" "$CALLS" ""

echo "=== malformed digests are refused ==="
for bad in "sha256:abc123" "$NEW/../evil"; do
  new_workdir
  write_dockerfile Dockerfile.x.konflux "$PIN"
  export STUB_DIGEST="$bad"
  refresh all
  assert_eq "'${bad:0:20}...': fails" "$RC" "1"
  assert_eq "'${bad:0:20}...': original untouched" "$(cat package/Dockerfile.x.konflux)" "$PIN"
  assert_not_contains "'${bad:0:20}...': never checked as an image" "$CALLS" "--raw"
done

echo "=== images that are not multi-arch are refused ==="
for bad in "$ONE_ARCH" "$WINDOWS_PPC"; do
  new_workdir
  write_dockerfile Dockerfile.x.konflux "$PIN"
  export STUB_RAW="$bad"
  refresh all
  assert_eq "'${bad:0:24}...': fails" "$RC" "1"
  assert_eq "'${bad:0:24}...': original untouched" "$(cat package/Dockerfile.x.konflux)" "$PIN"
done

echo "=== skopeo failures ==="
new_workdir
write_dockerfile Dockerfile.x.konflux "$PIN"
export STUB_INSPECT_RC=1
refresh all
assert_eq "inspect fails: fails" "$RC" "1"
assert_eq "inspect fails: original untouched" "$(cat package/Dockerfile.x.konflux)" "$PIN"
assert_contains "inspect fails: shows skopeo's error" "$OUT" "stub: unauthorized"
assert_contains "inspect fails: names the image" "$OUT" "registry.redhat.io/ubi9:latest"

new_workdir
write_dockerfile Dockerfile.x.konflux "$PIN"
export STUB_RAW_RC=1
refresh all
assert_eq "raw inspect fails: fails" "$RC" "1"
assert_eq "raw inspect fails: original untouched" "$(cat package/Dockerfile.x.konflux)" "$PIN"

new_workdir
write_dockerfile Dockerfile.a.konflux "$PIN"
write_dockerfile Dockerfile.b.konflux "FROM registry.redhat.io/ubi10@$OLD"
export STUB_FAIL_REPO=ubi10
refresh all
assert_eq "second pin fails: fails" "$RC" "1"
assert_eq "second pin fails: the first file is not rewritten either" "$(cat package/Dockerfile.a.konflux)" "$PIN"
assert_eq "second pin fails: nothing reported changed" "$CHANGED" ""

echo "=== component filter scope ==="
scope_case() { # FILTER EXPECTED_CHANGED
  new_workdir
  local f
  for f in nettest submariner-gateway submariner-globalnet submariner-route-agent; do
    write_dockerfile "Dockerfile.$f.konflux" "$PIN"
  done
  refresh "$1"
  assert_eq "$1: rewrites exactly its scope" "$CHANGED" "$2"
  for f in package/*; do
    case " $CHANGED " in
      *" $f "*) assert_eq "$1: $f rewritten" "$(cat "$f")" "$PIN_NEW" ;;
      *) assert_eq "$1: $f untouched" "$(cat "$f")" "$PIN" ;;
    esac
  done
}
scope_case gateway package/Dockerfile.submariner-gateway.konflux
scope_case globalnet package/Dockerfile.submariner-globalnet.konflux
scope_case route-agent package/Dockerfile.submariner-route-agent.konflux
scope_case nettest package/Dockerfile.nettest.konflux
ALL_FILES="package/Dockerfile.nettest.konflux package/Dockerfile.submariner-gateway.konflux"
ALL_FILES+=" package/Dockerfile.submariner-globalnet.konflux package/Dockerfile.submariner-route-agent.konflux"
scope_case all "$ALL_FILES"
scope_case submariner "$ALL_FILES"
scope_case shipyard "$ALL_FILES"

new_workdir
write_dockerfile Dockerfile.nettest.konflux "$PIN"
refresh gateway
assert_eq "component without a Dockerfile: no-op" "$RC" "0"
assert_eq "component without a Dockerfile: skopeo not called" "$CALLS" ""

echo "=== repo update: only the Dockerfile changes ==="
new_sandbox
new_repo shipyard Dockerfile.nettest.konflux "$PIN"
R="$SUBMARINER_BASE/shipyard"
ORIGINAL_SHA=$(git -C "$R" rev-parse original)
run_update nettest
assert_eq "recorded as updated" "$UPDATED" "nettest#shipyard#0.25.1#release-0.25"
assert_eq "nothing failed" "$FAILED" ""
assert_eq "nothing skipped" "$SKIPPED" ""
assert_eq "commits exactly the Dockerfile" "$(git -C "$R" diff --name-only release-0.25 "$FIX")" "package/Dockerfile.nettest.konflux"
assert_eq "one commit on the fix branch" "$(git -C "$R" rev-list --count "release-0.25..$FIX")" "1"
assert_eq "committed line has the new digest" "$(git -C "$R" show "$FIX:package/Dockerfile.nettest.konflux" | sed -n 3p)" "$PIN_NEW"
MSG=$(git -C "$R" log -1 --format=%B "$FIX")
assert_contains "commit message mentions the base refresh" "$MSG" "Refresh base images and RPM lockfiles for release-0.25"
assert_contains "commit message names the file" "$MSG" "- package/Dockerfile.nettest.konflux"
assert_contains "commit is signed off" "$MSG" "Signed-off-by: Test User <test@example.com>"
assert_contains "PR title mentions the base refresh" "$OUT" 'Refresh\ pinned\ base\ images\ and\ RPM\ lockfiles'
assert_eq "commit message has no overlong line" "$(printf '%s\n' "$MSG" | awk 'length > 80' | wc -l | tr -d ' ')" "0"
assert_eq "original branch restored" "$(git -C "$R" branch --show-current)" "original"
assert_eq "original branch unmoved" "$(git -C "$R" rev-parse original)" "$ORIGINAL_SHA"
assert_eq "worktree clean" "$(git -C "$R" status --porcelain --untracked-files=all)" ""
assert_contains "updater ran on the fix branch" "$(cat "$UPDATER_LOG")" "ARGS $FIX nettest"
assert_contains "lockfiles generated against the new base" "$(cat "$UPDATER_LOG")" "$PIN_NEW"
assert_not_contains "lockfiles never saw the old base" "$(cat "$UPDATER_LOG")" "$OLD"
assert_contains "next steps keep the existing PR flow" "$OUT" "gh pr create --base release-0.25 --head test-user:$FIX"

echo "=== repo update: Dockerfile and lockfile, nothing else staged ==="
new_sandbox
new_repo shipyard Dockerfile.nettest.konflux "$PIN"
R="$SUBMARINER_BASE/shipyard"
export UPDATER_MODE=scratch
run_update nettest
assert_eq "commits exactly the Dockerfile and lockfile" "$(git -C "$R" diff --name-only release-0.25 "$FIX" | tr '\n' ' ')" \
  ".rpm-lockfiles/nettest/rpms.lock.yaml package/Dockerfile.nettest.konflux "
assert_eq "stray file not committed" "$(git -C "$R" ls-tree -r --name-only "$FIX" -- .rpm-lockfiles/nettest/scratch)" ""
assert_eq "updater not committed" "$(git -C "$R" ls-tree -r --name-only "$FIX" -- .rpm-lockfiles/update-lockfile.sh)" ""

echo "=== repo update: lockfile only ==="
new_sandbox
new_repo shipyard Dockerfile.nettest.konflux "$PIN"
R="$SUBMARINER_BASE/shipyard"
export UPDATER_MODE=lock STUB_DIGEST="$OLD"
run_update nettest
assert_eq "commits exactly the lockfile" "$(git -C "$R" diff --name-only release-0.25 "$FIX")" ".rpm-lockfiles/nettest/rpms.lock.yaml"
MSG=$(git -C "$R" log -1 --format=%B "$FIX")
assert_contains "keeps the plain commit message" "$MSG" "Regenerate RPM lockfiles for release-0.25"
assert_not_contains "does not claim a base refresh" "$MSG" "base image"

echo "=== repo update: nothing changes ==="
new_sandbox
new_repo shipyard Dockerfile.nettest.konflux "$PIN"
R="$SUBMARINER_BASE/shipyard"
export STUB_DIGEST="$OLD"
run_update nettest
assert_eq "recorded as no-changes" "$SKIPPED" "nettest:no-changes"
assert_eq "nothing updated" "$UPDATED" ""
assert_eq "fix branch removed" "$(git -C "$R" branch --list "$FIX")" ""
assert_eq "original branch restored" "$(git -C "$R" branch --show-current)" "original"

echo "=== repo update: resolution fails ==="
new_sandbox
new_repo shipyard Dockerfile.nettest.konflux "$PIN"
new_repo submariner Dockerfile.submariner-gateway.konflux "FROM --platform=\${TARGETPLATFORM} registry.redhat.io/ubi10@$OLD"
R="$SUBMARINER_BASE/shipyard"
ORIGINAL_SHA=$(git -C "$R" rev-parse original)
export STUB_FAIL_REPO=ubi9
run_update all
assert_contains "recorded in REPOS_FAILED" "$FAILED" "shipyard:base-refresh-failed"
assert_contains "summary shows the reason" "$OUT" "✗ shipyard (base-refresh-failed)"
assert_eq "summary fails" "$SUMMARY_RC" "1"
assert_eq "original branch restored" "$(git -C "$R" branch --show-current)" "original"
assert_eq "original branch unmoved" "$(git -C "$R" rev-parse original)" "$ORIGINAL_SHA"
assert_eq "worktree clean" "$(git -C "$R" status --porcelain --untracked-files=all)" ""
assert_eq "nothing committed on the fix branch" "$(git -C "$R" rev-list --count "release-0.25..$FIX")" "0"
assert_not_contains "updater never ran for it" "$(cat "$UPDATER_LOG")" "registry.redhat.io/ubi9@"
assert_contains "the next repo is still processed" "$UPDATED" "submariner#submariner#0.25.1#release-0.25"

echo "=== repo update: the updater fails after the rewrite ==="
new_sandbox
new_repo shipyard Dockerfile.nettest.konflux "$PIN"
R="$SUBMARINER_BASE/shipyard"
export UPDATER_MODE=fail
run_update nettest
assert_eq "recorded as an updater failure" "$FAILED" "nettest:update-script-failed"
assert_eq "nothing committed" "$(git -C "$R" rev-list --count "release-0.25..$FIX")" "0"
assert_eq "unfinished work stays on the fix branch, like partial lockfiles" "$(git -C "$R" branch --show-current)" "$FIX"

echo "=== repo update: component filter ==="
new_sandbox
new_repo submariner \
  Dockerfile.submariner-gateway.konflux "$PIN" \
  Dockerfile.submariner-globalnet.konflux "$PIN"
R="$SUBMARINER_BASE/submariner"
run_update gateway
assert_eq "commits only gateway's Dockerfile" "$(git -C "$R" diff --name-only release-0.25 "$FIX")" "package/Dockerfile.submariner-gateway.konflux"

echo "=== repo update: no pins ==="
new_sandbox
new_repo submariner Dockerfile.submariner-gateway.konflux "FROM --platform=\${TARGETPLATFORM} registry.redhat.io/ubi9:latest"
run_update gateway
assert_eq "skopeo not called" "$CALLS" ""
assert_eq "recorded as no-changes" "$SKIPPED" "gateway:no-changes"

echo "=== prerequisites ==="
new_sandbox
mkdir "$SB/onlybin"
for t in git podman gh; do printf '#!/bin/bash\nexit 0\n' > "$SB/onlybin/$t"; chmod +x "$SB/onlybin/$t"; done
OUT=$(
  # shellcheck source=../rpm-lockfile-update.sh
  source "$LOCKFILE_SCRIPT"
  # shellcheck disable=SC2123  # hiding the real tools is the point
  PATH="$SB/onlybin"
  check_prerequisites 2>&1
) && RC=0 || RC=$?
assert_eq "missing tools: exit 1" "$RC" "1"
assert_contains "missing tools: names skopeo and jq" "$OUT" "Missing required tools: skopeo jq"
assert_contains "missing tools: says how to fix an existing VM" "$OUT" "sudo dnf install -y skopeo jq"

echo
echo "════════════════════════════════════════"
if [ "$FAIL" -eq 0 ]; then echo "All $PASS tests passed"; else echo "$FAIL FAILED, $PASS passed"; exit 1; fi
