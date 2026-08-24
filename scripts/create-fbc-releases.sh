#!/bin/bash
# Create FBC releases for all OCP versions (stage or prod)
#
# Usage: create-fbc-releases.sh <version> [stage|prod]
#
# Arguments:
#   version: Submariner version (e.g., 0.22.1 or 0.22)
#   stage|prod: Release type (default: stage) - matches create-component-release.sh
#
# Exit codes:
#   0: Success (releases created and committed)
#   1: Failure (prerequisites, validation, or commit failed)

set -euo pipefail

# Global variables (set by parse_arguments)
VERSION=""
RELEASE_TYPE="stage"
GIT_ROOT=""
SCRIPTS_DIR=""
RELEASES_DIR=""

# Global variables (set by verify_release)
declare -A SNAPSHOTS

# Global variables (set by generate_yamls)
declare -a CREATED_FILES

# ============================================================================
# Prerequisites Check
# ============================================================================

check_prerequisites() {
  local MISSING_TOOLS=()

  command -v oc &>/dev/null || MISSING_TOOLS+=("oc")
  command -v jq &>/dev/null || MISSING_TOOLS+=("jq")
  command -v curl &>/dev/null || MISSING_TOOLS+=("curl")
  command -v git &>/dev/null || MISSING_TOOLS+=("git")

  if [ "${#MISSING_TOOLS[@]}" -gt 0 ]; then
    echo "❌ ERROR: Missing required tools: ${MISSING_TOOLS[*]}"
    echo ""
    echo "Installation instructions:"
    for tool in "${MISSING_TOOLS[@]}"; do
      case "$tool" in
        oc) echo "  oc: https://docs.openshift.com/container-platform/latest/cli_reference/openshift_cli/getting-started-cli.html" ;;
        jq) echo "  jq: https://jqlang.github.io/jq/download/" ;;
        curl) echo "  curl: included in most systems" ;;
        git) echo "  git: https://git-scm.com/downloads" ;;
      esac
    done
    exit 1
  fi

  # Check bash version
  local BASH_MAJOR
  BASH_MAJOR=$(bash -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null)
  if [ -z "$BASH_MAJOR" ]; then
    BASH_MAJOR=$(bash --version 2>/dev/null | head -1 | sed -nE 's/.*version ([0-9]+).*/\1/p')
  fi

  if [ -z "$BASH_MAJOR" ] || [ "$BASH_MAJOR" -lt 4 ]; then
    local BASH_VER
    BASH_VER=$(bash --version 2>/dev/null | head -1 || echo "unknown")
    echo "❌ ERROR: bash 4.0+ required (current: $BASH_VER)"
    echo "This script uses associative arrays (declare -A) which require bash 4.0+."
    echo ""
    echo "macOS users: brew install bash"
    exit 1
  fi

  # Check oc authentication. Prod reuses the stage snapshots (read from the
  # stage YAMLs) and makes no cluster calls, so it needs no login — only
  # stage queries Konflux. (Requires RELEASE_TYPE, so parse_arguments runs first.)
  if [ "$RELEASE_TYPE" != "prod" ]; then
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

  echo "✓ Prerequisites verified: bash 4.0+, oc, jq, curl, git"
  if oc whoami &>/dev/null; then
    echo "✓ Authenticated with Konflux as: $(oc whoami)"
  fi
}

# ============================================================================
# Argument Parsing
# ============================================================================

parse_arguments() {
  # Parse arguments (version, stage|prod - order-independent)
  local ARG1="${1:-}"
  local ARG2="${2:-}"
  local REST="${3:-}"

  if [ -n "$REST" ]; then
    echo "❌ ERROR: Too many arguments"
    echo "Usage: $0 <version> [stage|prod]"
    exit 1
  fi

  for arg in "$ARG1" "$ARG2"; do
    [ -z "$arg" ] && continue

    case "$arg" in
      stage|prod)
        RELEASE_TYPE="$arg"
        ;;
      [0-9].[0-9]|[0-9].[0-9].[0-9]|[0-9].[0-9][0-9]|[0-9].[0-9][0-9].[0-9]|[0-9].[0-9][0-9].[0-9][0-9])
        VERSION="$arg"
        ;;
      *)
        echo "❌ ERROR: Unknown argument: $arg"
        echo "Usage: $0 <version> [stage|prod]"
        echo "Example: $0 0.22.1 stage"
        exit 1
        ;;
    esac
  done

  if [ -z "$VERSION" ]; then
    echo "❌ ERROR: Version required"
    echo "Usage: $0 <version> [stage|prod]"
    echo "Example: $0 0.22.1 stage"
    exit 1
  fi

  # Validate version format
  if [[ "$VERSION" =~ ^[0-9]+\.[0-9]+ ]]; then
    :  # Version format is valid
  else
    echo "❌ ERROR: Invalid version format: $VERSION"
    echo "Expected: 0.Y or 0.Y.Z (e.g., 0.22 or 0.22.1)"
    exit 1
  fi

  echo ""
  echo "============================================"
  echo "FBC $RELEASE_TYPE Release Creation"
  echo "============================================"
  echo "Version: $VERSION"
  echo "Release type: $RELEASE_TYPE"
  echo ""

  # Find git repository root (allows running from anywhere in repo)
  # `|| true`: outside a git repo `git rev-parse` exits non-zero, which under
  # set -e would abort before the friendly "Not in a git repository" guard below.
  GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || true
  if [ -z "$GIT_ROOT" ]; then
    echo "❌ ERROR: Not in a git repository"
    exit 1
  fi

  # Set up paths relative to git root
  SCRIPTS_DIR="$GIT_ROOT/scripts"
  RELEASES_DIR="$GIT_ROOT/releases"

  # Verify this is the correct repository by checking for required scripts
  if [ -x "$SCRIPTS_DIR/verify-fbc-release.sh" ] && \
     [ -x "$SCRIPTS_DIR/generate-fbc-release.sh" ]; then
    :  # Scripts exist
  else
    echo "❌ ERROR: Required helper scripts not found"
    echo "This skill requires the submariner-release-management repository"
    echo "Looked in: $SCRIPTS_DIR"
    exit 1
  fi

  echo "Repository root: $GIT_ROOT"
  echo ""

  # Check we are on the main branch (FBC release YAMLs must land on main)
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
  # Prod reuses the EXACT snapshots QE validated in stage. Re-deriving the latest
  # snapshot here (as stage does) could pick up a catalog rebuilt during the
  # multi-day QE gate — a build QE never tested — and silently ship it. Mirror
  # the documented invariant (create-fbc-prod-release.md: "same snapshot as
  # stage") and component-prod, which reads spec.snapshot from the stage YAML.
  if [ "$RELEASE_TYPE" = "prod" ]; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Reusing stage snapshots for prod release"
    echo "(same snapshots as stage - already QE-verified)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    local STAGE_DIR OCP_VERSION STAGE_YAML SNAPSHOT COUNT=0
    local VERSION_DASH="${VERSION//./-}"
    for STAGE_DIR in "$GIT_ROOT"/releases/fbc/4-*/stage; do
      [ -d "$STAGE_DIR" ] || continue
      OCP_VERSION=$(basename "$(dirname "$STAGE_DIR")")  # 4-XX
      # Latest stage YAML for this version and OCP version — filtering by VERSION_DASH
      # prevents silently picking up a stage YAML from a prior Z-stream cycle when
      # multiple releases have accumulated in the same per-OCP directory.
      STAGE_YAML=$(find "$STAGE_DIR" -name "submariner-fbc-${OCP_VERSION}-${VERSION_DASH}-stage-*.yaml" -type f | sort | tail -1)
      [ -z "$STAGE_YAML" ] && continue
      # `|| true`: a corrupted/hand-edited stage YAML with no `snapshot:` line
      # makes grep exit non-zero, which (with pipefail) would abort under set -e
      # before the friendly guard below (matches the git-rev-parse fix at :159).
      SNAPSHOT=$(grep "snapshot:" "$STAGE_YAML" | awk '{print $2}') || true
      if [ -z "$SNAPSHOT" ]; then
        echo "❌ ERROR: No snapshot found in stage YAML: $STAGE_YAML" >&2
        exit 1
      fi
      SNAPSHOTS["$OCP_VERSION"]="$SNAPSHOT"
      # Warn if the stage YAML is more than 90 days old — it may be from a
      # previous release cycle silently picked up by the 'latest YAML' logic.
      local _stage_date _stage_epoch _now_epoch _age_days
      _stage_date=$(basename "$STAGE_YAML" .yaml | grep -oE '[0-9]{8}' | head -1) || _stage_date=""
      if [ -n "$_stage_date" ]; then
        _stage_epoch=$(date -d "$_stage_date" +%s 2>/dev/null || echo 0)
        _now_epoch=$(date +%s)
        _age_days=$(( (_now_epoch - _stage_epoch) / 86400 ))
        if [ "$_age_days" -gt 90 ]; then
          echo "  ⚠ ${OCP_VERSION}: stage YAML is ${_age_days} days old — may be from a" >&2
          echo "    previous release cycle ($(basename "$STAGE_YAML"))." >&2
          echo "    Verify this is the correct artifact before applying." >&2
        fi
      fi
      echo "  ${OCP_VERSION}: reusing $SNAPSHOT (from $(basename "$STAGE_YAML"))"
      COUNT=$((COUNT + 1))
    done
    if [ "$COUNT" -eq 0 ]; then
      echo "❌ ERROR: No FBC stage YAMLs found under releases/fbc/*/stage/" >&2
      echo "Run stage creation first: $0 $VERSION stage" >&2
      exit 1
    fi
    echo ""
    return 0
  fi

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Verifying FBC snapshots and component SHAs"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  # Call combined verification script (batched queries + parallel extraction)
  local COMBINED_JSON
  local VERIFY_EXIT=0
  COMBINED_JSON=$("$SCRIPTS_DIR/verify-fbc-release.sh" "$VERSION" 2>&1) || VERIFY_EXIT=$?

  if [ $VERIFY_EXIT -ne 0 ]; then
    echo "$COMBINED_JSON"
    echo ""
    echo "❌ Verification failed"
    exit 1
  fi

  # Extract JSON (single line) and diagnostic output (everything else)
  local COMBINED_RESULT
  COMBINED_RESULT=$(echo "$COMBINED_JSON" | tail -1)

  # Show diagnostic output from script (all lines except JSON)
  echo "$COMBINED_JSON" | head -n -1

  # Parse JSON to verify status
  local STATUS
  STATUS=$(echo "$COMBINED_RESULT" | jq -r '.status' 2>/dev/null || echo "invalid")
  if [ "$STATUS" != "pass" ]; then
    echo "❌ Verification failed (invalid JSON output)"
    exit 1
  fi

  # Extract applicable OCP versions and snapshot names dynamically
  local APPLICABLE
  APPLICABLE=$(echo "$COMBINED_RESULT" | jq -r '.applicable_versions[]')
  for VERSION_NUM in $APPLICABLE; do
    local SNAPSHOT
    SNAPSHOT=$(echo "$COMBINED_RESULT" | jq -r ".snapshots[\"4-${VERSION_NUM}\"]")
    SNAPSHOTS["4-${VERSION_NUM}"]="$SNAPSHOT"
  done

  echo ""
}

# ============================================================================
# Generate Release YAMLs
# ============================================================================

generate_yamls() {
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Generating Release YAMLs"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  # Get release date
  local RELEASE_DATE
  RELEASE_DATE=$(date +%Y%m%d)

  # Change to git root so generate script can use relative paths
  cd "$GIT_ROOT" || exit 1

  local COUNT=0
  for VERSION_NUM in $(echo "${!SNAPSHOTS[@]}" | tr ' ' '\n' | sed 's/^4-//' | sort -n); do
    local OCP_VERSION="4-${VERSION_NUM}"
    local SNAPSHOT="${SNAPSHOTS[$OCP_VERSION]}"

    if [ -z "$SNAPSHOT" ] || [ "$SNAPSHOT" = "null" ]; then
      continue
    fi

    echo "Generating ${OCP_VERSION} release..."

    # Call generate-fbc-release.sh using absolute path.
    # Split declaration from assignment and use `|| GENERATE_EXIT=$?`: under
    # set -e a bare `VAR=$(cmd)` on its own line aborts the script on cmd
    # failure before the `if` handler runs, swallowing the diagnostic below.
    local YAML_FILE GENERATE_EXIT=0
    YAML_FILE=$("$SCRIPTS_DIR/generate-fbc-release.sh" "$OCP_VERSION" "$VERSION" "$SNAPSHOT" "$RELEASE_TYPE" "$RELEASE_DATE") || GENERATE_EXIT=$?

    if [ "$GENERATE_EXIT" -ne 0 ]; then
      echo "❌ Failed to generate YAML for ${OCP_VERSION}"
      exit 1
    fi

    echo "  ✓ Created: $YAML_FILE"
    CREATED_FILES+=("$YAML_FILE")
    COUNT=$((COUNT + 1))
  done

  echo ""
  echo "✓ Created $COUNT FBC ${RELEASE_TYPE} Release YAMLs"
}

# ============================================================================
# Validate YAMLs
# ============================================================================

validate_yamls() {
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Validating Release YAMLs"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  local VALIDATION_FAILED=0
  # Prod reuses stage-verified snapshots (no cluster call needed); local-only
  # make test is sufficient and avoids requiring oc login for prod.
  local _test_target="test-remote"
  [ "$RELEASE_TYPE" = "prod" ] && _test_target="test"

  for YAML_FILE in "${CREATED_FILES[@]}"; do
    echo "Validating $(basename "$YAML_FILE")..."

    if make -C "$GIT_ROOT" "$_test_target" FILE="$YAML_FILE" >/dev/null 2>&1; then
      echo "  ✓ Validation passed"
    else
      echo "  ✗ Validation failed"
      VALIDATION_FAILED=$((VALIDATION_FAILED + 1))
    fi
  done

  if [ $VALIDATION_FAILED -gt 0 ]; then
    echo ""
    echo "❌ $VALIDATION_FAILED YAML(s) failed validation"
    echo "Run 'make -C $GIT_ROOT $_test_target FILE=<yaml>' for details"
    exit 1
  fi

  echo ""
  echo "✓ All YAMLs passed validation"
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

  # Stage all created files using absolute path
  git add "$RELEASES_DIR/fbc/" || {
    echo "❌ ERROR: Failed to stage files"
    exit 1
  }

  # Show what's being committed
  echo "Files to commit:"
  git status --short | grep "^A" | sed 's/^A  /  /' || true
  echo ""

  # Create commit message. The body reflects what actually ran: stage verifies
  # snapshots/SHAs against Konflux; prod reuses the stage-verified snapshots
  # (no re-derivation), so it lists that provenance instead.
  local COMMIT_MSG
  local OCP_LIST
  OCP_LIST=$(echo "${!SNAPSHOTS[@]}" | tr ' ' '\n' | sort -t- -k2 -n | xargs)
  if [ "$RELEASE_TYPE" = "prod" ]; then
    COMMIT_MSG="Add FBC prod releases for $VERSION

Generated ${#CREATED_FILES[@]} Release CRs (${OCP_LIST}) with:
- Reused QE-verified stage snapshots (identical to stage releases)
- Validated with make test (local-only)"
  else
    COMMIT_MSG="Add FBC ${RELEASE_TYPE} releases for $VERSION

Generated ${#CREATED_FILES[@]} Release CRs (${OCP_LIST}) with:
- Verified GitHub catalog consistency
- Verified FBC snapshots (push events, tests passed)
- Verified component SHAs across all sources
- Validated with make test-remote"
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
  echo "SUCCESS - FBC ${RELEASE_TYPE} releases created"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "Next steps:"
  echo ""
  echo "1. Review changes:"
  echo "   git show"
  echo ""
  echo "2. Push commit:"
  echo "   git push origin \$(git rev-parse --abbrev-ref HEAD)"
  # Append to push summary if conductor is running. This is a release-YAML step,
  # so emit the full apply/watch trailer for every OCP version (not just git
  # push) — apply/watch are the load-bearing next actions.
  if [ -n "${AUTORELEASE_PUSH_LOG:-}" ]; then
    local _branch
    _branch=$(git rev-parse --abbrev-ref HEAD)
    {
      printf '\n  cd %s\n  git push origin %s\n' "$GIT_ROOT" "$_branch"
      # make apply already runs make test-remote as a prerequisite — omit it here.
      for YAML_FILE in "${CREATED_FILES[@]}"; do
        printf '  make apply FILE=%s\n  make watch NAME=%s\n' \
          "$YAML_FILE" "$(basename "$YAML_FILE" .yaml)"
      done
    } >> "$AUTORELEASE_PUSH_LOG"
  fi
  echo ""
  echo "3. Apply releases to cluster:"
  for YAML_FILE in "${CREATED_FILES[@]}"; do
    local YAML_NAME
    YAML_NAME=$(basename "$YAML_FILE" .yaml)
    echo "   make apply FILE=$YAML_FILE"
    echo "   make watch NAME=$YAML_NAME"
  done
  echo ""
  echo "To undo this commit:"
  echo "   git reset HEAD~1"
  echo ""
}

# ============================================================================
# Main Execution
# ============================================================================

main() {
  parse_arguments "$@"
  check_prerequisites

  # Tracker integration
  TRACKER_LIB="${TRACKER_LIB:-$SCRIPTS_DIR/lib/jira-tracker.sh}"
  # shellcheck source=lib/jira-tracker.sh
  [ -f "$TRACKER_LIB" ] && source "$TRACKER_LIB" 2>/dev/null || true
  TRACKER=$(find_release_tracker "$VERSION" 2>/dev/null || true)
  STEP_KEY=$( [ "$RELEASE_TYPE" = "prod" ] && echo "fbcProdReleases" || echo "fbcStageReleases" )
  [ -n "${TRACKER:-}" ] && update_step "$VERSION" "$STEP_KEY" "in_progress" '{}' "$TRACKER"

  # QE gate check for prod releases. get_step returns non-zero on a tracker
  # READ failure and empty output when the step is genuinely absent, so keep
  # the two apart — a Jira blip must not masquerade as "QE not signed off".
  # Either way we only generate/commit the YAML (a human still applies it in
  # Step 18), so this is an explicit advisory, not a hard stop.
  if [ "$RELEASE_TYPE" = "prod" ] && [ -n "${TRACKER:-}" ]; then
    local qe_data qe_rc=0
    qe_data=$(get_step "$VERSION" "qeValidation" "$TRACKER") || qe_rc=$?
    local qe_status=""
    [ "$qe_rc" -eq 0 ] && qe_status=$(printf '%s' "$qe_data" | jq -r '.status // empty' 2>/dev/null || true)

    if [ "$qe_rc" -ne 0 ]; then
      echo "⚠️  Could not read QE validation status (tracker read failed)." >&2
      echo "    Generating the prod release YAML anyway — confirm QE sign-off" >&2
      echo "    before applying it in Step 18." >&2
    elif [ "$qe_status" != "complete" ]; then
      echo "⚠️  QE validation is not marked complete in the tracker." >&2
      echo "    Generating the prod release YAML anyway — do NOT apply it (Step 18)" >&2
      echo "    until QE signs off, or mark the qeValidation subtask complete." >&2
    fi
  fi

  verify_release
  generate_yamls
  validate_yamls
  commit_changes

  # Record completion
  if [ -n "${TRACKER:-}" ]; then
    local ocp_count="${#CREATED_FILES[@]}"
    local data
    data=$(jq -n --arg count "$ocp_count" '{ocpVersionCount:($count|tonumber)}' | jq -c .) || data="{}"
    update_step "$VERSION" "$STEP_KEY" "complete" "$data" "$TRACKER"
  fi
}

main "$@"
