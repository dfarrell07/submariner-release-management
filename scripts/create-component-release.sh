#!/bin/bash
# Create component release (stage or prod)
#
# Usage: create-component-release.sh <version> [stage|prod]
#
# Arguments:
#   version: Submariner version (e.g., 0.22.1 or 0.22)
#   [stage|prod]: Release type (default: stage)
#
# Exit codes:
#   0: Success (release created and committed)
#   1: Failure (prerequisites, validation, or commit failed)

set -euo pipefail

# Global variables (set by parse_arguments)
VERSION=""
RELEASE_TYPE="stage"
GIT_ROOT=""
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

  if [ "${#MISSING_TOOLS[@]}" -gt 0 ]; then
    echo "❌ ERROR: Missing required tools: ${MISSING_TOOLS[*]}"
    echo ""
    echo "Installation instructions:"
    for tool in "${MISSING_TOOLS[@]}"; do
      case "$tool" in
        oc) echo "  oc: https://docs.openshift.com/container-platform/latest/cli_reference/openshift_cli/getting-started-cli.html" ;;
        jq) echo "  jq: https://jqlang.github.io/jq/download/" ;;
        git) echo "  git: https://git-scm.com/downloads" ;;
      esac
    done
    exit 1
  fi

  # Check oc authentication (only for stage/prod that need snapshot)
  if [ "$RELEASE_TYPE" = "stage" ]; then
    if oc whoami &>/dev/null; then
      :  # Already authenticated
    else
      echo ""
      echo "============================================"
      echo "ERROR: Not authenticated with Konflux"
      echo "============================================"
      echo "This script requires oc authentication."
      echo "Run: oc login --web https://api.kflux-prd-rh02.0fk9.p1.openshiftapps.com:6443/"
      echo ""
      exit 1
    fi
  fi

  echo "✓ Prerequisites verified: oc, jq, git"
  if oc whoami &>/dev/null; then
    echo "✓ Authenticated with Konflux as: $(oc whoami)"
  fi
}

# ============================================================================
# Argument Parsing
# ============================================================================

show_usage() {
  echo "Usage: $0 <version> [stage|prod]"
  echo "Example: $0 0.22.1"
  echo "Example: $0 0.22.1 stage"
  echo "Example: $0 0.22.1 prod"
}

parse_arguments() {
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

  # Find git repository root (allows running from anywhere in repo)
  # `|| true`: outside a git repo `git rev-parse` exits non-zero, which under
  # set -e would abort before the friendly "Not in a git repository" guard below
  # (matches create-fbc-releases.sh:159).
  GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || true
  if [ -z "$GIT_ROOT" ]; then
    echo "❌ ERROR: Not in a git repository"
    exit 1
  fi

  # Set up paths relative to git root
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
  _current_branch=$(git rev-parse --abbrev-ref HEAD)
  if [ "$_current_branch" != "main" ]; then
    echo "❌ This repo is on branch '$_current_branch', not 'main'" >&2
    echo "   Fix: git checkout main && git pull" >&2
    exit 1
  fi

  # Check git status (working tree should be clean)
  if git diff-index --quiet HEAD -- 2>/dev/null; then
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
    SNAPSHOT_NAME=$(grep "snapshot:" "$STAGE_YAML" | awk '{print $2}')
    echo "Using snapshot from stage: $SNAPSHOT_NAME"
    echo ""
    return 0
  fi

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Verifying component snapshot"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  # Call verification script
  local VERIFY_JSON VERIFY_EXIT
  VERIFY_JSON=$("$SCRIPTS_DIR/verify-component-release.sh" "$VERSION" 2>&1) && VERIFY_EXIT=0 || VERIFY_EXIT=$?

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
  # parse_arguments must run first: it sets RELEASE_TYPE (which check_prerequisites
  # branches on for the oc-auth check) and SCRIPTS_DIR (used by the tracker source).
  parse_arguments "$@"
  check_prerequisites

  # Tracker integration
  TRACKER_LIB="${TRACKER_LIB:-$SCRIPTS_DIR/lib/jira-tracker.sh}"
  # shellcheck source=lib/jira-tracker.sh
  [ -f "$TRACKER_LIB" ] && source "$TRACKER_LIB" 2>/dev/null || true
  # shellcheck source=lib/git-utils.sh
  [ -f "$SCRIPTS_DIR/lib/git-utils.sh" ] && source "$SCRIPTS_DIR/lib/git-utils.sh" 2>/dev/null || true
  TRACKER=$(find_release_tracker "$VERSION" 2>/dev/null || true)
  STEP_KEY=$( [ "$RELEASE_TYPE" = "prod" ] && echo "componentProd" || echo "componentStage" )
  [ -n "${TRACKER:-}" ] && update_step "$VERSION" "$STEP_KEY" "in_progress" '{}' "$TRACKER"

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
  assert_bundle_rebuilt
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
