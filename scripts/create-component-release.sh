#!/usr/bin/env bash
# Create component release (stage or prod)
#
# Usage: create-component-release.sh <version> [stage|prod] [--snapshot <name>]
#
# Arguments:
#   version: Submariner version (e.g., 0.22.1 or 0.22)
#   [stage|prod]: Release type (default: stage)
#   --snapshot <name>: stage only. Release this snapshot instead of choosing one;
#     it must still pass every check
#
# Environment:
#   ALLOW_PRE_TAG_CANDIDATE=true: let stage continue without v<version> on all five
#     component repos (warns)
#   ALLOW_EMPTY_RELEASE_NOTES=true: let prod continue when the stage YAML has no
#     issues or CVEs (warns)
#
# Exit codes:
#   0: Success (release created and committed)
#   1: Failure (prerequisites, validation, or commit failed)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/upstream-tags.sh
source "$SCRIPT_DIR/lib/upstream-tags.sh"

# Global variables (set by parse_arguments)
VERSION=""
RELEASE_TYPE="stage"
SNAPSHOT_ARG=""
GIT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPTS_DIR=""

# Global variables (set by verify_release)
SNAPSHOT_NAME=""

# Global variables (set by generate_yaml)
YAML_FILE=""

# ============================================================================
# Prerequisites Check
# ============================================================================

check_prerequisites() {
  local MISSING_TOOLS=()

  command -v oc &>/dev/null || MISSING_TOOLS+=("oc")
  command -v jq &>/dev/null || MISSING_TOOLS+=("jq")
  command -v git &>/dev/null || MISSING_TOOLS+=("git")
  command -v yq &>/dev/null || MISSING_TOOLS+=("yq")

  if [ "${#MISSING_TOOLS[@]}" -gt 0 ]; then
    echo "❌ ERROR: Missing required tools: ${MISSING_TOOLS[*]}"
    echo ""
    echo "Installation instructions:"
    for tool in "${MISSING_TOOLS[@]}"; do
      case "$tool" in
        oc) echo "  oc: https://docs.openshift.com/container-platform/latest/cli_reference/openshift_cli/getting-started-cli.html" ;;
        jq) echo "  jq: https://jqlang.github.io/jq/download/" ;;
        git) echo "  git: https://git-scm.com/downloads" ;;
        yq) echo "  yq: https://github.com/mikefarah/yq" ;;
      esac
    done
    exit 1
  fi

  # Check oc authentication: stage and prod both read the snapshot
  if ! oc whoami &>/dev/null; then
    echo ""
    echo "============================================"
    echo "ERROR: Not authenticated with Konflux"
    echo "============================================"
    echo "This script requires oc authentication."
    echo "Run: oc login --web https://api.kflux-prd-rh02.0fk9.p1.openshiftapps.com:6443/"
    echo ""
    exit 1
  fi

  echo "✓ Prerequisites verified: oc, jq, git, yq"
  echo "✓ Authenticated with Konflux as: $(oc whoami)"
}

# ============================================================================
# Argument Parsing
# ============================================================================

show_usage() {
  echo "Usage: $0 <version> [stage|prod] [--snapshot <name>]"
  echo "Example: $0 0.22.1"
  echo "Example: $0 0.22.1 stage"
  echo "Example: $0 0.22.1 stage --snapshot submariner-0-22-xxxxx"
  echo "Example: $0 0.22.1 prod"
}

parse_arguments() {
  local args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --snapshot)
        if [ -z "${2:-}" ]; then
          echo "❌ ERROR: --snapshot requires a snapshot name"
          show_usage
          exit 1
        fi
        SNAPSHOT_ARG="$2"
        shift 2
        ;;
      *) args+=("$1"); shift ;;
    esac
  done
  set -- "${args[@]}"
  local VERSION_ARG="${1:-}"
  local TYPE_ARG="${2:-}"

  if [ -z "$VERSION_ARG" ]; then
    echo "❌ ERROR: Version required"
    show_usage
    exit 1
  fi

  if [ $# -gt 2 ]; then
    echo "❌ ERROR: Too many arguments"
    show_usage
    exit 1
  fi

  # Parse version
  VERSION="$VERSION_ARG"

  # Validate version format and expand if needed
  if [[ "$VERSION" =~ ^[0-9]+\.[0-9]+$ ]]; then
    # X.Y format → default to X.Y.0
    VERSION="${VERSION}.0"
    echo "ℹ️  Defaulting to $VERSION (patch version 0)"
  elif ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "❌ ERROR: Invalid version format: $VERSION"
    echo "Expected: X.Y or X.Y.Z (e.g., 0.22 or 0.22.1)"
    exit 1
  fi

  # Parse release type (default: stage)
  if [ -n "$TYPE_ARG" ]; then
    if [[ "$TYPE_ARG" = "stage" || "$TYPE_ARG" = "prod" ]]; then
      RELEASE_TYPE="$TYPE_ARG"
    else
      echo "❌ ERROR: Invalid release type: $TYPE_ARG"
      echo "Expected: stage or prod"
      show_usage
      exit 1
    fi
  fi

  if [ -n "$SNAPSHOT_ARG" ] && [ "$RELEASE_TYPE" = "prod" ]; then
    echo "❌ ERROR: --snapshot is for stage only: prod releases the stage snapshot"
    exit 1
  fi

  echo ""
  echo "============================================"
  echo "Component $RELEASE_TYPE Release Creation"
  echo "============================================"
  echo "Version: $VERSION"
  echo "Release type: $RELEASE_TYPE"
  if [ "$RELEASE_TYPE" = "stage" ]; then
    echo "Release notes: Placeholder (fill via Step 9 workflow)"
  else
    echo "Release notes: Copied from stage"
  fi
  echo ""

  # Resolve repository-owned helpers from this script, independent of caller cwd.
  SCRIPTS_DIR="$GIT_ROOT/scripts"

  # Verify helper scripts exist
  if [ ! -x "$SCRIPTS_DIR/verify-component-release.sh" ] || \
     [ ! -x "$SCRIPTS_DIR/generate-component-release.sh" ]; then
    echo "❌ ERROR: Required helper scripts not found"
    echo "This script requires:"
    echo "  - scripts/verify-component-release.sh"
    echo "  - scripts/generate-component-release.sh"
    exit 1
  fi

  echo "Repository root: $GIT_ROOT"
  echo ""

  # Check we are on the main branch (component release YAMLs must land on main)
  _current_branch=$(git -C "$GIT_ROOT" rev-parse --abbrev-ref HEAD)
  if [ "$_current_branch" != "main" ]; then
    echo "❌ This repo is on branch '$_current_branch', not 'main'" >&2
    echo "   Fix: git checkout main && git pull" >&2
    exit 1
  fi

  # Check git status (working tree should be clean)
  if git -C "$GIT_ROOT" diff-index --quiet HEAD -- 2>/dev/null; then
    :  # Working tree is clean
  else
    echo "⚠️  WARNING: Working tree has uncommitted changes"
    echo "Proceeding anyway - you can review changes before pushing"
    echo ""
  fi
}

# ============================================================================
# Verify Release Readiness
# ============================================================================

verify_release() {
  # Skip verification for prod (uses same snapshot as stage)
  if [ "$RELEASE_TYPE" = "prod" ]; then
    echo "Skipping snapshot verification for prod release"
    echo "(Prod uses same snapshot as stage - already verified)"
    echo ""
    # Extract snapshot from stage YAML for prod generation
    local VERSION_MAJOR_MINOR
    VERSION_MAJOR_MINOR=$(echo "$VERSION" | grep -oE '^[0-9]+\.[0-9]+')
    local VERSION_FULL_DASH
    VERSION_FULL_DASH="${VERSION//./-}"
    # Absolute path: verify_release runs before generate_yaml's `cd "$GIT_ROOT"`,
    # so a relative path would break when invoked from a subdirectory of the repo.
    local STAGE_DIR="$GIT_ROOT/releases/${VERSION_MAJOR_MINOR}/stage"
    local STAGE_YAML
    # `2>/dev/null || true`: if STAGE_DIR doesn't exist yet (stage step not run),
    # find exits non-zero and (with pipefail) would abort under set -e before the
    # friendly "No stage YAML found / Run stage creation first" guard below — and
    # leak a raw "find: ...: No such file or directory" to stderr.
    STAGE_YAML=$(find "$STAGE_DIR" -name "submariner-${VERSION_FULL_DASH}-stage-*.yaml" -type f 2>/dev/null | sort | tail -1) || true
    if [ -z "$STAGE_YAML" ]; then
      echo "❌ ERROR: No stage YAML found"
      echo "Run stage creation first: $0 $VERSION stage"
      exit 1
    fi
    # Prod copies the stage notes and componentProd depends on releaseNotes. Only
    # prod stops: stage is generated with an empty placeholder and may be applied
    # before notes exist so FBC work can proceed. Zero issues is plausible but also
    # the signature of an untriaged backlog, so continuing takes an explicit choice.
    local NOTE_COUNT
    NOTE_COUNT=$(yq '((.spec.data.releaseNotes.issues.fixed // []) | length) + ((.spec.data.releaseNotes.cves // []) | length)' \
      "$STAGE_YAML" 2>/dev/null) || NOTE_COUNT=0
    if [ "${NOTE_COUNT:-0}" = "0" ]; then
      if [ "${ALLOW_EMPTY_RELEASE_NOTES:-}" != "true" ]; then
        echo "❌ ERROR: $STAGE_YAML has no release notes to copy to prod"
        echo "Add them first (Step 9): make add-release-notes VERSION=$VERSION"
        echo "If this release really has no issues or CVEs, re-run with ALLOW_EMPTY_RELEASE_NOTES=true."
        exit 1
      fi
      echo "⚠️  WARNING: continuing with no release notes because ALLOW_EMPTY_RELEASE_NOTES=true." >&2
    fi
    SNAPSHOT_NAME=$(grep "snapshot:" "$STAGE_YAML" | awk '{print $2}')
    echo "Using snapshot from stage: $SNAPSHOT_NAME"
    echo ""
    return 0
  fi

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Verifying component snapshot"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  if [ -z "$SNAPSHOT_ARG" ]; then
    select_snapshot
    return 0
  fi

  # An explicit snapshot is checked like any other, and never replaced.
  echo "Using snapshot passed with --snapshot: $SNAPSHOT_ARG"
  local VERIFY_JSON VERIFY_EXIT
  VERIFY_JSON=$("$SCRIPTS_DIR/verify-component-release.sh" "$VERSION" "$SNAPSHOT_ARG" 2>&1) && VERIFY_EXIT=0 || VERIFY_EXIT=$?

  if [ $VERIFY_EXIT -ne 0 ]; then
    echo "$VERIFY_JSON"
    echo ""
    echo "❌ Verification failed"
    exit 1
  fi

  # Extract JSON (last line) and diagnostic output (everything else)
  local VERIFY_RESULT
  VERIFY_RESULT=$(echo "$VERIFY_JSON" | tail -1)

  # Show diagnostic output from script
  echo "$VERIFY_JSON" | head -n -1

  # Parse JSON to verify status
  local STATUS
  STATUS=$(echo "$VERIFY_RESULT" | jq -r '.status' 2>/dev/null || echo "invalid")
  if [ "$STATUS" != "pass" ]; then
    echo "❌ Verification failed (invalid JSON output)"
    exit 1
  fi

  # Extract snapshot name
  SNAPSHOT_NAME=$(echo "$VERIFY_RESULT" | jq -r '.snapshot')

  echo ""
}

# ============================================================================
# Snapshot selection (stage without --snapshot)
# ============================================================================
#
# One bundle merge can produce several snapshots, and one can pair the rebuilt
# bundle with a component build its CSV doesn't reference: on 0.25.0 a bundle
# push also rebuilt the operator. Walk the newest snapshots and take the first
# that passes verify-component-release.sh and the bundle digest check. The walk
# stops at an older bundle: falling back past the newest bundle build could undo
# the SHA bump, and the freshness gate below can't see that without a tracker.
# A read failure stops rather than skips, so it can't promote an older snapshot.
_selection_read_failure() {
  echo "❌ ERROR: could not read snapshot $1 or its bundle; no snapshot was chosen." >&2
  echo "   Check oc login and registry access, then re-run to retry." >&2
  exit 1
}

select_snapshot() {
  local mm_dash="${VERSION%.*}" list rc=0
  mm_dash="${mm_dash//./-}"
  SNAPSHOT_NAME=""
  list=$("$SCRIPTS_DIR/verify-component-release.sh" "$VERSION" --list 2>/dev/null) || rc=$?
  [ "$rc" -le 1 ] || _selection_read_failure "list"
  if [ -z "$list" ]; then
    echo "❌ ERROR: no push snapshot found for ${VERSION%.*}" >&2
    echo "   Check: oc get snapshots -n submariner-tenant | grep submariner-$mm_dash" >&2
    exit 1
  fi

  local name bundle newest_bundle="" out verify_out skips=() mismatch_out=""
  while read -r name bundle; do
    if [ "$bundle" = "-" ]; then
      skips+=("$name: no bundle")
      continue
    fi
    newest_bundle=${newest_bundle:-$bundle}
    if [ "$bundle" != "$newest_bundle" ]; then
      echo "  Stopped at $name: it and older snapshots have an earlier bundle build"
      break
    fi
    rc=0
    verify_out=$("$SCRIPTS_DIR/verify-component-release.sh" "$VERSION" "$name" 2>&1) || rc=$?
    if [ "$rc" -eq 1 ]; then
      skips+=("$name: failing tests or missing components")
      continue
    fi
    [ "$rc" -eq 0 ] || _selection_read_failure "$name"
    rc=0
    out=$("$SCRIPTS_DIR/validate-bundle-images.sh" --snapshot "$name" 2>&1) || rc=$?
    if [ "$rc" -eq 0 ]; then
      SNAPSHOT_NAME="$name"
      break
    fi
    [ "$rc" -eq 1 ] || { echo "$out" >&2; _selection_read_failure "$name"; }
    skips+=("$name: component digests don't match its bundle CSV")
    [ -n "$mismatch_out" ] || mismatch_out="Newest mismatching candidate $name:"$'\n'"$out"
  done <<<"$list"

  if [ -n "$SNAPSHOT_NAME" ]; then
    echo "$verify_out" | head -n -1
    echo "$out"
    echo ""
    echo "✓ Chose snapshot $SNAPSHOT_NAME (skipped ${#skips[@]} newer)"
    [ "${#skips[@]}" -eq 0 ] || printf '    %s\n' "${skips[@]}"
    echo ""
    return 0
  fi

  echo "" >&2
  echo "❌ ERROR: no recent ${VERSION%.*} snapshot with the newest bundle passes every check." >&2
  [ "${#skips[@]}" -eq 0 ] || printf '    %s\n' "${skips[@]}" >&2
  if [ -n "$mismatch_out" ]; then
    printf '\n%s\n\n' "$mismatch_out" >&2
    echo "   A component was rebuilt after the bundle SHA bump. An operator build without" >&2
    echo "   file filters rebuilds on every bundle push (submariner-io/submariner-operator#4325)." >&2
    echo "   Fix: update the bundle SHAs again (Step 7) from a current snapshot, merge," >&2
    echo "   wait for the bundle rebuild, then re-run." >&2
  else
    echo "   Details: scripts/verify-component-release.sh $VERSION <snapshot>" >&2
  fi
  exit 1
}

# ============================================================================
# Bundle-freshness gate (stage only)
# ============================================================================
#
# Guards the documented bundleShas → componentStage stale-bundle hazard: this
# step must release a snapshot whose submariner-bundle was REBUILT since
# bundleShas selected its snapshot — i.e. after the operator merged the SHA-bump
# PR. verify-component-release.sh only checks that 9 components are present and
# tests pass; it never confirms the bundle postdates the merge. Without this
# gate, a re-run before the rebuild lands emits a stage Release YAML pointing at
# a pre-rebuild (stale) bundle whose relatedImages still reference pre-bump SHAs.
#
# Signal: a submariner-bundle image digest changes ONLY when the bundle is
# rebuilt (a bundle/ push), so if the chosen snapshot's bundle digest still
# equals the bundleShas-recorded snapshot's bundle digest, no rebuild has landed
# → STOP. An unrelated component push produces a new snapshot but does not
# rebuild the bundle, so this never false-passes on an intervening snapshot.
# Read-only: two `oc get snapshot` reads, no image pull, no writes.
#
# Fails OPEN (warn + proceed) whenever it cannot compare — no tracker, no
# recorded bundleShas snapshot, or a digest it can't read (e.g. that snapshot
# was garbage-collected). The complementary `bundleShas` review stop already
# puts a human in the loop, and a legitimate run must never hard-block on absent
# bookkeeping. It hard-STOPS only on a positive stale detection.
_bundle_digest() {
  local snap="$1" comp="$2" image=""
  # `|| true`: oc on a missing snapshot/component exits non-zero (and prints
  # nothing), which under set -e/pipefail would abort before the caller's
  # empty-means-unreadable fail-open guard.
  image=$(oc get snapshot "$snap" -n submariner-tenant \
    -o jsonpath="{.spec.components[?(@.name==\"$comp\")].containerImage}" 2>/dev/null) || true
  printf '%s' "$image" | grep -oE 'sha256:[a-f0-9]+' || true
}

assert_bundle_rebuilt() {
  # Prod reuses the stage-verified snapshot — nothing to re-gate.
  [ "$RELEASE_TYPE" = "stage" ] || return 0
  # No tracker → no recorded bundleShas snapshot to compare against.
  [ -n "${TRACKER:-}" ] || return 0

  local mm_dash="${VERSION%.*}"   # 0.22.1 → 0.22
  mm_dash="${mm_dash//./-}"       # 0.22   → 0-22
  local bundle_comp="submariner-bundle-${mm_dash}"

  # bundleShas-recorded (pre-rebuild) snapshot. get_step returns non-zero on a
  # tracker READ failure and empty when the step is genuinely absent; treat both
  # as "can't compare" (fail open), never conflating a Jira blip with staleness.
  local bs_data bs_rc=0
  bs_data=$(get_step "$VERSION" "bundleShas" "$TRACKER") || bs_rc=$?
  local bs_snap=""
  [ "$bs_rc" -eq 0 ] && bs_snap=$(printf '%s' "$bs_data" | jq -r '.data.snapshot // empty' 2>/dev/null || true)
  if [ -z "$bs_snap" ]; then
    echo "⚠️  Bundle-freshness gate skipped: no bundleShas snapshot recorded in the tracker." >&2
    echo "    Confirm the bundle SHA-bump PR is merged and rebuilt before applying (Step 10)." >&2
    return 0
  fi

  local chosen_digest recorded_digest
  chosen_digest=$(_bundle_digest "$SNAPSHOT_NAME" "$bundle_comp")
  recorded_digest=$(_bundle_digest "$bs_snap" "$bundle_comp")
  if [ -z "$chosen_digest" ] || [ -z "$recorded_digest" ]; then
    echo "⚠️  Bundle-freshness gate skipped: could not read submariner-bundle digest" >&2
    echo "    (chosen=$SNAPSHOT_NAME recorded=$bs_snap). Confirm the bundle was rebuilt" >&2
    echo "    after the SHA-bump merge before applying (Step 10)." >&2
    return 0
  fi

  if [ "$chosen_digest" = "$recorded_digest" ]; then
    echo "" >&2
    echo "❌ ERROR: Stale bundle — the release snapshot's submariner-bundle has NOT been" >&2
    echo "   rebuilt since bundleShas selected its snapshot." >&2
    echo "" >&2
    echo "   Chosen snapshot:     $SNAPSHOT_NAME" >&2
    echo "   bundleShas snapshot: $bs_snap" >&2
    echo "   submariner-bundle:   $chosen_digest (unchanged)" >&2
    echo "" >&2
    echo "   The bundle SHA-bump commit is not yet merged + rebuilt, so this snapshot's" >&2
    echo "   bundle still pins pre-bump component SHAs. Releasing it would ship a stale" >&2
    echo "   bundle." >&2
    echo "" >&2
    echo "   Fix: push/merge the bundleShas PR, wait for the Konflux bundle rebuild to" >&2
    echo "   produce a new snapshot, then re-run this step." >&2
    exit 1
  fi

  echo "✓ Bundle freshness: submariner-bundle rebuilt since bundleShas (${chosen_digest:0:19}…)" >&2
}

# ============================================================================
# Bundle digest gate (stage and prod)
# ============================================================================
#
# A snapshot can pair a bundle with component builds its CSV does not reference.
# Check before generating anything; a failed read stops too, so this fails closed.
assert_bundle_digests() {
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Checking snapshot digests against the bundle CSV"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  if "$SCRIPTS_DIR/validate-bundle-images.sh" --snapshot "$SNAPSHOT_NAME"; then
    echo ""
    return 0
  fi
  echo "" >&2
  echo "❌ ERROR: snapshot $SNAPSHOT_NAME failed the bundle digest check (see above)." >&2
  echo "   No release YAML was created." >&2
  echo "   Mismatch: do not release this snapshot. Use one whose bundle references its" >&2
  echo "   component builds; stage without --snapshot chooses one." >&2
  echo "   Read failure: check oc login and registry access, then re-run to retry." >&2
  exit 1
}

# ============================================================================
# Generate Release YAML
# ============================================================================

generate_yaml() {
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Generating Release YAML"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  # Get release date
  local RELEASE_DATE
  RELEASE_DATE=$(date +%Y%m%d)

  # Change to git root so generate script can use relative paths
  cd "$GIT_ROOT" || exit 1

  # Call generate script. Capture exit inline (&& / ||): a bare `X=$(...)` on its
  # own line propagates the command's failure under set -e, aborting before the
  # error handler below could run.
  local GENERATE_EXIT=0
  YAML_FILE=$("$SCRIPTS_DIR/generate-component-release.sh" "$VERSION" "$SNAPSHOT_NAME" "$RELEASE_TYPE" "$RELEASE_DATE" 2>&1) || GENERATE_EXIT=$?

  if [ $GENERATE_EXIT -ne 0 ]; then
    echo "$YAML_FILE"
    echo "❌ Failed to generate YAML"
    exit 1
  fi

  # Extract filename from output (last line should be the file path)
  YAML_FILE=$(echo "$YAML_FILE" | tail -1)

  if [ ! -f "$YAML_FILE" ]; then
    echo "❌ Generated file not found: $YAML_FILE"
    exit 1
  fi

  echo "✓ Created: $YAML_FILE"
  echo ""
}

# ============================================================================
# Validate YAML
# ============================================================================

validate_yaml() {
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Validating Release YAML"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  echo "Validating $(basename "$YAML_FILE")..."

  if [ "$RELEASE_TYPE" = "prod" ]; then
    # For prod, run local validation only (snapshot not releasable yet)
    echo "Running local validation only (prod uses same snapshot as stage)..."
    if make -C "$GIT_ROOT" test FILE="$YAML_FILE" >/dev/null 2>&1; then
      echo "  ✓ Validation passed"
    else
      echo "  ✗ Validation failed"
      echo ""
      echo "❌ Validation failed"
      echo "Run 'make -C $GIT_ROOT test FILE=$YAML_FILE' for details"
      exit 1
    fi
  else
    # For stage with notes placeholder, run full validation
    echo "Running full validation (including cluster checks)..."
    if make -C "$GIT_ROOT" test-remote FILE="$YAML_FILE" >/dev/null 2>&1; then
      echo "  ✓ Validation passed"
    else
      echo "  ✗ Validation failed"
      echo ""
      echo "❌ Validation failed"
      echo "Run 'make -C $GIT_ROOT test-remote FILE=$YAML_FILE' for details"
      exit 1
    fi
  fi

  echo ""
  echo "✓ YAML validation passed"
}

# ============================================================================
# Commit Changes
# ============================================================================

commit_changes() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Creating commit"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  # Stage the created file
  git add "$YAML_FILE" || {
    echo "❌ ERROR: Failed to stage file"
    exit 1
  }

  # Show what's being committed
  echo "File to commit:"
  git status --short | grep "^A" | sed 's/^A  /  /'
  echo ""

  # Create commit message
  local COMMIT_MSG
  if [ "$RELEASE_TYPE" = "stage" ]; then
    COMMIT_MSG="Add component ${RELEASE_TYPE} release for $VERSION

Snapshot: $SNAPSHOT_NAME
Release notes: Fill placeholder via Step 9 workflow"
  else
    COMMIT_MSG="Add component ${RELEASE_TYPE} release for $VERSION

Snapshot: $SNAPSHOT_NAME (same as stage)
Release notes: Copied from stage (QE-verified)"
  fi

  # Create commit
  git commit -s -m "$COMMIT_MSG" || {
    echo "❌ ERROR: Failed to create commit"
    exit 1
  }

  local COMMIT_HASH
  COMMIT_HASH=$(git rev-parse --short HEAD)

  echo "✓ Commit created: $COMMIT_HASH"
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "SUCCESS - Component ${RELEASE_TYPE} release created"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "Next steps:"
  echo ""
  echo "1. Review changes:"
  echo "   git show"
  echo ""
  echo "2. Push commit:"
  local _gh_user _fork _branch _rel_name
  _gh_user=$(get_gh_user)
  _fork=$(fork_remote "$GIT_ROOT" "$_gh_user")
  _branch=$(git rev-parse --abbrev-ref HEAD)
  echo "   git push $_fork $_branch"
  # Append to push summary if conductor is running. This is a release-YAML step,
  # so the load-bearing next actions are apply/watch (not just git push) — emit
  # the full trailer the operator must run after this script.
  if [ -n "${AUTORELEASE_PUSH_LOG:-}" ]; then
    _rel_name=$(basename "$YAML_FILE" .yaml)
    # make apply already runs make test-remote as a prerequisite, so listing
    # it separately here would run it twice. Show only apply/watch.
    printf '\n  cd %s\n  git push %s %s\n  make apply FILE=%s\n  make watch NAME=%s\n' \
      "$GIT_ROOT" "$_fork" "$_branch" "$YAML_FILE" "$_rel_name" \
      >> "$AUTORELEASE_PUSH_LOG"
  fi
  echo ""
  if [ "$RELEASE_TYPE" = "stage" ]; then
    echo "3. Fill release notes placeholder (issues.fixed[], cves[])"
    echo ""
    echo "4. Apply release to cluster:"
  else
    echo "3. Apply release to cluster:"
  fi
  echo "   make apply FILE=$YAML_FILE"
  local RELEASE_NAME
  RELEASE_NAME=$(basename "$YAML_FILE" .yaml)
  echo "   make watch NAME=$RELEASE_NAME"
  echo ""
  echo "To undo this commit:"
  echo "   git reset HEAD~1"
  echo ""
}

# ============================================================================
# Main Execution
# ============================================================================

main() {
  # parse_arguments must run first: it sets RELEASE_TYPE and SCRIPTS_DIR (used by
  # the tracker source).
  parse_arguments "$@"
  check_prerequisites
  # Candidates usually share one bundle: extract its manifests once.
  BUNDLE_CACHE_DIR=$(mktemp -d)
  export BUNDLE_CACHE_DIR
  trap 'rm -rf "$BUNDLE_CACHE_DIR"' EXIT

  # Tracker integration
  TRACKER_LIB="${TRACKER_LIB:-$SCRIPTS_DIR/lib/jira-tracker.sh}"
  # shellcheck source=lib/jira-tracker.sh
  [ -f "$TRACKER_LIB" ] && source "$TRACKER_LIB" 2>/dev/null || true
  # shellcheck source=lib/git-utils.sh
  [ -f "$SCRIPTS_DIR/lib/git-utils.sh" ] && source "$SCRIPTS_DIR/lib/git-utils.sh" 2>/dev/null || true
  TRACKER=$(find_release_tracker "$VERSION" 2>/dev/null || true)
  STEP_KEY=$( [ "$RELEASE_TYPE" = "prod" ] && echo "componentProd" || echo "componentStage" )
  if [ "$RELEASE_TYPE" = "stage" ]; then
    require_upstream_tag "$VERSION" "$STEP_KEY" || exit 1
  fi

  # Phase 3: QE gate check for prod releases. get_step returns non-zero on a
  # tracker READ failure and empty output when the step is genuinely absent, so
  # keep the two apart — a Jira blip must not masquerade as "QE not signed off".
  # Either way we only generate/commit the YAML (a human still applies it in
  # Step 16), so this is an explicit advisory, not a hard stop.
  if [ "$RELEASE_TYPE" = "prod" ] && [ -n "${TRACKER:-}" ]; then
    local qe_data qe_rc=0
    qe_data=$(get_step "$VERSION" "qeValidation" "$TRACKER") || qe_rc=$?
    local qe_status=""
    [ "$qe_rc" -eq 0 ] && qe_status=$(printf '%s' "$qe_data" | jq -r '.status // empty' 2>/dev/null || true)

    if [ "$qe_rc" -ne 0 ]; then
      echo "⚠️  Could not read QE validation status (tracker read failed)." >&2
      echo "    Generating the prod release YAML anyway — confirm QE sign-off" >&2
      echo "    before applying it in Step 16." >&2
    elif [ "$qe_status" != "complete" ]; then
      echo "⚠️  QE validation is not marked complete in the tracker." >&2
      echo "    Generating the prod release YAML anyway — do NOT apply it (Step 16)" >&2
      echo "    until QE signs off, or mark the qeValidation subtask complete." >&2
    fi
  fi

  verify_release
  # Both bundle gates run before the idempotency check: in a respin run before the
  # bundle rebuild, selection falls back to the snapshot already released, and
  # that must stop as a stale bundle, not complete the step.
  assert_bundle_rebuilt
  # Selection already checked an automatically chosen snapshot's digests.
  if [ "$RELEASE_TYPE" = "prod" ] || [ -n "$SNAPSHOT_ARG" ]; then
    assert_bundle_digests
  fi

  # Idempotency: if a Release CR for this snapshot is already Succeeded on the
  # cluster, the step was already applied in a previous run. Mark it complete so
  # the conductor advances instead of creating a duplicate YAML.
  if [ -n "${SNAPSHOT_NAME:-}" ]; then
    local rel_dir="$GIT_ROOT/releases/${VERSION%.*}/$RELEASE_TYPE"
    local existing_yaml=""
    existing_yaml=$(grep -rl "snapshot: $SNAPSHOT_NAME" "$rel_dir" 2>/dev/null | head -1 || true)
    if [ -n "$existing_yaml" ]; then
      local rel_name
      rel_name=$(basename "$existing_yaml" .yaml)
      local rel_status=""
      rel_status=$(oc get release "$rel_name" -n submariner-tenant \
        -o jsonpath='{.status.conditions[?(@.type=="Released")].status}' 2>/dev/null || true)
      if [ "$rel_status" = "True" ]; then
        echo "✓ $RELEASE_TYPE release already Succeeded for snapshot $SNAPSHOT_NAME ($rel_name)"
        echo "  Marking $STEP_KEY complete in tracker — no duplicate YAML needed."
        if [ -n "${TRACKER:-}" ]; then
          local idem_data
          idem_data=$(jq -n --arg name "$rel_name" --arg snap "$SNAPSHOT_NAME" --arg type "$RELEASE_TYPE" \
            '{releaseName:$name,snapshot:$snap,type:$type}' | jq -c .) || idem_data="{}"
          update_step "$VERSION" "$STEP_KEY" "complete" "$idem_data" "$TRACKER" || true
        fi
        return 0
      fi
    fi
  fi

  # Mark in progress only once every stop has passed.
  [ -n "${TRACKER:-}" ] && update_step "$VERSION" "$STEP_KEY" "in_progress" '{}' "$TRACKER"
  generate_yaml
  validate_yaml
  commit_changes

  # review level: script stays in_progress. User must apply the Release CR and wait
  # for the build to complete, then explicitly mark complete. This prevents chaining
  # to downstream steps before the release pipeline has produced a bundle/index.
  if [ -n "${TRACKER:-}" ]; then
    local release_name
    release_name=$(basename "${YAML_FILE:-.yaml}" .yaml)
    local data
    # shellcheck disable=SC2034
    data=$(jq -n --arg name "$release_name" --arg snap "${SNAPSHOT_NAME:-}" --arg type "$RELEASE_TYPE" \
      '{releaseName:$name,snapshot:$snap,type:$type}' | jq -c .) || data="{}"
  fi
}

# Run main only when executed directly; sourcing (e.g. from the test harness)
# exposes the functions without running the release flow.
if [ "${BASH_SOURCE[0]:-}" = "${0:-}" ]; then
  main "$@"
fi
