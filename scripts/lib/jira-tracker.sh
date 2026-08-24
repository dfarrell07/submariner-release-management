#!/bin/bash
# Shared library for Jira release tracker operations
# Used by: create-release-tracker.sh, release-status.sh, and release workflow scripts
#
# Provides structured Jira-based tracking for Submariner releases.
# Each release gets a parent Task with 15-18 Sub-task children (one per workflow step).
# Automation appends structured STEP_DATA comments as steps complete.
#
# Best-effort: tracker failures never crash calling scripts. Side-effect
# functions (update_step, etc.) return 0 on error. create_release_tracker is
# strict since it's a deliberate action. get_step is a reader: it returns
# non-zero on a failed/unreliable read so evidence recorders can tell a Jira
# blip apart from a genuinely absent step (empty output, exit 0).

# shellcheck disable=SC2034  # All STEP_* arrays are read by callers (autorelease.sh, release-status.sh, etc.)

# Include guard — prevent crash from re-sourcing readonly variables
if [ "${_JIRA_TRACKER_SOURCED:-}" = "true" ]; then
  return 0 2>/dev/null || true
fi
_JIRA_TRACKER_SOURCED=true

# Source shared Jira helpers (query_jira, view_jira, calculate_acm_version)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=release-notes-common.sh
source "$SCRIPT_DIR/release-notes-common.sh" 2>/dev/null || true
# shellcheck source=fbc-scope.sh
source "$SCRIPT_DIR/fbc-scope.sh"

# ============================================================================
# Constants
# ============================================================================

# Canonical FBC repo path — shared by autorelease.sh, fbc-catalog-update.sh,
# and tekton-task-refs-update.sh so the path is defined once. Override via the
# FBC_REPO_DEFAULT env var (e.g. in tests or when the repo lives elsewhere).
readonly FBC_REPO_DEFAULT="${FBC_REPO_DEFAULT:-$HOME/konflux/submariner-operator-fbc}"

# Maximum seconds any single acli network call is allowed to run before being
# killed. A silent TCP drop would otherwise cause an indefinite hang on any
# acli invocation. Override via ACLI_TIMEOUT env var (e.g. ACLI_TIMEOUT=60
# on slow networks). timeout exits 124 on expiry; the || return $? / || { … }
# guards already present at every call site propagate that code to callers.
readonly ACLI_TIMEOUT="${ACLI_TIMEOUT:-30}"

# Thin wrapper that applies ACLI_TIMEOUT to every acli network call.
# Uses GNU timeout(1) when acli resolves to an external binary (production),
# and falls back to a direct call when acli is a shell function (test mocks) —
# timeout(1) uses exec and cannot invoke shell functions, so the direct path
# keeps all existing test mocks working without modification.
_acli() {
  if [[ "$(type -t acli 2>/dev/null)" == "function" ]]; then
    acli "$@"
  else
    timeout "${ACLI_TIMEOUT}" acli "$@"
  fi
}

# ============================================================================
# Step Metadata (per-step co-located layout)
# ============================================================================
# Arrays declared here; entries grouped by step below for readability — a reader
# can find all metadata for any step in one block.
#
# Arrays read by callers (autorelease, release-ls, etc.) — SC2034 suppressed file-wide above.
# Note: STEP_VERIFIER is NOT here — it is defined in autorelease.sh alongside each function body.
declare -A STEP_TITLES
declare -A STEP_PHASE
declare -A STALENESS_RULES
declare -A STEP_DEPENDENCIES
declare -A AUTOMATION_LEVEL
declare -A STEP_SCRIPT
declare -A STEP_SKILL_HINT
declare -A STEP_EXTRA_ARGS
# Git-output classifiers: steps that create release CRs (apply/watch) or push
# directly to main (no PR). Used by autorelease.sh classify_log_growth and run_dry_run.
declare -A RELEASE_YAML_STEPS
declare -A DIRECT_PUSH_STEPS

# === Branch Setup steps ===

# ── createBranches ──────────────────────────────────────────────────────────
STEP_TITLES["createBranches"]="Create upstream release branches"
STEP_PHASE["createBranches"]="Branch Setup"
STEP_DEPENDENCIES["createBranches"]=""
AUTOMATION_LEVEL["createBranches"]="review"
STEP_SKILL_HINT["createBranches"]="See .agents/workflows/create-release-branch.md"

# ── configureDownstream ─────────────────────────────────────────────────────
STEP_TITLES["configureDownstream"]="Configure Konflux downstream"
STEP_PHASE["configureDownstream"]="Branch Setup"
STEP_DEPENDENCIES["configureDownstream"]="createBranches"
AUTOMATION_LEVEL["configureDownstream"]="auto"
STEP_SCRIPT["configureDownstream"]="scripts/configure-downstream.sh"

# ── tektonComponents ────────────────────────────────────────────────────────
STEP_TITLES["tektonComponents"]="Tekton component setup"
STEP_PHASE["tektonComponents"]="Branch Setup"
STEP_DEPENDENCIES["tektonComponents"]="configureDownstream"
AUTOMATION_LEVEL["tektonComponents"]="auto"
STEP_SCRIPT["tektonComponents"]="scripts/tekton-component-setup.sh"

# ── tektonBundle ────────────────────────────────────────────────────────────
STEP_TITLES["tektonBundle"]="Tekton bundle setup"
STEP_PHASE["tektonBundle"]="Branch Setup"
STEP_DEPENDENCIES["tektonBundle"]="configureDownstream"
AUTOMATION_LEVEL["tektonBundle"]="auto"
STEP_SCRIPT["tektonBundle"]="scripts/konflux-bundle-setup.sh"

# === Build Readiness steps ===

# ── cveFixes ────────────────────────────────────────────────────────────────
STEP_TITLES["cveFixes"]="CVE fixes"
STEP_PHASE["cveFixes"]="Build Readiness"
STEP_DEPENDENCIES["cveFixes"]=""
STALENESS_RULES["cveFixes"]="3d"
AUTOMATION_LEVEL["cveFixes"]="review"
STEP_SCRIPT["cveFixes"]="scripts/cve-fixes-update.sh"

# ── ecFixes ─────────────────────────────────────────────────────────────────
STEP_TITLES["ecFixes"]="EC compliance fixes"
STEP_PHASE["ecFixes"]="Build Readiness"
STEP_DEPENDENCIES["ecFixes"]=""
STALENESS_RULES["ecFixes"]="snapshot"
AUTOMATION_LEVEL["ecFixes"]="auto"
STEP_SKILL_HINT["ecFixes"]="/konflux-ci-fix (EC passes only after Build Readiness PRs merge and Konflux rebuilds — snapshots from in-flight builds will not pass)"

# ── rpmLockfiles ────────────────────────────────────────────────────────────
STEP_TITLES["rpmLockfiles"]="RPM lockfile updates"
STEP_PHASE["rpmLockfiles"]="Build Readiness"
STEP_DEPENDENCIES["rpmLockfiles"]=""
STALENESS_RULES["rpmLockfiles"]="3d"
AUTOMATION_LEVEL["rpmLockfiles"]="auto"
STEP_SCRIPT["rpmLockfiles"]="scripts/rpm-lockfile-update.sh"

# ── tektonTasks ─────────────────────────────────────────────────────────────
STEP_TITLES["tektonTasks"]="Tekton task updates"
STEP_PHASE["tektonTasks"]="Build Readiness"
STEP_DEPENDENCIES["tektonTasks"]=""
AUTOMATION_LEVEL["tektonTasks"]="auto"
STEP_SCRIPT["tektonTasks"]="scripts/tekton-task-refs-update.sh"

# ── versionLabels ───────────────────────────────────────────────────────────
STEP_TITLES["versionLabels"]="Version label updates"
STEP_PHASE["versionLabels"]="Build Readiness"
STEP_DEPENDENCIES["versionLabels"]=""
AUTOMATION_LEVEL["versionLabels"]="auto"
STEP_SCRIPT["versionLabels"]="scripts/update-version-labels.sh"

# ── upstreamRelease ─────────────────────────────────────────────────────────
STEP_TITLES["upstreamRelease"]="Cut upstream release"
STEP_PHASE["upstreamRelease"]="Build Readiness"
STEP_DEPENDENCIES["upstreamRelease"]="cveFixes,ecFixes,rpmLockfiles,tektonTasks,versionLabels,tektonComponents,tektonBundle"
AUTOMATION_LEVEL["upstreamRelease"]="gate"
STEP_SKILL_HINT["upstreamRelease"]="See .agents/workflows/cut-upstream-release.md"

# ── bundleShas ──────────────────────────────────────────────────────────────
STEP_TITLES["bundleShas"]="Update bundle SHAs"
STEP_PHASE["bundleShas"]="Build Readiness"
STEP_DEPENDENCIES["bundleShas"]="upstreamRelease"
STALENESS_RULES["bundleShas"]="snapshot"
# review (not auto): breaks the bundleShas → componentStage auto-chain so the
# human pushes/merges the SHA-bump PR and waits for the Konflux bundle rebuild
# before componentStage runs. Complementary to create-component-release.sh's
# in-script bundle-freshness gate (see "Chain hazards" in the plan).
AUTOMATION_LEVEL["bundleShas"]="review"
STEP_SCRIPT["bundleShas"]="scripts/bundle-image-update.sh"
DIRECT_PUSH_STEPS["bundleShas"]=1

# === Stage Release steps ===

# ── componentStage ──────────────────────────────────────────────────────────
STEP_TITLES["componentStage"]="Component stage release"
STEP_PHASE["componentStage"]="Stage Release"
STEP_DEPENDENCIES["componentStage"]="bundleShas"
# componentStage records the snapshot it released; if bundleShas later records
# a newer snapshot, componentStage is stale — the stage YAML references the old
# snapshot. release-ls surfaces this; operator runs --refresh componentStage.
STALENESS_RULES["componentStage"]="snapshot"
# review (not auto): stops the conductor after create-component-release.sh runs
# so the operator applies/watches the stage release pipeline before advancing to
# releaseNotes and fbcCatalogUpdate. Without this stop, a silent apply failure
# leaves those downstream steps completed against an unapplied stage release.
AUTOMATION_LEVEL["componentStage"]="review"
STEP_SCRIPT["componentStage"]="scripts/create-component-release.sh"
STEP_EXTRA_ARGS["componentStage"]="stage"
RELEASE_YAML_STEPS["componentStage"]=1

# ── releaseNotes ────────────────────────────────────────────────────────────
STEP_TITLES["releaseNotes"]="Release notes"
STEP_PHASE["releaseNotes"]="Stage Release"
STEP_DEPENDENCIES["releaseNotes"]="componentStage"
AUTOMATION_LEVEL["releaseNotes"]="review"
STEP_SCRIPT["releaseNotes"]="scripts/add-release-notes.sh"

# ── fbcCatalogUpdate ────────────────────────────────────────────────────────
STEP_TITLES["fbcCatalogUpdate"]="FBC catalog update"
STEP_PHASE["fbcCatalogUpdate"]="Stage Release"
STEP_DEPENDENCIES["fbcCatalogUpdate"]="componentStage"
STALENESS_RULES["fbcCatalogUpdate"]="snapshot"
AUTOMATION_LEVEL["fbcCatalogUpdate"]="review"
STEP_SCRIPT["fbcCatalogUpdate"]="scripts/fbc-catalog-update.sh"
DIRECT_PUSH_STEPS["fbcCatalogUpdate"]=1

# ── fbcStageReleases ────────────────────────────────────────────────────────
STEP_TITLES["fbcStageReleases"]="FBC stage releases"
STEP_PHASE["fbcStageReleases"]="Stage Release"
STEP_DEPENDENCIES["fbcStageReleases"]="fbcCatalogUpdate"
AUTOMATION_LEVEL["fbcStageReleases"]="review"
STEP_SCRIPT["fbcStageReleases"]="scripts/create-fbc-releases.sh"
STEP_EXTRA_ARGS["fbcStageReleases"]="stage"
RELEASE_YAML_STEPS["fbcStageReleases"]=1

# === QE Validation ===

# ── qeValidation ────────────────────────────────────────────────────────────
STEP_TITLES["qeValidation"]="QE testing"
STEP_PHASE["qeValidation"]="QE Validation"
STEP_DEPENDENCIES["qeValidation"]="fbcStageReleases"
STALENESS_RULES["qeValidation"]="snapshot"
AUTOMATION_LEVEL["qeValidation"]="gate"
STEP_SKILL_HINT["qeValidation"]="Share URLs with /get-fbc-urls, then await QE approval"

# === Production Release steps ===

# ── componentProd ───────────────────────────────────────────────────────────
STEP_TITLES["componentProd"]="Component prod release"
STEP_PHASE["componentProd"]="Production Release"
STEP_DEPENDENCIES["componentProd"]="qeValidation,componentStage,releaseNotes"
AUTOMATION_LEVEL["componentProd"]="review"
STEP_SCRIPT["componentProd"]="scripts/create-component-release.sh"
STEP_EXTRA_ARGS["componentProd"]="prod"
RELEASE_YAML_STEPS["componentProd"]=1

# ── fbcProdReleases ─────────────────────────────────────────────────────────
STEP_TITLES["fbcProdReleases"]="FBC prod releases"
STEP_PHASE["fbcProdReleases"]="Production Release"
STEP_DEPENDENCIES["fbcProdReleases"]="componentProd"
AUTOMATION_LEVEL["fbcProdReleases"]="review"
STEP_SCRIPT["fbcProdReleases"]="scripts/create-fbc-releases.sh"
STEP_EXTRA_ARGS["fbcProdReleases"]="prod"
RELEASE_YAML_STEPS["fbcProdReleases"]=1

# ── fbcProdUrls ─────────────────────────────────────────────────────────────
STEP_TITLES["fbcProdUrls"]="FBC prod URL conversion"
STEP_PHASE["fbcProdUrls"]="Production Release"
STEP_DEPENDENCIES["fbcProdUrls"]="fbcProdReleases"
# No staleness rule for fbcProdUrls: the quay.io→registry.redhat.io conversion
# is a one-time permanent action. Once it marks the step complete, a time-based
# rule would spuriously re-flag it as stale forever.
AUTOMATION_LEVEL["fbcProdUrls"]="auto"
STEP_SKILL_HINT["fbcProdUrls"]="See .agents/workflows/update-fbc-templates-prod.md"

# === Ordering and stream membership ===

# Step display order (workflow sequence)
readonly STEP_ORDER=(
  "createBranches" "configureDownstream" "tektonComponents" "tektonBundle"
  "rpmLockfiles" "versionLabels" "tektonTasks" "cveFixes" "ecFixes"
  "upstreamRelease" "bundleShas"
  "componentStage" "releaseNotes" "fbcCatalogUpdate" "fbcStageReleases"
  "qeValidation"
  "componentProd" "fbcProdReleases" "fbcProdUrls"
)

# Y-stream only steps (omitted for Z-stream)
readonly YSTREAM_STEPS=("createBranches" "configureDownstream" "tektonComponents" "tektonBundle")

# Z-stream only steps (omitted for Y-stream)
readonly ZSTREAM_STEPS=("versionLabels")

# Jira status names (overridable via env for project-specific names)
readonly JIRA_STATUS_IN_PROGRESS="${JIRA_STATUS_IN_PROGRESS:-In Progress}"
readonly JIRA_STATUS_RESOLVED="${JIRA_STATUS_RESOLVED:-Resolved}"

# ============================================================================
# Internal Helpers
# ============================================================================

# Check if a step applies to the given release type
# Args: $1=step_key $2=release_type (y-stream|z-stream)
# Returns: 0 if applicable, 1 if not
step_applies_to_release() {
  local step_key="$1"
  local release_type="$2"
  if [ "$release_type" = "z-stream" ]; then
    for ys in "${YSTREAM_STEPS[@]}"; do
      [ "$step_key" = "$ys" ] && return 1
    done
  elif [ "$release_type" = "y-stream" ]; then
    for zs in "${ZSTREAM_STEPS[@]}"; do
      [ "$step_key" = "$zs" ] && return 1
    done
  fi
  return 0
}

# Normalize version: expand 2-segment (0.24) to 3-segment (0.24.0)
# Args: $1=version
# Output: normalized version
_normalize_version() {
  local v="$1"
  [[ "$v" =~ ^[0-9]+\.[0-9]+$ ]] && v="${v}.0"
  echo "$v"
}

# Validate version format (must be X.Y.Z with 3 segments)
# Args: $1=version
# Returns: 0 if valid, 1 if invalid
_validate_version() {
  local version="$1"
  if ! echo "$version" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "❌ ERROR: Version must be X.Y.Z format (e.g., 0.24.0), got '$version'" >&2
    echo "   Two-segment versions (e.g., 0.24) would create label collisions across patches" >&2
    return 1
  fi
}

# Convert version to Jira label (dots → dashes)
# Args: $1=version (e.g., 0.24.0)
# Output: label (e.g., release-0-24-0)
_version_to_label() {
  echo "release-$(echo "$1" | tr '.' '-')"
}

# Detect release type from version
# Args: $1=version (X.Y.Z)
# Output: "y-stream" or "z-stream"
_detect_release_type() {
  local patch="${1##*.}"
  if [ "$patch" = "0" ]; then
    echo "y-stream"
  else
    echo "z-stream"
  fi
}

# Find a subtask by parent key and step key
# Args: $1=parent_key (e.g., ACM-54321)
#       $2=step_key (e.g., cveFixes)
# Output: subtask issue key or empty
_find_subtask() {
  local parent_key="$1"
  local step_key="$2"
  local title="${STEP_TITLES[$step_key]:-}"

  if [ -z "$title" ]; then
    echo "⚠️  Unknown step key: $step_key" >&2
    return 1
  fi

  local result
  result=$(query_jira --jql "parent = $parent_key AND summary = \"$title\"" --fields "key" 2>/dev/null) || return 1

  echo "$result" | jq -r '.[0].key // empty' 2>/dev/null
}

# Transition a Jira issue to a new status
# Args: $1=issue_key $2=target_status
_transition_issue() {
  local key="$1"
  local status="$2"

  # Try the transition directly — Jira auto-sets resolution for most workflows
  _acli jira workitem transition --key "$key" --status "$status" --yes </dev/null 2>/dev/null
}

# Write a structured comment on a Jira issue
# Args: $1=issue_key $2=comment_body (markdown string)
_add_comment() {
  local key="$1"
  local body="$2"

  local body_file
  body_file=$(mktemp)
  printf '%s\n' "$body" > "$body_file"

  local result=0
  _acli jira workitem comment create --key "$key" --body-file "$body_file" </dev/null 2>/dev/null || result=$?

  rm -f "$body_file"
  return "$result"
}

# Generate parent task description markdown
# Args: $1=version $2=release_type $3=acm_version
_generate_parent_description() {
  local version="$1"
  local release_type="$2"
  local acm_version="$3"
  local major_minor="${version%.*}"

  local type_label
  if [ "$release_type" = "y-stream" ]; then
    type_label="Y-stream (new minor version)"
  else
    type_label="Z-stream (patch release)"
  fi

  cat <<DESC
## Release Info

- **Version:** $version
- **Type:** $type_label
- **ACM Version:** $acm_version
- **Release Branch:** release-$major_minor
- **Release Engineer:** $(git config user.name 2>/dev/null || echo "TBD")

## Key Artifacts

Updated by automation as the release progresses.

- **Snapshot:** _(pending)_
- **Stage Release:** _(pending)_
- **Prod Release:** _(pending)_
- **FBC Catalog URLs:** _(pending)_
- **Advisory:** _(pending)_

## Tracking

This issue tracks the Submariner $version release workflow.
Subtasks represent individual steps. Structured comments record
step completion data for automation.
DESC
}

# Generate subtask description based on step type
# Args: $1=step_key $2=version
_generate_subtask_description() {
  local step_key="$1"
  local version="$2"
  local major_minor="${version%.*}"
  # FBC_OCP_VERSIONS is set by fbc-scope.sh, sourced at the top of this file.
  local _ocp="${FBC_OCP_VERSIONS:?FBC_OCP_VERSIONS must be set (source fbc-scope.sh first)}"
  local _first _last
  read -r _first _ <<< "$_ocp"
  _last=$(echo "$_ocp" | awk '{print $NF}')
  local _ocp_range="4.$_first through 4.$_last"

  case "$step_key" in
    cveFixes|ecFixes|rpmLockfiles|tektonTasks|versionLabels)
      cat <<DESC
## PRs

_(populated by automation when PRs are created)_

## Status

Waiting for skill to create PRs across repos on release-$major_minor branch.
DESC
      ;;
    createBranches)
      cat <<DESC
## Status

Create release-$major_minor branches across all upstream repos.

- **Repo:** submariner-io/releases
- **Branch:** release-$major_minor
DESC
      ;;
    configureDownstream)
      cat <<DESC
## Status

Configure Konflux for Submariner $version.

- **Repo:** konflux-release-data
- **Output:** Overlays, tenant config, RPAs for $major_minor
DESC
      ;;
    tektonComponents|tektonBundle)
      cat <<DESC
## Status

Setup Tekton pipelines on release-$major_minor branch.
DESC
      ;;
    upstreamRelease)
      cat <<DESC
## Release

- **Version:** v$version
- **Branch:** release-$major_minor
- **PR:** _(pending)_
- **Status:** _(pending)_

## Decision

_(record the decision to cut the release here)_
DESC
      ;;
    bundleShas)
      cat <<DESC
## Status

- **Snapshot:** _(pending)_
- **PR:** _(pending)_
- **Verification:** _(pending)_
DESC
      ;;
    componentStage|componentProd)
      cat <<DESC
## Release

- **Release Name:** _(pending)_
- **Snapshot:** _(pending)_
- **Attempt:** 1
- **Status:** _(pending)_

## Notes

_(automation will update with release pipeline results)_
DESC
      ;;
    releaseNotes)
      cat <<DESC
## Advisory

- **Type:** _(RHSA or RHBA, pending)_
- **Total issues:** _(pending)_
- **Review PR:** _(pending)_
DESC
      ;;
    fbcCatalogUpdate)
      cat <<DESC
## Status

Update FBC catalogs with bundle from stage release.
Pushes directly to FBC repo main (no PR); wait ~15-30 min for FBC rebuild.

- **FBC Repo push:** _(pending)_
- **OCP Versions:** $_ocp_range
DESC
      ;;
    fbcStageReleases|fbcProdReleases)
      cat <<DESC
## Releases

One release per OCP version ($_ocp_range).

_(automation will populate with per-OCP-version release status)_
DESC
      ;;
    qeValidation)
      cat <<DESC
## Stage Catalog URLs

_(populated by automation when stage releases complete)_

## Platform Testing Status

- **AWS:** _(pending)_
- **vSphere:** _(pending)_
- **ROSA:** _(pending)_
- **Azure:** _(pending)_
- **ARO:** _(pending)_
- **GCP:** _(pending)_
- **IBM Power (ppc64le):** _(pending)_
- **IBM Z (s390x):** _(pending)_

## Go/No-Go Decision

- **Decision:** _(pending)_
- **Approved by:** _(pending)_
- **Date:** _(pending)_
- **Known issues:** _(pending)_
- **Conditions:** _(pending)_
- **OCP versions tested:** _(pending)_

Assign this subtask to the QE engineer. Catalog URLs are
populated by automation when stage releases complete.
DESC
      ;;
    fbcProdUrls)
      cat <<DESC
## Status

Convert temporary quay.io bundle URLs to permanent registry.redhat.io
URLs in the FBC template.

- **Deadline:** ~90 days after prod release (quay.io URLs expire)
- **FBC Repo PR:** _(pending)_

Usually handled automatically during the next release's FBC catalog
update. Manual conversion needed if no next release within 90 days.
DESC
      ;;
    *)
      echo "_(no description template for $step_key)_"
      ;;
  esac
}

# ============================================================================
# Public API
# ============================================================================

# Find the Jira tracker task for a release version
# Args: $1=version (X.Y.Z)
# Output: Issue key (e.g., ACM-54321) or empty
# Returns: 0 with a key or empty stdout (found / genuinely absent / invalid
#            version); 2 when the Jira query itself failed (auth/network) so
#            callers can distinguish "no tracker exists" from "couldn't look".
#          Bare `$(find_release_tracker ...)` sites append `|| true` to keep
#            their empty-stdout handling and avoid a set -e abort on the 2.
find_release_tracker() {
  local version="$1"
  version=$(_normalize_version "$version")

  _validate_version "$version" || return 0

  local version_label
  version_label=$(_version_to_label "$version")

  local result
  result=$(query_jira --jql "project = ACM AND labels = release-tracking AND labels = $version_label AND issuetype = Task" --fields "key,summary" 2>/dev/null) || {
    echo "⚠️  Could not query Jira for release tracker" >&2
    return 2
  }

  # An exit-0 response can still be garbled (truncated --paginate, an error
  # object, a bare null, or empty). Without this guard jq would yield empty,
  # which create_release_tracker reads as "tracker absent" and would then create
  # a DUPLICATE. Require a JSON array (mirrors get_step's validation) and signal
  # the unreliable-read case as rc 2 so the caller refuses instead.
  if ! printf '%s' "$result" | jq -e 'type=="array"' >/dev/null 2>&1; then
    echo "⚠️  Unreliable Jira response checking for release tracker" >&2
    return 2
  fi

  echo "$result" | jq -r '.[0].key // empty' 2>/dev/null || true
}

# Create a new release tracker with all subtasks
# Args: $1=version (X.Y.Z)
#       $2=release_type (y-stream|z-stream) [optional, auto-detected]
#       $3=qe_assignee (email) [optional]
# Output: Parent issue key
# Returns: 0 on success, 1 on failure
create_release_tracker() {
  local version="$1"
  version=$(_normalize_version "$version")
  local release_type="${2:-}"
  local qe_assignee="${3:-}"

  _validate_version "$version" || return 1

  # Auto-detect release type if not specified
  if [ -z "$release_type" ]; then
    release_type=$(_detect_release_type "$version")
  fi

  local version_label
  version_label=$(_version_to_label "$version")

  # Idempotency: check for existing tracker. Distinguish "not found" (rc 0,
  # empty output) from "couldn't check" (rc 2, the Jira query itself failed).
  # Swallowing rc 2 here would let a failed check fall through to creating a
  # second tracker when one may already exist — refuse instead. This runs in
  # dry-run too (read-only), so a preview correctly reports an existing tracker.
  local existing find_rc=0
  existing=$(find_release_tracker "$version") || find_rc=$?
  if [ "$find_rc" -eq 2 ]; then
    echo "❌ ERROR: Could not query Jira to check for an existing tracker" >&2
    echo "   Refusing to create — a duplicate tracker may result." >&2
    echo "   Check Jira auth/network, then retry." >&2
    return 1
  fi
  if [ -n "$existing" ]; then
    echo "⚠️  Tracker already exists: $existing" >&2
    echo "$existing"
    return 0
  fi

  # Jira search indexes can be stale for ~30s after a write. Retry once after a
  # short wait — a stale-empty response looks identical to "no tracker exists",
  # and creating a second tracker on a stale read duplicates work and confuses
  # the conductor (which reads whichever duplicate Jira returns first).
  echo "ℹ️  No existing tracker found. Waiting for Jira index to settle..." >&2
  sleep "${_JIRA_STALE_RETRY_DELAY:-15}"
  find_rc=0
  existing=$(find_release_tracker "$version") || find_rc=$?
  if [ "$find_rc" -eq 2 ]; then
    echo "❌ ERROR: Could not query Jira to check for an existing tracker (retry)" >&2
    echo "   Refusing to create — a duplicate tracker may result." >&2
    echo "   Check Jira auth/network, then retry." >&2
    return 1
  fi
  if [ -n "$existing" ]; then
    echo "⚠️  Tracker found on retry (index was stale): $existing" >&2
    echo "$existing"
    return 0
  fi
  echo "ℹ️  Confirmed: no existing tracker after retry — proceeding to create." >&2

  # Calculate ACM version (sets ACM_VERSION global)
  VERSION="$version" calculate_acm_version || {
    echo "❌ ERROR: Failed to calculate ACM version for $version" >&2
    return 1
  }

  echo "Creating release tracker for Submariner $version ($release_type)..." >&2

  # --- Create parent task ---

  local desc_file
  desc_file=$(mktemp)
  _generate_parent_description "$version" "$release_type" "$ACM_VERSION" > "$desc_file"

  local parent_output parent_key
  if [ "${JIRA_TRACKER_DRY_RUN:-}" = "true" ]; then
    echo "[DRY RUN] Would create: Task 'Release Submariner $version'" >&2
    parent_key="ACM-DRY-RUN"
  else
    parent_output=$(_acli jira workitem create \
      --project ACM \
      --type Task \
      --summary "Release Submariner $version" \
      --label "release-tracking,submariner,$version_label" \
      --assignee "@me" \
      --description-file "$desc_file" \
      --json </dev/null) || {
      echo "❌ ERROR: Failed to create parent task" >&2
      rm -f "$desc_file"
      return 1
    }
    parent_key=$(echo "$parent_output" | jq -r '.key // empty' 2>/dev/null) || parent_key=""
  fi

  rm -f "$desc_file"

  if [ -z "$parent_key" ]; then
    echo "❌ ERROR: Could not extract parent key from create response" >&2
    return 1
  fi

  echo "✓ Parent task created: $parent_key" >&2

  # Fix Version ($ACM_VERSION) must be set manually or via MCP — acli edit
  # doesn't support fixVersions (--key and --from-json are mutually exclusive,
  # and --from-json schema lacks fixVersions). The description includes the
  # ACM version for reference.

  # --- Create subtasks ---

  local subtask_count=0
  local failed_count=0

  for step_key in "${STEP_ORDER[@]}"; do
    step_applies_to_release "$step_key" "$release_type" || continue

    local title="${STEP_TITLES[$step_key]:-$step_key}"

    local sub_desc_file
    sub_desc_file=$(mktemp)
    _generate_subtask_description "$step_key" "$version" > "$sub_desc_file"

    # Build create command args
    local -a create_args=(
      --project ACM
      --type Sub-task
      --parent "$parent_key"
      --summary "$title"
      --label "release-tracking,$version_label"
      --description-file "$sub_desc_file"
      --json
    )

    # Assign subtasks: QE to specified engineer (or unassigned), all others to release engineer
    if [ "$step_key" = "qeValidation" ]; then
      [ -n "$qe_assignee" ] && create_args+=(--assignee "$qe_assignee")
    else
      create_args+=(--assignee "@me")
    fi

    if [ "${JIRA_TRACKER_DRY_RUN:-}" = "true" ]; then
      echo "[DRY RUN] Would create: Sub-task '$title' under $parent_key" >&2
      subtask_count=$((subtask_count + 1))
    else
      local sub_output
      if sub_output=$(_acli jira workitem create "${create_args[@]}" </dev/null 2>/dev/null); then
        local sub_key
        sub_key=$(echo "$sub_output" | jq -r '.key // empty' 2>/dev/null) || sub_key=""
        echo "  ✓ $title ($sub_key)" >&2
        subtask_count=$((subtask_count + 1))
      else
        echo "  ❌ Failed to create: $title" >&2
        failed_count=$((failed_count + 1))
      fi
    fi

    rm -f "$sub_desc_file"
  done

  echo "" >&2
  echo "✓ Release tracker created: $parent_key" >&2
  echo "  Subtasks: $subtask_count created" >&2
  [ "$failed_count" -gt 0 ] && echo "  ⚠️  $failed_count subtask(s) failed to create" >&2

  echo "$parent_key"
}

# Update a step's status and add a structured comment
# Args: $1=version (X.Y.Z)
#       $2=step_key (e.g., "cveFixes")
#       $3=status ("in_progress"|"complete"|"failed")
#       $4=data (JSON string with step-specific results) [optional]
#       $5=parent_key [optional, avoids re-lookup]
# Returns: 0 always (best-effort)
update_step() {
  local version="$1"
  version=$(_normalize_version "$version")
  local step_key="$2"
  local status="$3"
  local data="${4:-"{}"}"
  local parent_key="${5:-}"

  _update_step_impl "$version" "$step_key" "$status" "$data" "$parent_key" || true
  return 0
}

_update_step_impl() {
  local version="$1"
  local step_key="$2"
  local status="$3"
  local data="$4"
  local parent_key="$5"

  _validate_version "$version" || return 0

  # Find tracker if not provided
  if [ -z "$parent_key" ]; then
    local _tracker_rc=0
    parent_key=$(find_release_tracker "$version") || _tracker_rc=$?
    if [ "$_tracker_rc" -eq 2 ]; then
      echo "⚠️  update_step: Jira query failed (network/auth) for $version — step not recorded" >&2
      return 0
    fi
    if [ -z "$parent_key" ]; then
      echo "⚠️  No tracker found for $version (run /create-release-tracker $version)" >&2
      return 0
    fi
  fi

  local title="${STEP_TITLES[$step_key]:-$step_key}"
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Build structured comment
  local status_label
  case "$status" in
    in_progress) status_label="IN PROGRESS" ;;
    complete) status_label="COMPLETE" ;;
    failed) status_label="FAILED" ;;
    *) status_label="$status" ;;
  esac

  # Build STEP_DATA JSON safely via jq
  local step_json
  step_json=$(jq -cn \
    --arg step "$step_key" \
    --arg ts "$timestamp" \
    --arg status "$status" \
    --argjson data "$data" \
    '{_t:"STEP_DATA",step:$step,timestamp:$ts,status:$status,data:$data}')

  local comment_body
  comment_body="## $title — $status_label

- **Timestamp:** $timestamp
- **Status:** $status

---
\`\`\`STEP_DATA
$step_json
\`\`\`"

  # Add comment on parent task
  _add_comment "$parent_key" "$comment_body" || {
    echo "⚠️  Failed to add tracker comment for $step_key" >&2
    return 0
  }

  # Transition subtask
  local subtask_key
  subtask_key=$(_find_subtask "$parent_key" "$step_key") || true

  if [ -n "$subtask_key" ]; then
    case "$status" in
      in_progress)
        _transition_issue "$subtask_key" "$JIRA_STATUS_IN_PROGRESS" || \
          echo "  ⚠ Could not update subtask Jira status for $step_key — update manually in Jira" >&2
        ;;
      complete)
        _transition_issue "$subtask_key" "$JIRA_STATUS_RESOLVED" || \
          echo "  ⚠ Could not update subtask Jira status for $step_key — update manually in Jira" >&2
        ;;
      failed)
        # Keep in current status (In Progress), failure recorded in comment
        ;;
    esac
  fi

  echo "✓ Tracker updated: $step_key → $status_label" >&2
}

# Fetch all comments from a tracker parent task as a flat JSON array.
# acli's comment-list JSON shape varies by version: older builds emit a top-level
# array, current acli (1.3.x) emits {"comments":[...]} and --paginate streams one
# such object PER PAGE. Normalize every shape to a single flat array here, at the
# one choke point, so the consumers' `type=="array"` guards and `.[] | .body`
# parse hold unchanged. acli's exit code is captured before the pipe and returned
# unchanged, so a failed read stays non-zero; empty output is preserved as empty
# (callers treat that as an unreliable read). Anything jq can't cleanly flatten
# (null, an error body, garbage) is passed through raw so the callers' array-guard
# rejects it exactly as before. Args: $1=parent_key.
_fetch_tracker_comments() {
  local raw
  raw=$(_acli jira workitem comment list --key "$1" --json --paginate </dev/null 2>/dev/null) || return $?
  [ -z "$raw" ] && return 0
  printf '%s' "$raw" | jq -s '[ .[] |
    if type == "object" and (.comments | type) == "array" then .comments[]
    elif type == "array" then .[]
    else error("unrecognized acli comment shape")
    end ]' 2>/dev/null || printf '%s' "$raw"
}

# Extract the latest STEP_DATA payload for one step from an acli comments JSON
# blob (read on stdin). Single source of truth for the STEP_DATA parse shared by
# get_step and get_release_summary. (find_next_step in autorelease.sh has its own
# copy because it extracts *all* steps to TSV, a different shape.)
# Args: $1=step_key
# Output: the step's JSON object, or empty if none
_extract_step_data() {
  jq -r --arg step "$1" '
    [.[] | .body // empty |
     capture("```STEP_DATA\\n(?<json>\\{[^`]+)\\n```"; "g") // empty |
     .json] |
    map(fromjson? // empty) |
    map(select(._t == "STEP_DATA" and .step == $step)) |
    last // empty
  ' 2>/dev/null || true
}

# Get the latest step data from tracker comments
# Args: $1=version (X.Y.Z)
#       $2=step_key (e.g., "cveFixes")
#       $3=parent_key [optional]
# Output: JSON object with step data, or empty
# Returns: 0 on a good read (step data on stdout, or empty for a genuinely
#          absent step / empty tracker); non-zero if the tracker read FAILED or
#          was unreliable. Callers that record evidence off a read must check the
#          exit code so a transient Jira blip isn't mistaken for "step absent";
#          callers that only display/compare can keep `|| true` to degrade to
#          "no data". (find_next_step guards its own fetch the same way.)
get_step() {
  local version="$1"
  version=$(_normalize_version "$version")
  local step_key="$2"
  local parent_key="${3:-}"

  _validate_version "$version" || return 0

  if [ -z "$parent_key" ]; then
    local find_rc=0
    parent_key=$(find_release_tracker "$version") || find_rc=$?
    if [ "$find_rc" -eq 2 ]; then
      return 2
    fi
    [ -z "$parent_key" ] && return 0
  fi

  # Fetch comments, keeping the fetch's exit code separate from its output. A
  # failed read (auth/network/rate-limit blip) is signalled non-zero, NOT
  # swallowed to empty — empty must mean "step genuinely absent", never "couldn't
  # read". A success exit can still yield empty/garbled output (truncated
  # --paginate, error body, bare null); a real read is always a JSON array
  # (`[]` when the tracker has no comments), so reject anything else as an
  # unreliable read rather than trust it as a zero-step tracker.
  local comments fetch_rc=0
  comments=$(_fetch_tracker_comments "$parent_key") || fetch_rc=$?
  [ "$fetch_rc" -ne 0 ] && return "$fetch_rc"
  if [ -z "$comments" ] || ! printf '%s' "$comments" | jq -e 'type=="array"' >/dev/null 2>&1; then
    return 1
  fi

  # Parse comments to find latest STEP_DATA matching step_key
  # (comments are chronological; _extract_step_data returns the last match)
  printf '%s' "$comments" | _extract_step_data "$step_key"
}

# Build a STEP_DATA payload carrying the current bundleShas snapshot, so that
# snapshot-triggered staleness rules (see STALENESS_RULES / check_freshness) have
# a value to compare against. bundleShas is the source of truth for "which
# component build are we releasing"; a downstream step recorded against an older
# snapshot is correctly flagged stale once bundleShas advances. Prints "{}" when
# the bundleShas snapshot is unavailable (nothing to compare — treated as fresh).
# Args: $1=version  $2=parent_key/tracker [optional]
snapshot_step_data() {
  local version="$1"
  local parent_key="${2:-}"
  local bundle_data rc=0
  bundle_data=$(get_step "$version" "bundleShas" "$parent_key") || rc=$?
  if [ "$rc" -ne 0 ]; then
    # Tracker read failed — warn instead of silently recording "{}", which
    # check_freshness reads as "fresh" forever and so quietly disables this
    # step's snapshot-staleness rule. The step still completes (the human's
    # explicit action shouldn't block on a Jira blip); only the staleness
    # metadata is degraded, and now visibly so.
    echo "  ⚠ Could not read bundleShas snapshot from Jira — snapshot-staleness tracking degraded for this step" >&2
    echo "{}"
    return 0
  fi
  if [ -z "$bundle_data" ]; then
    # bundleShas not yet recorded (rc=0 but empty): completing this step before
    # bundleShas runs disables snapshot-staleness tracking for it — warn visibly.
    echo "  ⚠ bundleShas not yet recorded — completing this step before bundleShas runs disables snapshot-staleness tracking; verify EC passes on the snapshot bundleShas will select" >&2
    echo "{}"
    return 0
  fi
  local snap
  snap=$(printf '%s' "$bundle_data" | jq -r '.data.snapshot // empty' 2>/dev/null) || snap=""
  if [ -n "$snap" ]; then
    jq -cn --arg snap "$snap" '{snapshot:$snap}'
  else
    echo "{}"
  fi
}

# Check freshness of a completed step
# Args: $1=version (X.Y.Z)
#       $2=step_key
#       $3=parent_key [optional]
#       $4=pre-fetched step_data JSON [optional, avoids re-fetching]
# Output: "fresh" or "stale"
# Returns: 0 always
check_freshness() {
  local version="$1"
  version=$(_normalize_version "$version")
  local step_key="$2"
  local parent_key="${3:-}"

  local rule="${STALENESS_RULES[$step_key]:-}"
  if [ -z "$rule" ]; then
    echo "fresh"
    return 0
  fi

  # Use pre-fetched step data if provided, otherwise fetch
  local step_data="${4:-}"
  if [ -z "$step_data" ]; then
    step_data=$(get_step "$version" "$step_key" "$parent_key") || true
  fi
  if [ -z "$step_data" ]; then
    echo "fresh"
    return 0
  fi

  local step_status
  step_status=$(echo "$step_data" | jq -r '.status // empty' 2>/dev/null) || true
  if [ "$step_status" != "complete" ]; then
    echo "fresh"
    return 0
  fi

  local step_timestamp
  step_timestamp=$(echo "$step_data" | jq -r '.timestamp // empty' 2>/dev/null) || true
  if [ -z "$step_timestamp" ]; then
    echo "fresh"
    return 0
  fi

  case "$rule" in
    *d)
      # Time-based staleness (e.g., 3d, 75d)
      local days="${rule%d}"
      local step_epoch now_epoch age_secs max_secs
      if ! step_epoch=$(date -d "$step_timestamp" +%s 2>/dev/null); then
        echo "Cannot parse step timestamp '$step_timestamp'; treating as fresh" >&2
        echo "fresh"
        return 0
      fi
      if ! now_epoch=$(date +%s 2>/dev/null); then
          echo "Cannot determine current time; treating as fresh" >&2
          echo "fresh"
          return 0
      fi
      age_secs=$((now_epoch - step_epoch))
      max_secs=$((days * 86400))

      if [ "$age_secs" -gt "$max_secs" ]; then
        local age_days=$((age_secs / 86400))
        echo "stale"
        echo "  Completed ${age_days}d ago (limit: ${days}d)" >&2
      else
        echo "fresh"
      fi
      ;;
    snapshot)
      # Snapshot-triggered staleness
      # Compare step's snapshot against the latest known snapshot (from bundleShas)
      local step_snapshot
      step_snapshot=$(echo "$step_data" | jq -r '.data.snapshot // empty' 2>/dev/null) || true

      if [ -z "$step_snapshot" ]; then
        echo "fresh"
        return 0
      fi

      local bundle_data latest_snapshot bundle_rc=0
      bundle_data=$(get_step "$version" "bundleShas" "$parent_key") || bundle_rc=$?
      if [ "$bundle_rc" -ne 0 ]; then
        echo "⚠️  check_freshness: get_step(bundleShas) failed (rc=$bundle_rc); treating as stale (fail-closed)" >&2
        echo "stale"
        return 0
      fi
      latest_snapshot=$(echo "$bundle_data" | jq -r '.data.snapshot // empty' 2>/dev/null) || true

      if [ -n "$latest_snapshot" ] && [ "$step_snapshot" != "$latest_snapshot" ]; then
        echo "stale"
        echo "  Snapshot changed: ${step_snapshot:0:30} → ${latest_snapshot:0:30}" >&2
      else
        echo "fresh"
      fi
      ;;
    *)
      echo "fresh"
      ;;
  esac
}

# Update a subtask's description
# Args: $1=version (X.Y.Z)
#       $2=step_key
#       $3=content (markdown string)
#       $4=parent_key [optional]
# Returns: 0 always (best-effort)
update_subtask_description() {
  local version="$1"
  version=$(_normalize_version "$version")
  local step_key="$2"
  local content="$3"
  local parent_key="${4:-}"

  _update_subtask_description_impl "$version" "$step_key" "$content" "$parent_key" >&2 || true
  return 0
}

_update_subtask_description_impl() {
  local version="$1"
  local step_key="$2"
  local content="$3"
  local parent_key="$4"

  _validate_version "$version" || return 0

  if [ -z "$parent_key" ]; then
    parent_key=$(find_release_tracker "$version") || true
    [ -z "$parent_key" ] && return 0
  fi

  local subtask_key
  subtask_key=$(_find_subtask "$parent_key" "$step_key") || {
    echo "⚠️  Could not find subtask for $step_key" >&2
    return 0
  }

  [ -z "$subtask_key" ] && return 0

  local desc_file
  desc_file=$(mktemp)
  printf '%s\n' "$content" > "$desc_file"

  _acli jira workitem edit --key "$subtask_key" --description-file "$desc_file" --yes </dev/null 2>/dev/null || {
    echo "⚠️  Failed to update description for $step_key ($subtask_key)" >&2
  }

  rm -f "$desc_file"
}

# Get a structured summary of all step statuses
# Args: $1=version (X.Y.Z)
# Output: JSON summary with per-step status
# Returns: 0 always
get_release_summary() {
  local version="$1"
  version=$(_normalize_version "$version")

  _validate_version "$version" || { echo "{}"; return 0; }

  local parent_key
  parent_key=$(find_release_tracker "$version") || true
  if [ -z "$parent_key" ]; then
    echo "{}"
    return 0
  fi

  local release_type
  release_type=$(_detect_release_type "$version")

  # Fetch all subtasks with status
  local subtasks
  subtasks=$(query_jira --jql "parent = $parent_key" --fields "key,summary,status" 2>/dev/null) || {
    echo "{}"
    return 0
  }

  # Fetch all comments from parent for step data
  local comments
  comments=$(_fetch_tracker_comments "$parent_key") || true

  # Build summary JSON using jq for safe construction
  local result
  result=$(jq -n --arg version "$version" --arg type "$release_type" --arg tracker "$parent_key" \
    '{version: $version, type: $type, tracker: $tracker, steps: {}}') || { echo "{}"; return 0; }

  for step_key in "${STEP_ORDER[@]}"; do
    step_applies_to_release "$step_key" "$release_type" || continue

    local title="${STEP_TITLES[$step_key]:-$step_key}"
    local phase="${STEP_PHASE[$step_key]:-unknown}"

    # Get subtask Jira status
    local jira_status
    jira_status=$(echo "$subtasks" | jq -r --arg title "$title" '
      [.[] | select(.fields.summary == $title)] | .[0].fields.status.name // "Unknown"
    ' 2>/dev/null) || true

    # Get latest step data from comments
    local step_data="{}"
    if [ -n "$comments" ]; then
      local extracted
      extracted=$(echo "$comments" | _extract_step_data "$step_key") || true
      [ -n "$extracted" ] && step_data="$extracted"
    fi

    # Check freshness
    local freshness="fresh"
    if [ -n "${STALENESS_RULES[$step_key]:-}" ] && [ "$step_data" != "{}" ]; then
      freshness=$(check_freshness "$version" "$step_key" "$parent_key" "$step_data" 2>/dev/null) || true
    fi

    # Merge step into result using jq (handles escaping safely)
    result=$(echo "$result" | jq \
      --arg key "$step_key" \
      --arg title "$title" \
      --arg phase "$phase" \
      --arg jiraStatus "${jira_status:-Unknown}" \
      --arg freshness "$freshness" \
      --argjson stepData "$step_data" \
      '.steps[$key] = {title: $title, phase: $phase, jiraStatus: $jiraStatus, freshness: $freshness, stepData: $stepData}') || true
  done

  echo "$result"
}

# Read-only, best-effort: is the release tracker still OPEN (found, and not yet
# Resolved)? Makes auto-close idempotent — a re-run on an already-resolved
# release must not re-probe registries or add a duplicate resolution comment.
# Returns 0 ONLY when it positively reads a non-Resolved parent status; returns 1
# for Resolved, absent, unparseable, or unreachable — i.e. "do not auto-close
# now" (probe-failure counts as closed-enough so a flake can never re-comment).
# Args: $1=version (X.Y.Z)
tracker_is_open() {
  local version="$1"
  version=$(_normalize_version "$version")
  _validate_version "$version" || return 1

  local version_label result status
  version_label=$(_version_to_label "$version")
  result=$(query_jira --jql "project = ACM AND labels = release-tracking AND labels = $version_label AND issuetype = Task" --fields "key,status" 2>/dev/null) || return 1
  printf '%s' "$result" | jq -e 'type=="array"' >/dev/null 2>&1 || return 1
  status=$(echo "$result" | jq -r '.[0].fields.status.name // empty' 2>/dev/null) || return 1

  [ -n "$status" ] && [ "$status" != "$JIRA_STATUS_RESOLVED" ]
}

# Resolve a release tracker and its subtasks (mark the whole release done).
# Transitions to "Resolved" — the same terminal status a step reaches when it
# completes — not "Closed", so the tracker's end state matches its steps.
# Best-effort like every other Jira write: never blocks on a failed transition.
# Args: $1=version (X.Y.Z)
#       $2=reason (string explaining why)
# Returns: 0 always (best-effort)
close_release_tracker() {
  local version="$1"
  version=$(_normalize_version "$version")
  local reason="$2"

  _close_release_tracker_impl "$version" "$reason" >&2 2>&1 || true
  return 0
}

_close_release_tracker_impl() {
  local version="$1"
  local reason="$2"

  _validate_version "$version" || return 0

  local parent_key tracker_rc=0
  parent_key=$(find_release_tracker "$version") || tracker_rc=$?
  if [ "$tracker_rc" -eq 2 ]; then
    echo "⚠️  close_release_tracker: Jira query failed (network/auth) for $version — skipping close" >&2
    return 0
  fi
  if [ -z "$parent_key" ]; then
    echo "⚠️  No tracker found for $version" >&2
    return 0
  fi

  echo "Resolving release tracker $parent_key ($version)..." >&2

  # Add a resolution comment on the parent
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Build STEP_DATA JSON safely via jq. step "_close" is an internal marker, not
  # a real DAG step, so find_next_step/get_release_summary (which key off
  # STEP_ORDER) ignore it.
  local step_json
  step_json=$(jq -cn --arg ts "$timestamp" --arg reason "$reason" \
    '{_t:"STEP_DATA",step:"_close",timestamp:$ts,status:"resolved",data:{reason:$reason}}')

  local comment
  comment="## Release Tracker Resolved

- **Timestamp:** $timestamp
- **Reason:** $reason

---
\`\`\`STEP_DATA
$step_json
\`\`\`"

  _add_comment "$parent_key" "$comment" || true

  # Resolve all still-open subtasks (any not already Resolved)
  local subtasks
  subtasks=$(query_jira --jql "parent = $parent_key AND status != $JIRA_STATUS_RESOLVED" --fields "key,summary" 2>/dev/null) || true

  if [ -n "$subtasks" ]; then
    local keys
    keys=$(echo "$subtasks" | jq -r '.[].key // empty' 2>/dev/null)
    for key in $keys; do
      _transition_issue "$key" "$JIRA_STATUS_RESOLVED" 2>/dev/null || true
    done
  fi

  # Resolve the parent
  _transition_issue "$parent_key" "$JIRA_STATUS_RESOLVED" 2>/dev/null || true

  echo "✓ Tracker resolved: $parent_key" >&2
}

