#!/bin/bash
# Shared library for release notes workflow
# Used by: collect.sh, prepare.sh, auto-apply.sh
set -euo pipefail

# ============================================================================
# UI Helpers
# ============================================================================

# Print section banner
banner() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "$1"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
}

# ============================================================================
# ACM Version Calculation
# ============================================================================
# Maps Submariner version to ACM version: 0.X → 2.(X-7).0
# Sets global variables: VERSION_MAJOR_MINOR, VERSION_MAJOR_MINOR_DASH, ACM_VERSION
# Requires: VERSION variable set by caller
calculate_acm_version() {
  # Extract version components (e.g., "0.23.1" → "0.23")
  VERSION_MAJOR_MINOR="${VERSION%.*}"
  # shellcheck disable=SC2034  # Used by caller after sourcing
  VERSION_MAJOR_MINOR_DASH="${VERSION_MAJOR_MINOR//./-}"

  # Submariner 0.X → ACM 2.(X-7)
  local MINOR_VERSION="${VERSION_MAJOR_MINOR##*.}"
  local ACM_MINOR=$((MINOR_VERSION - 7))

  if [[ $ACM_MINOR -lt 0 ]]; then
    echo "❌ ERROR: Cannot calculate ACM version for Submariner '$VERSION_MAJOR_MINOR'" >&2
    return 1
  fi

  # Always use base ACM version (not patch)
  # shellcheck disable=SC2034  # Used by caller after sourcing
  ACM_VERSION="ACM 2.${ACM_MINOR}.0"
}

# ============================================================================
# Component Name Mapping
# ============================================================================
# Maps Jira pscomponent label to Konflux component name
# Args: $1=pscomponent (e.g., rhacm2/submariner-operator-rhel9)
#       $2=version-dash (e.g., 0-22)
# Returns: component-name (e.g., submariner-operator-0-22)
#          "EXCLUDE" for submariner-addon (built separately)
#          "UNKNOWN" for unrecognized components
map_component_name() {
  local PSCOMPONENT="$1"
  local VERSION_DASH="$2"

  case "$PSCOMPONENT" in
    "rhacm2/lighthouse-coredns-rhel9"|"lighthouse-coredns-container")
      echo "lighthouse-coredns-${VERSION_DASH}"
      ;;
    "rhacm2/lighthouse-agent-rhel9"|"lighthouse-agent-container")
      echo "lighthouse-agent-${VERSION_DASH}"
      ;;
    "rhacm2/submariner-addon-rhel9")
      echo "EXCLUDE"  # Built separately in ACM/MCE - don't include
      ;;
    "rhacm2/submariner-rhel9-operator")
      # Alternative label format for operator (rhel9 in middle)
      echo "submariner-operator-${VERSION_DASH}"
      ;;
    "rhacm2/submariner-"*"-rhel9"|"submariner-"*"-container")
      # Extract component name (e.g., submariner-route-agent from rhacm2/submariner-route-agent-rhel9)
      # Remove rhacm2/ prefix and -rhel9/-container suffix
      local COMP
      COMP=$(sed -E 's/^(rhacm2\/)?(.+)-(rhel9|container)$/\2/' <<< "$PSCOMPONENT")
      echo "${COMP}-${VERSION_DASH}"
      ;;
    "nettest-container"|"rhacm2/nettest-rhel9")
      echo "nettest-${VERSION_DASH}"
      ;;
    "subctl-container"|"rhacm2/subctl-rhel9")
      echo "subctl-${VERSION_DASH}"
      ;;
    *)
      echo "UNKNOWN"
      ;;
  esac
}

# ============================================================================
# Stage YAML Discovery
# ============================================================================
# Finds latest stage YAML for given version
# Args: $1=version (e.g., 0.22.1)
#       $2=stage_yaml_override (optional path to specific YAML)
# Returns: Sets STAGE_YAML global variable
# Exits: 1 if YAML not found
find_stage_yaml() {
  local VERSION="$1"
  local STAGE_YAML_ARG="$2"

  # Extract version components (e.g., "0.23.1" → "0.23", "0-23-1")
  local VERSION_MAJOR_MINOR
  VERSION_MAJOR_MINOR="${VERSION%.*}"
  local VERSION_FULL_DASH="${VERSION//./-}"

  # Find git repository root
  # `|| true`: outside a git repo `git rev-parse` exits non-zero, which under
  # set -e would abort before the friendly "Not in a git repository" guard below.
  local GIT_ROOT
  GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || true
  if [[ -z "$GIT_ROOT" ]]; then
    echo "❌ ERROR: Not in a git repository" >&2
    return 1
  fi

  # Find or verify stage YAML
  if [[ -n "$STAGE_YAML_ARG" ]]; then
    STAGE_YAML="$STAGE_YAML_ARG"
    if [[ ! -f "$STAGE_YAML" ]]; then
      echo "❌ ERROR: Stage YAML not found: '$STAGE_YAML'" >&2
      return 1
    fi
  else
    # Find latest stage YAML for this version
    local STAGE_DIR="$GIT_ROOT/releases/$VERSION_MAJOR_MINOR/stage"

    if [[ ! -d "$STAGE_DIR" ]]; then
      echo "❌ ERROR: Stage directory not found: '$STAGE_DIR'" >&2
      echo "Possible causes:" >&2
      echo "  - Step 8 not complete (create-component-release not run)" >&2
      echo "Run: /create-component-release $VERSION" >&2
      return 1
    fi

    STAGE_YAML=$(find "$STAGE_DIR" -name "submariner-${VERSION_FULL_DASH}-stage-*.yaml" -type f | sort | tail -1)

    if [[ ! -f "$STAGE_YAML" ]]; then
      echo "❌ ERROR: No stage YAML found for version '$VERSION'" >&2
      echo "Expected: $STAGE_DIR/submariner-${VERSION_FULL_DASH}-stage-*.yaml" >&2
      echo "Run: /create-component-release $VERSION" >&2
      return 1
    fi
  fi
}

# ============================================================================
# Jira Query with Retry
# ============================================================================
# Wrapper for acli jira workitem search with retry logic
# Args: $@=all arguments passed to acli (typically --jql "...")
# Returns: JSON array from acli (stdout)
# Exits: 1 if both attempts fail
query_jira() {
  local OUTPUT

  for ATTEMPT in 1 2; do
    if OUTPUT=$(timeout "${ACLI_TIMEOUT:-30}" acli jira workitem search "$@" --paginate --json </dev/null); then
      echo "$OUTPUT"
      return 0
    fi

    if [[ "$ATTEMPT" -eq 1 ]]; then
      echo "⚠️  Jira query failed, retrying..." >&2
      sleep 2
    fi
  done

  echo "❌ ERROR: Jira query failed after 2 attempts" >&2
  return 1
}

# ============================================================================
# Jira Issue View with Retry
# ============================================================================
# Wrapper for acli jira workitem view with retry logic
# Args: $1=issue_key, $@=additional arguments (e.g., --fields "...")
# Returns: JSON object from acli (stdout)
# Exits: 1 if both attempts fail
view_jira() {
  local ISSUE_KEY="$1"
  shift
  local OUTPUT

  for ATTEMPT in 1 2; do
    if OUTPUT=$(timeout "${ACLI_TIMEOUT:-30}" acli jira workitem view "$ISSUE_KEY" "$@" --json </dev/null); then
      echo "$OUTPUT"
      return 0
    fi

    if [[ "$ATTEMPT" -eq 1 ]]; then
      echo "⚠️  Jira view failed for $ISSUE_KEY, retrying..." >&2
      sleep 2
    fi
  done

  echo "❌ ERROR: Jira view failed for '$ISSUE_KEY' after 2 attempts" >&2
  return 1
}

# ============================================================================
# Update Stage YAML Data Section
# ============================================================================
# Replaces or adds spec.data.releaseNotes section in stage YAML
# Args: $1=STAGE_YAML (path to YAML file)
#       $2=RELEASE_NOTES_YAML (new data section content)
# Exits: 1 if YAML is malformed (multiple data: sections)
# Side effects: Creates ${STAGE_YAML}.bak backup, modifies STAGE_YAML in place
update_stage_yaml_data_section() {
  local STAGE_YAML="$1"
  local RELEASE_NOTES_YAML="$2"

  echo "Updating stage YAML..."

  # Validate YAML doesn't have duplicate data: sections (malformed)
  local DATA_COUNT
  DATA_COUNT=$(grep -c "^  data:" "$STAGE_YAML" || true)
  if [[ "$DATA_COUNT" -gt 1 ]]; then
    echo "❌ ERROR: YAML has $DATA_COUNT 'data:' sections (expected 0 or 1)" >&2
    echo "File is malformed. Fix manually before applying release notes." >&2
    return 1
  fi

  # Backup original
  cp "$STAGE_YAML" "${STAGE_YAML}.bak"
  echo "✓ Backup created: ${STAGE_YAML}.bak"

  # Replace or add data: section in YAML
  local TMPFILE
  TMPFILE=$(mktemp)
  trap 'rm -f "$TMPFILE"' RETURN

  local DATA_LINE
  # `|| true`: no data: section is a valid input (the else branch appends one);
  # without it, pipefail + set -e would abort here before that branch is reached
  # (matches the guarded sibling greps at the DATA_COUNT and NEXT_KEY_LINE reads).
  DATA_LINE=$(grep -n -m1 '^  data:' "$STAGE_YAML" | cut -d: -f1 || true)

  if [[ -n "$DATA_LINE" ]]; then
    # YAML has existing data: section - replace it
    # Extract everything before "  data:" (excluding the data: line itself)
    sed -n '1,/^  data:/p' "$STAGE_YAML" | head -n -1 > "$TMPFILE"

    # Add new releaseNotes section
    echo "$RELEASE_NOTES_YAML" >> "$TMPFILE"

    # Find next key at same indentation (2 spaces - spec level)
    local NEXT_KEY_LINE
    NEXT_KEY_LINE=$(tail -n +"$((DATA_LINE + 1))" "$STAGE_YAML" | \
      grep -n -m1 '^  [a-zA-Z]' | cut -d: -f1 || true)

    if [[ -n "$NEXT_KEY_LINE" ]]; then
      # Append everything from next key onwards (preserves releasePlan, etc.)
      local ABS_LINE=$((DATA_LINE + NEXT_KEY_LINE))
      tail -n +"$ABS_LINE" "$STAGE_YAML" >> "$TMPFILE"
    fi
  else
    # YAML has no data: section - append new section at end
    cp "$STAGE_YAML" "$TMPFILE"
    echo "$RELEASE_NOTES_YAML" >> "$TMPFILE"
  fi

  # Replace original with updated
  mv "$TMPFILE" "$STAGE_YAML"
  echo "✓ Stage YAML updated"
}

# ============================================================================
# Validate Stage YAML
# ============================================================================
# Validates YAML syntax and release data format
# Args: $1=STAGE_YAML (path to YAML file)
# Exits: 1 if validation fails (also restores backup)
# Side effects: Restores ${STAGE_YAML}.bak on failure (commit removes it on success)
validate_stage_yaml() {
  local STAGE_YAML="$1"

  echo "Validating updated YAML..."

  # YAML syntax check
  if ! yq eval '.' "$STAGE_YAML" >/dev/null 2>&1; then
    echo "❌ ERROR: YAML syntax invalid" >&2
    echo "Restoring backup..." >&2
    mv "${STAGE_YAML}.bak" "$STAGE_YAML"
    return 1
  fi
  echo "✓ YAML syntax valid"

  # Find git root for make command
  # `|| true`: outside a git repo `git rev-parse` exits non-zero, which under
  # set -e would abort before the skip-validation warning below.
  local GIT_ROOT
  GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || true
  if [[ -z "$GIT_ROOT" ]]; then
    echo "⚠️  WARNING: Not in git repository - skipping validation" >&2
  else
    # Run file validation (yaml, fields, data - excludes gitlint/markdown)
    local VALIDATION_OUTPUT
    if ! VALIDATION_OUTPUT=$(cd "$GIT_ROOT" && make validate-file FILE="$STAGE_YAML" 2>&1); then
      echo "❌ ERROR: Validation command failed" >&2
      echo "$VALIDATION_OUTPUT" >&2
      echo "Restoring backup..." >&2
      mv "${STAGE_YAML}.bak" "$STAGE_YAML"
      return 1
    fi
    if echo "$VALIDATION_OUTPUT" | grep -q "ERROR"; then
      echo "❌ ERROR: Validation output contains errors" >&2
      echo "$VALIDATION_OUTPUT" >&2
      echo "Restoring backup..." >&2
      mv "${STAGE_YAML}.bak" "$STAGE_YAML"
      return 1
    fi
    echo "✓ Release data validation passed"
  fi
}

# ============================================================================
# Extract and Validate Metadata
# ============================================================================
# Extracts version and stage YAML path from data file and validates
# Args: $1=DATA_JSON (path to data JSON file)
# Sets: STAGE_YAML, VERSION (global variables)
# Exits: 1 if stage YAML file not found
extract_and_validate_metadata() {
  local DATA_JSON="$1"

  # Extract metadata and stage YAML path
  read -r STAGE_YAML VERSION < <(jq -r '.metadata | "\(.stage_yaml) \(.version)"' "$DATA_JSON")

  echo "Version: $VERSION"
  echo "Stage YAML: $STAGE_YAML"

  if [[ ! -f "$STAGE_YAML" ]]; then
    echo "❌ ERROR: Stage YAML not found: '$STAGE_YAML'" >&2
    return 1
  fi
}

# ============================================================================
# Format Issues YAML
# ============================================================================
# Formats issue keys into YAML array entries
# Args: $@ = space-separated issue keys (e.g., "ACM-123 ACM-456")
# Output: YAML-formatted issue entries to stdout
format_issues() {
  printf '          - id: %s\n            source: issues.redhat.com\n' "$@"
}

# ============================================================================
# Build Issues Fixed YAML
# ============================================================================
# Builds issues.fixed[] YAML section with CVE and non-CVE sections
# Args: $1=CVE_COUNT (number of CVE issues)
#       $2=CVE_ISSUE_KEYS (space-separated CVE issue keys)
#       $3=NON_CVE_COUNT (number of non-CVE issues)
#       $4=NON_CVE_ISSUE_KEYS (space-separated non-CVE issue keys)
# Output: Formatted issues.fixed YAML content to stdout
build_issues_fixed_yaml() {
  local CVE_COUNT="$1"
  local CVE_ISSUE_KEYS="$2"
  local NON_CVE_COUNT="$3"
  local NON_CVE_ISSUE_KEYS="$4"

  if [[ "$CVE_COUNT" -gt 0 ]]; then
    printf '          # CVE Issues (%s):\n' "$CVE_COUNT"
    # shellcheck disable=SC2086  # Intentional word splitting: pass each issue key as separate arg
    format_issues $CVE_ISSUE_KEYS
  fi

  if [[ "$NON_CVE_COUNT" -gt 0 ]]; then
    printf '          # Non-CVE Issues (%s):\n' "$NON_CVE_COUNT"
    # shellcheck disable=SC2086  # Intentional word splitting: pass each issue key as separate arg
    format_issues $NON_CVE_ISSUE_KEYS
  fi
}

# ============================================================================
# Build Complete Release Notes YAML
# ============================================================================
# Assembles complete releaseNotes YAML section
# Args: $1=RELEASE_TYPE (e.g., "RHSA", "RHBA")
#       $2=ISSUES_FIXED_YAML (formatted issues YAML content)
#       $3=CVES_YAML (formatted CVEs YAML content, empty string if none)
# Output: Complete releaseNotes YAML to stdout
build_release_notes_yaml() {
  local RELEASE_TYPE="$1"
  local ISSUES_FIXED_YAML="$2"
  local CVES_YAML="$3"
  local YAML

  YAML="  data:
    releaseNotes:
      type: $RELEASE_TYPE
      issues:
        fixed:
$ISSUES_FIXED_YAML"

  if [[ -n "$CVES_YAML" ]]; then
    YAML+="
      cves:
$CVES_YAML"
  fi

  echo "$YAML"
}

# ============================================================================
# Display Release Notes Summary
# ============================================================================
# Displays summary of built release notes
# Args: $1=RELEASE_TYPE (e.g., "RHSA", "RHBA")
#       $2=CVE_COUNT (number of CVE issues)
#       $3=NON_CVE_COUNT (number of non-CVE issues)
display_release_notes_summary() {
  local RELEASE_TYPE="$1"
  local CVE_COUNT="$2"
  local NON_CVE_COUNT="$3"

  echo "✓ releaseNotes section built"
  echo "  Type: $RELEASE_TYPE"
  echo "  CVE issues: $CVE_COUNT"
  echo "  Non-CVE issues: $NON_CVE_COUNT"
}

# ============================================================================
# Commit Release Notes
# ============================================================================
# Commits stage YAML with release notes and displays success message
# Args: $1=STAGE_YAML (path to YAML file)
#       $2=COMMIT_MSG (commit message)
#       $3=SUCCESS_MSG (success message, e.g., "applied" or "auto-applied")
# Side effects: Commits file, removes backup, displays success banner
commit_release_notes() {
  local STAGE_YAML="$1"
  local COMMIT_MSG="$2"
  local SUCCESS_MSG="$3"

  # Stage file
  git add "$STAGE_YAML"

  # Remove backup
  rm -f "${STAGE_YAML}.bak"

  # Check if there are any changes to commit
  if git diff --cached --quiet; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Release notes already up-to-date - no changes needed!"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    return 0
  fi

  echo "Commit message:"
  echo "$COMMIT_MSG"

  # Commit
  git commit -s -m "$COMMIT_MSG"

  echo "✓ Changes committed"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Release notes $SUCCESS_MSG successfully!"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}
