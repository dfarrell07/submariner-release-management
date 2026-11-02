#!/usr/bin/env bash
# Tests for the operator and bundle file change filters and the ACM version mapping.
# Run: ./scripts/lib/test-konflux-setup.sh
#
# Runs the real setup steps in disposable repositories, as child shells so errexit
# behaves as it does in the scripts. The pipelines start from real operator push
# headers in scripts/tests/fixtures/operator-tekton. Needs yq, as the scripts do.
set -euo pipefail

# A hook can export GIT_DIR and friends. Fixture git commands must not use the
# caller's repository, index or object database.
while IFS= read -r git_env; do unset "$git_env"; done < <(git rev-parse --local-env-vars)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(dirname "$SCRIPT_DIR")"
COMPONENT_SCRIPT="$SCRIPTS/konflux-component-setup.sh"
BUNDLE_SCRIPT="$SCRIPTS/konflux-bundle-setup.sh"
FIXTURES="$SCRIPTS/tests/fixtures/operator-tekton"

# shellcheck source=lib/acm-version.sh
source "$SCRIPT_DIR/acm-version.sh"
# shellcheck source=lib/cel-filter.sh
source "$SCRIPT_DIR/cel-filter.sh"

PASS=0 FAIL=0
assert_eq() {
  if [ "$2" = "$3" ]; then echo "  ✓ $1"; PASS=$((PASS + 1))
  else echo "  ✗ $1"; echo "    got:  '$2'"; echo "    want: '$3'"; FAIL=$((FAIL + 1)); fi
}
assert_contains() {
  if printf '%s' "$2" | grep -qF -- "$3"; then echo "  ✓ $1"; PASS=$((PASS + 1))
  else echo "  ✗ $1 (missing: '$3')"; FAIL=$((FAIL + 1)); fi
}
assert_not_contains() {
  if ! printf '%s' "$2" | grep -qF -- "$3"; then echo "  ✓ $1"; PASS=$((PASS + 1))
  else echo "  ✗ $1 (unexpectedly found: '$3')"; FAIL=$((FAIL + 1)); fi
}

command -v yq >/dev/null || { echo "SKIP: yq not installed"; exit 0; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid

# ━━━ Pipeline forms (args: file-type minor) ━━━

# A fixture renumbered to MINOR, turned into the pull-request pipeline if asked.
# Args: fixture (0-21, 0-25, 0-25-bot) file-type minor
header() {
  local own="${1:2:2}"
  sed -e "s/0-$own/0-$3/g" -e "s/release-0\.$own/release-0.$3/g" \
    -e "s/event == \"push\"/event == \"${2/-/_}\"/" -e "s/-on-push\$/-on-$2/" "$FIXTURES/$1-push.yaml"
}
op21() { header 0-21 "$@"; }    # real release-0.21: wrapped, lacks go.sum and other inputs
op25() { header 0-25 "$@"; }    # real release-0.25: every input
bot() { header 0-25-bot "$@"; } # real Konflux bot form: no filter, over two lines
no_cel() { bot "$@" | awk '/on-cel-expression:/ { getline; next } 1'; }
# The bot form with another expression. Args: file-type minor expression
with_cel() {
  bot "$1" "$2" | CEL="$3" awk '
    /on-cel-expression:/ { print "    pipelinesascode.tekton.dev/on-cel-expression: " ENVIRON["CEL"]; getline; next } 1'
}
expected_cel() { op25 "$2" "$1" | cel_read -; } # Args: minor file-type

# Creates a repository whose origin/release-0.PREV has PREV_FORM pipelines, checked
# out on a bot branch with CUR_FORM pipelines. Prints its path.
# Args: component prev-minor prev-form cur-minor cur-form
new_repo() {
  local component="$1" prev="$2" prev_form="$3" cur="$4" cur_form="$5" repo file_type
  repo=$(mktemp -d "$TMP/repo-XXXXXX")
  mkdir -p "$repo/.tekton"
  git -C "$repo" init -q -b "release-0.$prev"
  for file_type in pull-request push; do
    "$prev_form" "$file_type" "$prev" > "$repo/.tekton/$component-0-$prev-$file_type.yaml"
  done
  git -C "$repo" add -A
  git -C "$repo" commit -qm previous
  git -C "$repo" update-ref "refs/remotes/origin/release-0.$prev" HEAD
  git -C "$repo" checkout -qb "konflux-$component-0-$cur"
  git -C "$repo" rm -qr .tekton
  mkdir -p "$repo/.tekton"
  for file_type in pull-request push; do
    "$cur_form" "$file_type" "$cur" > "$repo/.tekton/$component-0-$cur-$file_type.yaml"
  done
  git -C "$repo" add -A
  git -C "$repo" commit -qm "bot pipelines"
  echo "$repo"
}

# Runs one real step of konflux-component-setup.sh. Sets OUT and RC.
# Args: repo minor step
run_component_step() {
  RC=0
  OUT=$(cd "$1" && bash -c '
    source "$1"
    COMPONENT=submariner-operator
    VERSION_MAJOR=0
    VERSION_MINOR=$2
    VERSION_DASHED=0-$2
    VERSION_DOTTED=0.$2
    TARGET_BRANCH=release-0.$2
    PREV_VERSION=$(($2 - 1))
    HAS_CPE=yes
    SPECIAL_FILES=""
    ACM_VERSION=${TEST_ACM:-}
    "$3"' _ "$COMPONENT_SCRIPT" "$2" "$3" 2>&1) || RC=$?
}

# Runs one real step of konflux-bundle-setup.sh. Sets OUT and RC.
# Args: repo minor step
run_bundle_step() {
  RC=0
  OUT=$(cd "$1" && bash -c '
    source "$1"
    VERSION=0.$2
    VERSION_DASH=0-$2
    VERSION_MINOR=$2
    PREV_VERSION=0.$(($2 - 1))
    PREV_VERSION_MINOR=$(($2 - 1))
    PREV_VERSION_DASH=0-$(($2 - 1))
    PREV_RELEASE_BRANCH=release-0.$(($2 - 1))
    RELEASE_BRANCH=release-0.$2
    ACM_VERSION=${TEST_ACM:-}
    "$3"' _ "$BUNDLE_SCRIPT" "$2" "$3" 2>&1) || RC=$?
}

operator_file() { echo "$1/.tekton/submariner-operator-0-$2-$3.yaml"; }
commits() { git -C "$1" rev-list --count HEAD; }
dirty() { git -C "$1" status --porcelain; }

# Everything but the annotation, to check nothing else in a pipeline moved.
without_cel() {
  awk '
    /on-cel-expression:/ { skipping = 1; next }
    skipping && /^      / { next }
    { skipping = 0; print }' "$1"
}

# Asserts the step failed with a message and left no commit or changes.
assert_fails_clean() {
  local name="$1" repo="$2" want="$3" before="$4"
  assert_eq "$name: fails" "$RC" 1
  assert_contains "$name: says why" "$OUT" "$want"
  assert_eq "$name: no commit" "$(commits "$repo")" "$before"
  assert_eq "$name: no changes left" "$(dirty "$repo")" ""
}

# Runs the operator filter step on a new repository and checks it failed cleanly.
# Args: name message prev-form cur-form
operator_fails() {
  local repo before
  repo=$(new_repo submariner-operator 25 "$3" 26 "$4")
  before=$(commits "$repo")
  run_component_step "$repo" 26 add_file_change_filters
  assert_fails_clean "$1" "$repo" "$2" "$before"
}

# ━━━ Operator filter ━━━

echo "=== Operator filter: real release-0.25 copied over the bot's two-line form ==="
repo=$(new_repo submariner-operator 25 op25 26 bot)
before=$(commits "$repo")
before_rest=$(without_cel "$(operator_file "$repo" 26 push)")
run_component_step "$repo" 26 add_file_change_filters
assert_eq "setup succeeds" "$RC" 0
for file_type in pull-request push; do
  assert_eq "$file_type expression" "$(cel_read "$(operator_file "$repo" 26 "$file_type")")" "$(expected_cel 26 "$file_type")"
done
assert_eq "one commit added" "$(commits "$repo")" "$((before + 1))"
assert_eq "tree clean" "$(dirty "$repo")" ""
assert_eq "rest of the pipeline unchanged" "$(without_cel "$(operator_file "$repo" 26 push)")" "$before_rest"
assert_contains "commit is signed off" "$(git -C "$repo" log -1 --format=%B)" "Signed-off-by: test"

echo "=== Idempotent rerun ==="
head_before=$(git -C "$repo" rev-parse HEAD)
sum_before=$(cat "$repo"/.tekton/*.yaml | sha256sum)
git -C "$repo" update-ref -d refs/remotes/origin/release-0.25
run_component_step "$repo" 26 add_file_change_filters
assert_eq "rerun succeeds without the previous branch" "$RC" 0
assert_eq "rerun adds no commit" "$(git -C "$repo" rev-parse HEAD)" "$head_before"
assert_eq "rerun leaves files alone" "$(cat "$repo"/.tekton/*.yaml | sha256sum)" "$sum_before"

echo "=== Annotation absent ==="
repo=$(new_repo submariner-operator 25 op25 26 no_cel)
run_component_step "$repo" 26 add_file_change_filters
assert_eq "annotation absent: inserted" "$(cel_read "$(operator_file "$repo" 26 push)")" "$(expected_cel 26 push)"
assert_eq "inserted once" "$(grep -c on-cel-expression "$(operator_file "$repo" 26 push)")" 1

echo "=== Failures ==="
operator_fails "previous branch has no filter" "has no path filter to copy" bot bot
operator_fails "previous filter lacks an input" "missing required path: go.sum" op21 bot
assert_not_contains "wrapped release-0.21 expression read in full" "$OUT" "not a path-filtered"
# The required paths are exactly the release-0.25 ones: dropping any of them fails.
full=$(expected_cel 26 push) not_required=""
while IFS= read -r path; do
  lit="\"$path\".pathChanged()"
  dropped="${full/"$lit || "/}"
  [ "$dropped" != "$full" ] || dropped="${full/" || $lit"/}"
  err=$(cel_check_operator "$dropped" push release-0.26 submariner-operator-0-26 2>&1) ||
    [[ "$err" != *"missing required path: $path"* ]] || continue
  not_required+="$path "
done < <(cel_paths "$full")
assert_eq "every release-0.25 path is required" "$not_required" ""
op25_config() { op25 "$@" | sed 's|"pkg/\*\*\*"|"config/***"|'; }
operator_fails "copied filter has config/" "path must not be in this filter: config/***" op25_config bot
op25_bundle() { op25 "$@" | sed 's|"pkg/\*\*\*".pathChanged()|& \|\| "bundle/***".pathChanged()|'; }
operator_fails "copied filter has bundle/" "path must not be in this filter: bundle/***" op25_bundle bot
top_level_or() { with_cel "$1" "$2" "event == \"${1/-/_}\" && target_branch == \"release-0.$2\" || \"go.mod\".pathChanged()"; }
operator_fails "filter doesn't restrict the build" "not a path-filtered expression" op25 top_level_or
stale() { op25 "$1" 25; }
operator_fails "filter for the wrong branch" "not a path-filtered expression" op25 stale
push_only() { op25 push "$2"; }
operator_fails "pull-request pipeline copied a push filter" "not a path-filtered expression" push_only bot
no_insertion_point() { no_cel "$@" | sed '/max-keep-runs/d'; }
operator_fails "nowhere to insert" "Failed to write" op25 no_insertion_point
assert_eq "nowhere to insert: no temp file" "$(find "$TMP" -name '*.cel-tmp' | wc -l | tr -d ' ')" 0

repo=$(new_repo submariner-operator 25 op25 26 bot)
git -C "$repo" update-ref -d refs/remotes/origin/release-0.25
before=$(commits "$repo")
run_component_step "$repo" 26 add_file_change_filters
assert_fails_clean "previous branch unreadable" "$repo" "Cannot read" "$before"

repo=$(new_repo submariner-operator 25 op25 26 bot)
git -C "$repo" rm -q .tekton/submariner-operator-0-26-push.yaml
git -C "$repo" commit -qm "drop push"
before=$(commits "$repo")
run_component_step "$repo" 26 add_file_change_filters
assert_fails_clean "pipeline missing" "$repo" "submariner-operator-0-26-push.yaml not found" "$before"

printf 'metadata: [unclosed\n' > "$TMP/broken.yaml"
rc=0; cel_read "$TMP/broken.yaml" >/dev/null 2>&1 || rc=$?
assert_eq "unparseable YAML is an error" "$rc" 1

repo=$(new_repo submariner-gateway 25 bot 26 bot)
before=$(commits "$repo")
RC=0
OUT=$(cd "$repo" && bash -c 'source "$1"; COMPONENT=submariner-gateway; add_file_change_filters' _ "$COMPONENT_SCRIPT" 2>&1) || RC=$?
assert_eq "other components skip the filter" "$RC" 0
assert_eq "other components: no commit" "$(commits "$repo")" "$before"

# ━━━ Bundle filter ━━━

echo "=== Bundle filter ==="
bundle_cel() {
  local c="submariner-bundle-0-$2"
  echo "event == \"${1/-/_}\" && target_branch == \"release-0.$2\" && (\".tekton/$c-pull-request.yaml\".pathChanged() || \".tekton/$c-push.yaml\".pathChanged() || \"bundle.Dockerfile.konflux\".pathChanged() || \"bundle/***\".pathChanged() || \"config/bundle/***\".pathChanged())"
}
bundle() { with_cel "$1" "$2" "$(bundle_cel "$1" "$2")" | sed 's/submariner-operator/submariner-bundle/g'; }
bundle_bot() { bot "$@" | sed 's/submariner-operator/submariner-bundle/g'; }
bundle_file() { echo "$1/.tekton/submariner-bundle-0-$2-$3.yaml"; }

repo=$(new_repo submariner-bundle 25 bundle 26 bundle_bot)
before=$(commits "$repo")
run_bundle_step "$repo" 26 add_file_change_filters
assert_eq "bundle filter applied" "$RC" 0
assert_eq "bundle filter updated to the new branch" \
  "$(cel_read "$(bundle_file "$repo" 26 pull-request)")" "$(bundle_cel pull-request 26)"
assert_eq "bundle filter commit" "$(commits "$repo")" "$((before + 1))"
run_bundle_step "$repo" 26 add_file_change_filters
assert_eq "bundle rerun succeeds" "$RC" 0
assert_eq "bundle rerun adds no commit" "$(commits "$repo")" "$((before + 1))"

repo=$(new_repo submariner-bundle 25 bundle 26 bundle_bot)
git -C "$repo" update-ref -d refs/remotes/origin/release-0.25
git -C "$repo" branch -qD release-0.25
before=$(commits "$repo")
run_bundle_step "$repo" 26 add_file_change_filters
assert_fails_clean "bundle: previous file unavailable" "$repo" "Could not copy" "$before"

bundle_no_config() { bundle "$@" | sed 's/ || "config\/bundle\/\*\*\*".pathChanged()//'; }
repo=$(new_repo submariner-bundle 25 bundle_no_config 26 bundle_bot)
before=$(commits "$repo")
run_bundle_step "$repo" 26 add_file_change_filters
assert_fails_clean "bundle: filter missing a path" "$repo" "missing required path: config/bundle/***" "$before"

# Only the second file is bad: the first must not be left half done.
bundle_push_bad() { if [ "$1" = push ]; then bundle_bot "$@"; else bundle "$@"; fi; }
repo=$(new_repo submariner-bundle 25 bundle_push_bad 26 bundle_bot)
before=$(commits "$repo")
run_bundle_step "$repo" 26 add_file_change_filters
assert_fails_clean "bundle: only push is bad" "$repo" "no valid path filter" "$before"

# ━━━ ACM mapping ━━━

echo "=== ACM mapping ==="
for pair in 0.7:2.0 0.20:2.13 0.24:2.17 0.25:5.0 0.25.1:5.0; do
  assert_eq "${pair%:*} is ${pair#*:}" "$(acm_version_for "${pair%:*}")" "${pair#*:}"
done

acm_fails() {
  local name="$1" want="$2" err rc=0
  shift 2
  err=$("$@" 2>&1 >/dev/null) || rc=$?
  assert_eq "$name: fails" "$rc" 1
  assert_contains "$name: says why" "$err" "$want"
}
acm_fails "0.26 unknown" "a row for 26 to acm_version_for" acm_version_for 0.26
acm_fails "0.6 too old" "minimum is 0.7" acm_version_for 0.6
acm_fails "1.0 not a Submariner version" "Invalid Submariner version" acm_version_for 1.0

echo "=== CPE label ==="
for pair in 0.20:2.13 0.24:2.17 0.25:5.0; do
  printf '      cpe="cpe:/a:redhat:acm:1.1::el9" \\\n' > "$TMP/Dockerfile"
  acm_set_cpe "$TMP/Dockerfile" "$(acm_version_for "${pair%:*}")"
  assert_eq "${pair%:*} CPE" "$(cat "$TMP/Dockerfile")" "      cpe=\"cpe:/a:redhat:acm:${pair#*:}::el9\" \\"
done
printf 'LABEL name="x"\n' > "$TMP/Dockerfile"
rc=0; acm_set_cpe "$TMP/Dockerfile" 5.0 || rc=$?
assert_eq "no CPE label to set is a failure" "$rc" 1

# The real Dockerfile step, copying a 0.24 label block.
repo=$(new_repo submariner-operator 24 bot 25 bot)
mkdir -p "$repo/package"
cat > "$repo/package/Dockerfile.submariner-operator.konflux" <<'EOF'
ARG BASE_BRANCH=release-0.24
LABEL com.github.url="https://github.com/submariner-io/submariner-operator" \
      cpe="cpe:/a:redhat:acm:2.17::el9" \
      version="v0.24.0"
EOF
git -C "$repo" add -A
git -C "$repo" commit -qm dockerfile
git -C "$repo" update-ref refs/remotes/origin/release-0.24 HEAD
TEST_ACM=$(acm_version_for 0.25) run_component_step "$repo" 25 add_konflux_dockerfile
assert_contains "operator Dockerfile copied from 0.24 gets ACM 5.0" \
  "$(cat "$repo/package/Dockerfile.submariner-operator.konflux")" 'cpe="cpe:/a:redhat:acm:5.0::el9"'

echo "=== Scripts use the mapping ==="
# Args: minor
detect() {
  local repo
  repo=$(new_repo submariner-operator $(($1 - 1)) bot "$1" bot)
  git -C "$repo" branch -q "release-0.$1"
  RC=0
  OUT=$(cd "$repo" && bash -c 'source "$1"; detect_repo_and_component . submariner-operator "$2"' _ "$COMPONENT_SCRIPT" "0.$1" 2>&1) || RC=$?
}
detect 25
assert_contains "component setup: 0.25 is ACM 5.0" "$OUT" "ACM version:    5.0"
detect 26
assert_eq "component setup: 0.26 fails" "$RC" 1
assert_contains "component setup: 0.26 says what to do" "$OUT" "a row for 26 to acm_version_for"

bundle_version() {
  RC=0
  OUT=$(bash -c 'source "$1"; parse_args_and_detect_version "$2"' _ "$BUNDLE_SCRIPT" "$1" 2>&1) || RC=$?
}
bundle_version 0.25
assert_contains "bundle setup: 0.25 is ACM 5.0" "$OUT" "ACM version: 5.0"
bundle_version 0.26
assert_eq "bundle setup: 0.26 fails" "$RC" 1
assert_contains "bundle setup: 0.26 says what to do" "$OUT" "a row for 26 to acm_version_for"

# The bundle step must not treat a previous ACM of 5.0 as text to replace everywhere.
# TEST_ACM stands in for a future table row.
repo="$TMP/bundle-infra"
mkdir -p "$repo/config/bundle/patches" "$repo/config/manager/patches" "$repo/.tekton"
git -C "$repo" init -q -b release-0.25
cat > "$repo/bundle.Dockerfile.konflux" <<'EOF'
LABEL cpe="cpe:/a:redhat:acm:5.0::el9"
LABEL com.redhat.openshift.versions="v4.19-v5.0"
LABEL csv-version="0.25.0"
EOF
echo 'newTag: 0.25.0' > "$repo/config/bundle/kustomization.yaml"
echo 'version: 0.25.0' > "$repo/config/bundle/patches/submariner.csv.config.yaml"
echo 'x: y' > "$repo/config/manager/patches/related-images.deployment.config.yaml"
echo 'BASE_BRANCH=release-0.25' > "$repo/.tekton/konflux.args"
echo 'value: bundle.Dockerfile' > "$repo/.tekton/submariner-bundle-0-26-push.yaml"
git -C "$repo" add -A
git -C "$repo" commit -qm previous
git -C "$repo" checkout -qb konflux-submariner-bundle-0-26
TEST_ACM=5.1 run_bundle_step "$repo" 26 add_bundle_infrastructure
assert_eq "bundle infrastructure copied" "$RC" 0
dockerfile=$(cat "$repo/bundle.Dockerfile.konflux")
assert_contains "bundle CPE moves from 5.0 to 5.1" "$dockerfile" 'cpe:/a:redhat:acm:5.1::el9'
assert_contains "OCP v5.0 text is left alone" "$dockerfile" 'v4.19-v5.0'
assert_contains "Submariner version still updated" "$dockerfile" 'csv-version="0.26.0"'

echo "=== Release notes and tracker use the mapping ==="
calc() {
  bash -c 'source "$1"; VERSION=$2; calculate_acm_version; echo "$ACM_VERSION"' \
    _ "$SCRIPT_DIR/release-notes-common.sh" "$1"
}
assert_eq "tracker form: 0.24.1" "$(calc 0.24.1)" "ACM 2.17.0"
assert_eq "tracker form: 0.25.0" "$(calc 0.25.0)" "ACM 5.0.0"
rc=0; calc 0.26.0 >/dev/null 2>&1 || rc=$?
assert_eq "tracker form: 0.26.0 fails" "$rc" 1

description=$(bash -c 'source "$1"; VERSION=0.25.0; calculate_acm_version; _generate_parent_description 0.25.0 y "$ACM_VERSION"' \
  _ "$SCRIPT_DIR/jira-tracker.sh" 2>&1)
assert_contains "tracker description says ACM 5.0.0" "$description" "**ACM Version:** ACM 5.0.0"

rc=0; err=$("$SCRIPTS/release-notes/review-issue.sh" ACM-1 0.26.0 stage "$TMP/out" "$TMP/decision" 2>&1) || rc=$?
assert_eq "review-issue.sh: 0.26.0 fails" "$rc" 1
assert_contains "review-issue.sh: says what to do" "$err" "a row for 26 to acm_version_for"

echo "=== configure-downstream uses the mapping ==="
# It must stop before looking for the release-data repository, which this HOME lacks.
rc=0; out=$(HOME="$TMP" TRACKER_LIB=/nonexistent "$SCRIPTS/configure-downstream.sh" 0.26 2>&1) || rc=$?
assert_eq "configure-downstream: 0.26 fails" "$rc" 1
assert_contains "configure-downstream: says what to do" "$out" "a row for 26 to acm_version_for"
assert_not_contains "configure-downstream: fails before the repository" "$out" "konflux-release-data"

# 0.24 to 0.25 in a fake release-data repository, whose 0.24 overlay has the ACM
# version between slashes and in unrelated text.
data="$TMP/home/konflux/konflux-release-data"
overlays="$data/tenants-config/cluster/kflux-prd-rh02/tenants/submariner-tenant/overlay/application-submariner"
mkdir -p "$overlays/0-24-overlay"
: > "$data/tenants-config/build-single.sh"
printf 'path: /2.17/images\nnote: v2.17\nvalue: release-0.24\nvalue: submariner-0-24\n' \
  > "$overlays/0-24-overlay/component-patch.yaml"
echo "nameSuffix: -0-24" > "$overlays/0-24-overlay/kustomization.yaml"
# The script checks for the 26 files of a real overlay.
for i in $(seq 24); do echo 'a: b' > "$overlays/0-24-overlay/filler-$i.yaml"; done
git -C "$data" init -q -b main && git -C "$data" add -A && git -C "$data" commit -qm init
git -C "$data" update-ref refs/remotes/origin/main HEAD
out=$(HOME="$TMP/home" TRACKER_LIB=/nonexistent "$SCRIPTS/configure-downstream.sh" 0.25 2>&1) || true
patch=$(cat "$overlays/0-25-overlay/component-patch.yaml")
assert_contains "configure-downstream: slashed ACM version replaced" "$patch" "path: /5.0/images"
assert_contains "configure-downstream: unrelated text kept" "$patch" "note: v2.17"
assert_not_contains "configure-downstream: unrelated text isn't a leftover" "$out" "Old version references"
assert_contains "configure-downstream: overlay commit reached" "$out" "Commit 1: Created overlay structure"

echo "=== No other copy of the math ==="
others=$(grep -rnE '(MINOR[A-Z_]*|minor|[A-Z_]*VERSION[A-Z_]*) - 7\)|redhat:acm:2\.\$' "$SCRIPTS" \
  --exclude=acm-version.sh --exclude=test-konflux-setup.sh || true)
assert_eq "ACM math only lives in acm-version.sh" "$others" ""

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
