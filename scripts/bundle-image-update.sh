#!/bin/bash
# Update bundle component image SHAs from Konflux snapshots
#
# Usage: bundle-image-update.sh [X.Y|X.Y.Z] [--snapshot name]
#
# Arguments:
#   X.Y|X.Y.Z: Target version (auto-detected from branch if omitted).
#               X.Y defaults to X.Y.0.
#   --snapshot: Use specific snapshot instead of auto-detecting latest passing.
#
# What it does:
#   - Navigates to submariner-operator repo (auto-detects or uses default path)
#   - Queries Konflux for latest passing snapshot (or uses --snapshot arg)
#   - Extracts 7 component SHAs (8 total with metrics-proxy duplicate)
#   - Updates config/manager/patches/related-images.deployment.config.yaml
#   - Runs make bundle to regenerate manifests
#   - Updates Dockerfile labels (version bumps only)
#   - Verifies all SHAs match snapshot
#   - Creates single commit with all changes
#
# Exit codes:
#   0: Success (all steps completed)
#   1: Failure (prerequisites, validation, or step failed)

set -euo pipefail

# Resolve script location before any cd so lib paths work from any clone location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ━━━ CONSTANTS ━━━

readonly OPERATOR_REPO="$HOME/go/src/submariner-io/submariner-operator"
readonly CONFIG_FILE="config/manager/patches/related-images.deployment.config.yaml"

# Component mapping: snapshot-component-suffix:related-image-var-name
readonly COMPONENT_MAP=(
  "submariner-operator:submariner-operator"
  "submariner-gateway:submariner-gateway"
  "submariner-route-agent:submariner-routeagent"
  "submariner-globalnet:submariner-globalnet"
  "lighthouse-agent:submariner-lighthouse-agent"
  "lighthouse-coredns:submariner-lighthouse-coredns"
  "nettest:submariner-nettest"
)

# ━━━ GLOBAL VARIABLES ━━━

VERSION_DOT=""
VERSION_DASH=""
CURRENT_VERSION=""
TARGET_VERSION=""
UPDATE_TYPE=""
SNAPSHOT_ARG=""
SNAPSHOT=""
BRANCH=""

# SHA variables (set during extract_shas)
declare -A COMPONENT_SHAS

# ━━━ HELPERS ━━━

die() {
  echo "ERROR: $1"
  [ -n "${2:-}" ] && echo "$2"
  exit 1
}

# ━━━ STEP 0: PREREQUISITES AND ARGUMENTS ━━━

check_prerequisites() {
  echo "=== Bundle Image Update ==="
  echo ""

  # Check bash version (need 4.0+ for associative arrays)
  local BASH_MAJOR
  BASH_MAJOR=$(bash -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null)
  if [ -z "$BASH_MAJOR" ]; then
    BASH_MAJOR=$(bash --version 2>/dev/null | head -1 | sed -nE 's/.*version ([0-9]+).*/\1/p')
  fi

  if [ -z "$BASH_MAJOR" ] || [ "$BASH_MAJOR" -lt 4 ]; then
    local BASH_VER
    BASH_VER=$(bash --version 2>/dev/null | head -1 || echo "unknown")
    die "Bash 4.0+ required (current: $BASH_VER)" \
      "Associative arrays needed for component mapping"
  fi

  # Check oc login
  if oc auth can-i get snapshots -n submariner-tenant &>/dev/null; then
    echo "Logged into Konflux cluster"
  else
    die "Not logged into Konflux cluster" \
      "Run: oc login --web https://api.kflux-prd-rh02.0fk9.p1.openshiftapps.com:6443/"
  fi

  # Navigate to submariner-operator repo
  local REPO_NAME
  REPO_NAME=$(basename "$(pwd)" 2>/dev/null)
  if [ "$REPO_NAME" != "submariner-operator" ]; then
    echo "Not in submariner-operator, changing directory..."

    if [ ! -d "$OPERATOR_REPO" ]; then
      die "Repository not found at $OPERATOR_REPO"
    fi

    cd "$OPERATOR_REPO"
    echo "Changed to: $(pwd)"
  fi

  BRANCH=$(git rev-parse --abbrev-ref HEAD)

  echo "Prerequisites verified"
  echo ""
}

# Cross-step branch-misroute guard. bundle-image-update commits the SHA bump onto
# whatever branch submariner-operator has checked out (commit_changes) and prints
# `push origin $BRANCH`. If a prior release step (e.g. the cveFixes CVE-fix tooling)
# left the repo parked on its own `fix-*` branch, the bump would silently land there
# instead of release-<X.Y> — the documented cross-step branch hazard (see plan
# "Known bugs"). Assert the checkout is an *intended* bundle branch for this version:
# the release branch, or the Konflux bundle bot branch (Y-stream step 3b). Returns
# non-zero for anything else (a stray fix branch, detached HEAD, or wrong version).
assert_expected_branch() {
  local branch="$1" version_dot="$2" version_dash="$3"
  case "$branch" in
    "release-$version_dot"|"konflux-submariner-bundle-$version_dash") return 0 ;;
  esac
  return 1
}

parse_arguments() {
  local VERSION_ARG=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --snapshot)
        if [ -z "${2:-}" ]; then
          die "--snapshot requires a value" \
            "Usage: bundle-image-update.sh [X.Y|X.Y.Z] [--snapshot name]"
        fi
        SNAPSHOT_ARG="$2"
        shift 2
        ;;
      *)
        if [ -z "$VERSION_ARG" ]; then
          VERSION_ARG="$1"
        else
          die "Unexpected argument: $1" \
            "Usage: bundle-image-update.sh [X.Y|X.Y.Z] [--snapshot name]"
        fi
        shift
        ;;
    esac
  done

  # Extract version from branch if not provided. Only the two branches this script
  # legitimately commits onto are recognized (release + bundle bot); any other
  # branch dies below rather than guessing a version and risking a misrouted commit.
  if [ -z "$VERSION_ARG" ]; then
    case "$BRANCH" in
      release-*)
        VERSION_DOT="${BRANCH#release-}"  # release-0.21 -> 0.21
        ;;
      konflux-submariner-bundle-*)
        # Bot branch: konflux-submariner-bundle-0-24 -> 0.24
        local TEMP="${BRANCH#konflux-submariner-bundle-}"
        VERSION_DOT="${TEMP//-/.}"
        ;;
    esac
    if ! echo "$VERSION_DOT" | grep -qE '^[0-9]+\.[0-9]+$'; then
      die "Cannot auto-detect version from branch: $BRANCH" \
        "Provide version explicitly: bundle-image-update.sh X.Y"
    fi
    echo "Auto-detected version from branch: $VERSION_DOT"
  else
    # Validate format and default to .0 if patch version omitted
    if echo "$VERSION_ARG" | grep -qE '^[0-9]+\.[0-9]+$'; then
      VERSION_ARG="${VERSION_ARG}.0"
      echo "Defaulting to $VERSION_ARG (patch version 0)"
    elif ! echo "$VERSION_ARG" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
      die "Invalid version format: $VERSION_ARG" \
        "Expected: X.Y or X.Y.Z (e.g., 0.23, 0.21.2)"
    fi
    VERSION_DOT=$(echo "$VERSION_ARG" | grep -oE '^[0-9]+\.[0-9]+')
  fi

  VERSION_DASH="${VERSION_DOT//./-}"  # 0.21 -> 0-21

  # Refuse to commit onto a stray branch. bundle-image-update commits to whatever
  # branch is checked out, so a repo left on a fix branch by a prior release step
  # would misroute the SHA bump. Only the intended release / bundle-bot branch for
  # this version is allowed. (Auto-detected branches always pass — they can only be
  # release-*/bundle-*; every other branch already died above with "Cannot
  # auto-detect version". The check still earns its keep on the explicit path.)
  if ! assert_expected_branch "$BRANCH" "$VERSION_DOT" "$VERSION_DASH"; then
    die "submariner-operator is on branch '$BRANCH', not release-$VERSION_DOT" \
      "A prior release step may have left the repo on a fix branch, which would
misroute the bundle-SHA commit. Check out the release branch and re-run:
  cd $OPERATOR_REPO && git checkout release-$VERSION_DOT"
  fi

  # Read current bundle version
  CURRENT_VERSION=$(grep "^  version:" bundle/manifests/submariner.clusterserviceversion.yaml | head -1 | awk '{print $2}') || true

  if ! echo "$CURRENT_VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    die "Invalid version format in CSV: $CURRENT_VERSION" \
      "Expected: X.Y.Z (e.g., 0.21.1)"
  fi

  # Determine target version and update type
  if [ -z "$VERSION_ARG" ]; then
    TARGET_VERSION="$CURRENT_VERSION"
    UPDATE_TYPE="sha-only"
  elif [ "$VERSION_ARG" = "$CURRENT_VERSION" ]; then
    TARGET_VERSION="$CURRENT_VERSION"
    UPDATE_TYPE="sha-only"
  else
    TARGET_VERSION="$VERSION_ARG"
    UPDATE_TYPE="version-bump"
  fi

  echo "Version: $VERSION_DOT"
  echo "Current bundle version: $CURRENT_VERSION"
  echo "Target bundle version: $TARGET_VERSION"
  echo "Update type: $UPDATE_TYPE"
  echo ""
}

# ━━━ STEP 1: QUERY SNAPSHOT AND EXTRACT SHAS ━━━

# _parse_epoch DATE_STRING
# Converts an ISO-8601/RFC-3339 date string to Unix epoch seconds.
# Tries GNU date (-d) first, then BSD date (-j -f), returns 0 on any failure.
# Redirect stderr: both variants print errors for strings they don't understand.
_parse_epoch() {
  date -d "$1" +%s 2>/dev/null || \
  date -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null || \
  echo 0
}

# _get_tag_creation_time REPO TAG
# Returns the git tag's creation timestamp via GitHub API.
# For annotated tags: tagger.date from the tag object (when the tag was signed/pushed).
# For lightweight tags: committer.date from the tagged commit.
# Returns empty on any failure (gh absent, no auth, tag not found, jq missing).
_get_tag_creation_time() {
  local repo="$1" tag="$2"
  local ref_json obj_type obj_url
  ref_json=$(gh api "repos/$repo/git/refs/tags/$tag" 2>/dev/null || true)
  [ -z "$ref_json" ] && return
  obj_type=$(echo "$ref_json" | jq -r '.object.type // empty' 2>/dev/null || true)
  obj_url=$(echo "$ref_json" | jq -r '.object.url // empty' 2>/dev/null || true)
  [ -z "$obj_url" ] && return
  if [ "$obj_type" = "tag" ]; then
    # Annotated tag: follow to the tag object for tagger.date
    gh api "$obj_url" --jq '.tagger.date // empty' 2>/dev/null || true
  else
    # Lightweight tag: the object is the commit itself
    gh api "$obj_url" --jq '.committer.date // empty' 2>/dev/null || true
  fi
}

# _check_stale_snapshot SNAPSHOT CREATION_TIME
# Warns (stderr) when the snapshot predates the upstream git tag creation.
# Using git tag creation time — not GitHub release publishedAt — avoids false
# positives on snapshots built between the tag push and release page publication.
# Warn-only; callers continue regardless. Silently skips when gh is absent or
# date parsing fails (both scenarios return 0, guard condition stays false).
_check_stale_snapshot() {
  local snapshot="$1" creation_time="$2"
  local _tag_time _tag_ep _snap_ep
  _tag_time=$(_get_tag_creation_time \
    "submariner-io/submariner-operator" "v$TARGET_VERSION")
  [ -z "$_tag_time" ] && return
  _tag_ep=$(_parse_epoch "$_tag_time")
  _snap_ep=$(_parse_epoch "$creation_time")
  if [ "$_tag_ep" -gt 0 ] && [ "$_snap_ep" -gt 0 ] && [ "$_snap_ep" -lt "$_tag_ep" ]; then
    local _lag=$(( (_tag_ep - _snap_ep) / 60 ))
    echo "⚠  WARNING: snapshot predates release tag v$TARGET_VERSION by ~${_lag} min" >&2
    echo "   Konflux typically rebuilds 30-90 min after a tag push." >&2
    echo "   Snapshot: $snapshot (created $creation_time)" >&2
    echo "   Tag created: $_tag_time" >&2
    echo "   Wait for a newer snapshot or verify this one reflects the release commit." >&2
  fi
}

find_snapshot() {
  echo "Querying Konflux snapshots..."

  if [ -n "$SNAPSHOT_ARG" ]; then
    SNAPSHOT="$SNAPSHOT_ARG"
    # Verify snapshot exists
    local CREATION_TIME
    # `|| true`: oc get on a nonexistent named snapshot exits non-zero, which
    # under set -e would abort before the friendly "Snapshot not found" die below.
    CREATION_TIME=$(oc get snapshot "$SNAPSHOT" -n submariner-tenant -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null || true)
    if [ -z "$CREATION_TIME" ]; then
      die "Snapshot not found: $SNAPSHOT"
    fi
    echo "Using specified snapshot: $SNAPSHOT (created $CREATION_TIME)"
    # Stale guard applies on the --snapshot path too: an operator may pass a
    # pre-tag snapshot name explicitly (e.g., in conductor-driven automation).
    _check_stale_snapshot "$SNAPSHOT" "$CREATION_TIME"
  else
    # Get snapshot names only (avoids JSON corruption with large result sets)
    local SNAPSHOT_NAMES
    # `|| true`: a no-match grep exits non-zero, which (with pipefail) would abort
    # the whole script before the friendly "No snapshots found" die below.
    SNAPSHOT_NAMES=$(oc get snapshots -n submariner-tenant \
      -l 'pac.test.appstudio.openshift.io/event-type in (push,retest-all-comment,incoming)' \
      --sort-by=.metadata.creationTimestamp -o name | \
      grep "^snapshot.appstudio.redhat.com/submariner-${VERSION_DASH}" || true)

    if [ -z "$SNAPSHOT_NAMES" ]; then
      die "No snapshots found for version ${VERSION_DOT}"
    fi

    # Try finding passing snapshot (check recent 20)
    SNAPSHOT=""
    local SNAP_NAME SNAP STATUS
    for SNAP_NAME in $(echo "$SNAPSHOT_NAMES" | tail -20); do
      SNAP="${SNAP_NAME#snapshot.appstudio.redhat.com/}"
      STATUS=$(oc get snapshot "$SNAP" -n submariner-tenant \
        -o jsonpath='{.status.conditions[?(@.type=="AppStudioTestSucceeded")].status}' 2>/dev/null)
      if [ "$STATUS" = "True" ]; then
        SNAPSHOT="$SNAP"
      fi
    done

    local FALLBACK=false
    if [ -z "$SNAPSHOT" ]; then
      echo "WARNING: No passing snapshot found - using latest push snapshot..."
      SNAP_NAME=$(echo "$SNAPSHOT_NAMES" | tail -1)
      SNAPSHOT="${SNAP_NAME#snapshot.appstudio.redhat.com/}"
      FALLBACK=true
    fi

    local CREATION_TIME
    CREATION_TIME=$(oc get snapshot "$SNAPSHOT" -n submariner-tenant -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null || true)
    [ -z "$CREATION_TIME" ] && die "Snapshot disappeared or oc error: $SNAPSHOT"
    echo "Using snapshot: $SNAPSHOT (created $CREATION_TIME)"

    # Stale-snapshot guard: warn if snapshot predates the upstream git tag.
    # GitHub tag push triggers Konflux rebuilds (typically 30-90 min later).
    # Warn-only: operator may run before rebuild completes, or gh auth may be absent.
    _check_stale_snapshot "$SNAPSHOT" "$CREATION_TIME"

    [ "$FALLBACK" = true ] && {
      echo "  ⚠️  WARNING: this snapshot's tests did NOT pass (no passing snapshot was found)."
      echo "     Verify its test/EC status in the Konflux UI before pushing the bundle."
      echo "     Failing tests are expected only during initial new-version setup —"
      echo "     during a normal Z-stream update they may signal a real regression."
    }
  fi

  echo ""
}

extract_shas() {
  echo "Extracting component SHAs from snapshot..."

  # Fetch the snapshot JSON once and reuse it for every component. A single
  # snapshot is a bounded object that is safe to hold in a variable; the
  # "don't store JSON" caveat applies only to the large snapshot LIST queried
  # in find_snapshot, not to one resolved snapshot.
  local SNAP_JSON
  SNAP_JSON=$(oc get snapshot "$SNAPSHOT" -n submariner-tenant -o json) || \
    die "Failed to fetch snapshot: $SNAPSHOT"

  local COMPONENT SNAPSHOT_COMPONENT VAR_NAME SHA
  for PAIR in "${COMPONENT_MAP[@]}"; do
    COMPONENT="${PAIR%%:*}"
    VAR_NAME="${PAIR##*:}"
    SNAPSHOT_COMPONENT="${COMPONENT}-${VERSION_DASH}"

    # `|| true`: a missing component yields empty jq output, so grep exits
    # non-zero on no-match; under set -e/pipefail that would abort before the
    # friendly "Failed to extract SHA" die below.
    SHA=$(printf '%s' "$SNAP_JSON" | \
      jq -r ".spec.components[] | select(.name==\"$SNAPSHOT_COMPONENT\") | .containerImage" | \
      grep -oP 'sha256:\K[a-f0-9]+' || true)

    if [ -z "$SHA" ]; then
      die "Failed to extract SHA for component: $SNAPSHOT_COMPONENT"
    fi

    COMPONENT_SHAS["$VAR_NAME"]="sha256:$SHA"
    echo "  $VAR_NAME: ${SHA:0:12}..."
  done

  # Metrics-proxy uses same SHA as nettest
  COMPONENT_SHAS["submariner-metrics-proxy"]="${COMPONENT_SHAS[submariner-nettest]}"
  local SHA_DISPLAY="${COMPONENT_SHAS[submariner-metrics-proxy]#sha256:}"
  echo "  submariner-metrics-proxy: ${SHA_DISPLAY:0:12}... (same as nettest)"

  echo "Extracted 7 component SHAs from snapshot"
}

# ━━━ STEP 2: UPDATE RELATED IMAGES CONFIG ━━━

update_config() {
  if [ ! -f "$CONFIG_FILE" ]; then
    die "$CONFIG_FILE not found" \
      "Run bundle setup first: /konflux-bundle-setup ${VERSION_DOT}"
  fi

  echo ""
  echo "Updating $CONFIG_FILE..."

  local VAR_NAME
  for VAR_NAME in submariner-operator submariner-gateway submariner-routeagent submariner-globalnet \
                  submariner-lighthouse-agent submariner-lighthouse-coredns submariner-nettest \
                  submariner-metrics-proxy; do
    local NEW_SHA="${COMPONENT_SHAS[$VAR_NAME]}"

    # Replace SHA256 digest while preserving registry.redhat.io URL
    sed -i "/name: RELATED_IMAGE_${VAR_NAME}/,/value:/ s|@sha256:[a-f0-9]*|@${NEW_SHA}|" "$CONFIG_FILE"

    echo "  RELATED_IMAGE_${VAR_NAME}"
  done

  # Update container image field (uses operator SHA)
  sed -i "/path:.*\/containers\/.*\/image$/,/value:/ s|@sha256:[a-f0-9]*|@${COMPONENT_SHAS[submariner-operator]}|" "$CONFIG_FILE"
  echo "  Container image (uses operator SHA)"

  echo ""
  echo "Updated $CONFIG_FILE with 9 SHA references"
}

# ━━━ STEP 3: GENERATE BUNDLE ━━━

generate_bundle() {
  echo ""
  echo "Regenerating bundle..."

  if [ ! -d "bundle" ]; then
    die "bundle/ directory not found" \
      "Run bundle setup first: /konflux-bundle-setup ${VERSION_DOT}"
  fi

  # Remove v prefix if present (Makefile regex requires X.Y.Z format without v)
  local VERSION_NO_V="${TARGET_VERSION#v}"

  # Run make bundle with semantic version (triggers IS_SEMANTIC_VERSION=true in Makefile)
  if make bundle LOCAL_BUILD=1 VERSION="$VERSION_NO_V"; then
    echo "Bundle regenerated successfully"
  else
    die "make bundle failed"
  fi
}

# ━━━ STEP 4: UPDATE DOCKERFILE LABELS ━━━

update_dockerfile_labels() {
  if [ "$UPDATE_TYPE" = "version-bump" ]; then
    echo ""
    echo "Updating Dockerfile labels for version bump..."

    if [ ! -f "bundle.Dockerfile.konflux" ]; then
      die "bundle.Dockerfile.konflux not found" \
        "Run bundle setup first: /konflux-bundle-setup ${VERSION_DOT}"
    fi

    local VERSION_NO_V="${TARGET_VERSION#v}"

    sed -i \
      -e "s/csv-version=\"[^\"]*\"/csv-version=\"$VERSION_NO_V\"/" \
      -e "s/release=\"v[^\"]*\"/release=\"v$VERSION_NO_V\"/" \
      -e "s/version=\"v[^\"]*\"/version=\"v$VERSION_NO_V\"/" \
      bundle.Dockerfile.konflux

    # Verify labels updated
    if grep -q "csv-version=\"$VERSION_NO_V\"" bundle.Dockerfile.konflux && \
       grep -q "release=\"v$VERSION_NO_V\"" bundle.Dockerfile.konflux && \
       grep -q "version=\"v$VERSION_NO_V\"" bundle.Dockerfile.konflux; then
      echo "  csv-version=\"$VERSION_NO_V\""
      echo "  release=\"v$VERSION_NO_V\""
      echo "  version=\"v$VERSION_NO_V\""
      echo "Dockerfile labels updated"
    else
      die "Failed to update Dockerfile labels"
    fi
  else
    echo ""
    echo "SHA-only update - skipping Dockerfile label update"
  fi
}

# ━━━ STEP 5: VERIFY CHANGES ━━━

verify_shas() {
  echo ""
  echo "=== Verifying SHAs match snapshot $SNAPSHOT ==="

  local ERRORS=0

  # Fetch the snapshot JSON once (source of truth) and reuse it per component;
  # a single snapshot is safe to hold in a variable (see extract_shas).
  local SNAP_JSON
  SNAP_JSON=$(oc get snapshot "$SNAPSHOT" -n submariner-tenant -o json) || \
    die "Failed to fetch snapshot: $SNAPSHOT"

  local PAIR COMPONENT SNAPSHOT_COMPONENT VAR_NAME SNAPSHOT_SHA BUNDLE_SHA
  for PAIR in "${COMPONENT_MAP[@]}"; do
    COMPONENT="${PAIR%%:*}"
    VAR_NAME="${PAIR##*:}"
    SNAPSHOT_COMPONENT="${COMPONENT}-${VERSION_DASH}"

    # Get SHA from snapshot (source of truth). `|| true`: a missing component or
    # SHA-less image makes grep exit non-zero, which under set -e/pipefail would
    # abort before the empty-SHA guard below can report the MISSING via ERRORS.
    SNAPSHOT_SHA=$(printf '%s' "$SNAP_JSON" | \
      jq -r ".spec.components[] | select(.name==\"$SNAPSHOT_COMPONENT\") | .containerImage" | \
      grep -o 'sha256:[a-f0-9]*' || true)

    # Get SHA from bundle CSV (what we generated)
    BUNDLE_SHA=$(grep -A1 "name: RELATED_IMAGE_$VAR_NAME" bundle/manifests/submariner.clusterserviceversion.yaml \
      | grep "value:" | grep -o 'sha256:[a-f0-9]*' || true)

    if [ -z "$SNAPSHOT_SHA" ] || [ -z "$BUNDLE_SHA" ]; then
      echo "FAIL $SNAPSHOT_COMPONENT: MISSING SHA!"
      echo "  Snapshot: ${SNAPSHOT_SHA:-<empty>}"
      echo "  Bundle:   ${BUNDLE_SHA:-<empty>}"
      ((ERRORS++))
    elif [ "$SNAPSHOT_SHA" = "$BUNDLE_SHA" ]; then
      echo "OK   $SNAPSHOT_COMPONENT"
    else
      echo "FAIL $SNAPSHOT_COMPONENT: MISMATCH!"
      echo "  Snapshot: $SNAPSHOT_SHA"
      echo "  Bundle:   $BUNDLE_SHA"
      ((ERRORS++))
    fi
  done

  # Verify metrics-proxy uses nettest SHA
  local NETTEST_SHA METRICS_SHA
  # `|| true` on both: no-match grep exits non-zero and would abort under
  # set -e/pipefail before the empty-SHA guard below can report it via ERRORS.
  NETTEST_SHA=$(printf '%s' "$SNAP_JSON" | \
    jq -r ".spec.components[] | select(.name==\"nettest-${VERSION_DASH}\") | .containerImage" | \
    grep -o 'sha256:[a-f0-9]*' || true)
  METRICS_SHA=$(grep -A1 "name: RELATED_IMAGE_submariner-metrics-proxy" bundle/manifests/submariner.clusterserviceversion.yaml \
    | grep "value:" | grep -o 'sha256:[a-f0-9]*' || true)

  if [ -z "$NETTEST_SHA" ] || [ -z "$METRICS_SHA" ]; then
    echo "FAIL metrics-proxy: MISSING SHA!"
    echo "  Expected (nettest): ${NETTEST_SHA:-<empty>}"
    echo "  Bundle:             ${METRICS_SHA:-<empty>}"
    ((ERRORS++))
  elif [ "$NETTEST_SHA" = "$METRICS_SHA" ]; then
    echo "OK   metrics-proxy (uses nettest SHA)"
  else
    echo "FAIL metrics-proxy: MISMATCH!"
    echo "  Expected (nettest): $NETTEST_SHA"
    echo "  Bundle:             $METRICS_SHA"
    ((ERRORS++))
  fi

  echo ""

  if [ $ERRORS -eq 0 ]; then
    echo "All SHAs verified - bundle matches snapshot!"
  else
    die "VERIFICATION FAILED - $ERRORS mismatches found!" \
      "DO NOT COMMIT. Review and fix SHA mismatches above."
  fi

  echo ""

  # Validate YAML
  echo "Validating YAML..."
  if make yamllint; then
    echo "YAML validation passed"
  else
    die "YAML validation failed"
  fi
}

# ━━━ STEP 6: COMMIT CHANGES ━━━

commit_changes() {
  echo ""
  echo "Creating commit..."

  # Stage all bundle-related changes
  git add config/manager/patches/related-images.deployment.config.yaml \
          bundle/ \
          config/bundle/kustomization.yaml \
          config/manifests/kustomization.yaml

  # Stage Dockerfile for version bumps
  if [ "$UPDATE_TYPE" = "version-bump" ]; then
    git add bundle.Dockerfile.konflux
  fi

  # Generate commit message based on update type
  local COMMIT_MSG
  if [ "$UPDATE_TYPE" = "version-bump" ]; then
    COMMIT_MSG="Update bundle to $TARGET_VERSION

Updates container image SHAs to match Konflux snapshot.

Snapshot: $SNAPSHOT"
  else
    COMMIT_MSG="Update bundle SHAs to latest

Updates container image SHAs to match Konflux snapshot.

Snapshot: $SNAPSHOT"
  fi

  git diff --quiet --cached && { echo "Nothing staged — bundle already up to date"; return 0; }
  git commit -s -m "$COMMIT_MSG"
  COMMIT_CREATED=true
  echo "Commit created"
}

COMMIT_CREATED=false

# ━━━ STEP 7: SUMMARY ━━━

print_summary() {
  echo ""
  echo "======================================="
  echo "Bundle Image Update Complete"
  echo "======================================="
  echo ""
  echo "Summary:"
  echo "  Update type: $UPDATE_TYPE"
  echo "  Version: $CURRENT_VERSION -> $TARGET_VERSION"
  echo "  Snapshot: $SNAPSHOT"
  echo "  Branch: $BRANCH"
  echo ""
  if [ "$COMMIT_CREATED" = true ]; then
    echo "Commit created:"
    git --no-pager log -1 --oneline
    echo ""
    echo "Files modified:"
    git --no-pager diff --stat HEAD~1
  else
    echo "No changes — bundle already up to date"
  fi
  echo ""
  echo "Next steps:"
  echo "  1. Review changes: git show"
  echo "  2. Push: git push origin $BRANCH"
  echo "  3. Wait for bundle rebuild (~15-30 min)"
  echo "  4. Verify: oc get snapshots -n submariner-tenant | grep submariner-bundle-${VERSION_DASH}"
  echo ""
  # Append to push summary if conductor is running and a commit was actually created
  if [ "$COMMIT_CREATED" = true ] && [ -n "${AUTORELEASE_PUSH_LOG:-}" ]; then
    printf '\n  cd %s\n  git push origin %s\n' \
      "$OPERATOR_REPO" "$BRANCH" \
      >> "$AUTORELEASE_PUSH_LOG"
  fi
}

# ━━━ MAIN ━━━

main() {
  check_prerequisites
  parse_arguments "$@"

  # Tracker integration
  TRACKER_LIB="${TRACKER_LIB:-$SCRIPT_DIR/lib/jira-tracker.sh}"
  # shellcheck source=/dev/null
  [ -f "$TRACKER_LIB" ] && source "$TRACKER_LIB" 2>/dev/null || true
  TRACKER=$(find_release_tracker "${TARGET_VERSION:-}" 2>/dev/null || true)
  [ -n "${TRACKER:-}" ] && update_step "$TARGET_VERSION" "bundleShas" "in_progress" '{}' "$TRACKER"

  # CVE recheck gate
  if [ -n "${TRACKER:-}" ]; then
    local freshness
    freshness=$(check_freshness "$TARGET_VERSION" "cveFixes" "$TRACKER" 2>/dev/null || true)
    [ "$freshness" = "stale" ] && echo "⚠️  CVE fixes may be stale — consider re-running CVE checks" >&2
  fi

  find_snapshot
  extract_shas
  update_config
  generate_bundle
  update_dockerfile_labels
  verify_shas
  commit_changes
  print_summary

  # Record completion
  if [ -n "${TRACKER:-}" ]; then
    local data
    data=$(jq -n --arg snap "${SNAPSHOT:-}" --arg ver "$TARGET_VERSION" \
      '{snapshot:$snap,version:$ver}' | jq -c .) || data="{}"
    update_step "$TARGET_VERSION" "bundleShas" "complete" "$data" "$TRACKER"
  fi
}

# Guard so tests can source helpers (assert_expected_branch) without running an update.
if [ "${BASH_SOURCE[0]:-}" = "${0:-}" ]; then
  main "$@"
fi
