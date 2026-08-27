#!/bin/bash
# Automate Konflux bundle setup on new release branches
#
# Usage: konflux-bundle-setup.sh [version]
#
# Arguments:
#   version: Release version (e.g., 0.23). Auto-detected from branch if not provided.
#
# What it does:
#   - Navigates to submariner-operator repo (auto-detects or uses default path)
#   - Detects version and checks out appropriate branch (bot PR or release)
#   - Copies bundle infrastructure from previous release
#   - Adds OLM annotations (7 feature annotations + subscription annotation)
#   - Configures Tekton build parameters (hermetic, multi-platform, SBOM)
#   - Adds file change filters (CEL expressions)
#   - Updates task references to latest versions
#   - Creates 6-9 commits with clear messages
#
# Note: Bundle image SHAs are copied from previous release.
# Update them with bundle-sha-update workflow after component builds complete.
#
# Exit codes:
#   0: Success (all steps completed)
#   1: Failure (prerequisites, validation, or step failed)

set -euo pipefail

# Locate this script's directory so shared libs source regardless of CWD (this
# script cds into the operator repo during execution). Computed before any cd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCHER_LIB="$SCRIPT_DIR/lib/pipeline-patcher.sh"
if [ ! -f "$PATCHER_LIB" ]; then
  echo "ERROR: Required library not found: $PATCHER_LIB" >&2
  exit 1
fi
# shellcheck source=lib/pipeline-patcher.sh
source "$PATCHER_LIB"
# shellcheck source=lib/git-utils.sh
source "$SCRIPT_DIR/lib/git-utils.sh" 2>/dev/null || true

# ━━━ CONSTANTS ━━━

readonly OPERATOR_REPO="$HOME/go/src/submariner-io/submariner-operator"

# ━━━ GLOBAL VARIABLES ━━━

VERSION=""
VERSION_DASH=""
VERSION_MINOR=""
ACM_VERSION=""
PREV_VERSION=""
PREV_VERSION_MINOR=""
PREV_VERSION_DASH=""
PREV_RELEASE_BRANCH=""
RELEASE_BRANCH=""
BOT_BRANCH=""

# ━━━ HELPERS ━━━

die() {
  echo "❌ ERROR: $1"
  [ -n "${2:-}" ] && echo "$2"
  exit 1
}

COMMIT_CREATED=false

commit_changes() {
  # $1 = commit message
  # $2 (optional) = success message (defaults to "Changes committed")
  git commit -s -m "$1" || die "Failed to commit changes"
  COMMIT_CREATED=true
  echo "✅ ${2:-Changes committed}"
}

# ━━━ STEP 0: PREREQUISITES CHECK ━━━

check_prerequisites() {
  local MISSING_TOOLS=()

  command -v git &>/dev/null || MISSING_TOOLS+=("git")
  command -v sed &>/dev/null || MISSING_TOOLS+=("sed")
  command -v awk &>/dev/null || MISSING_TOOLS+=("awk")
  command -v curl &>/dev/null || MISSING_TOOLS+=("curl")
  command -v jq &>/dev/null || MISSING_TOOLS+=("jq")
  command -v sha256sum &>/dev/null || command -v shasum &>/dev/null || MISSING_TOOLS+=("sha256sum")

  if [ "${#MISSING_TOOLS[@]}" -gt 0 ]; then
    echo "❌ ERROR: Missing required tools: ${MISSING_TOOLS[*]}"
    echo ""
    echo "Installation instructions:"
    for tool in "${MISSING_TOOLS[@]}"; do
      case "$tool" in
        git) echo "  git: https://git-scm.com/downloads" ;;
        sed|awk) echo "  $tool: included in most systems" ;;
        curl) echo "  curl: included in most systems" ;;
        jq) echo "  jq: https://jqlang.github.io/jq/download/" ;;
        sha256sum) echo "  sha256sum (Linux) or shasum -a 256 (macOS): included in most systems" ;;
      esac
    done
    exit 1
  fi

  # Navigate to submariner-operator repo
  local REPO_NAME
  REPO_NAME=$(basename "$(pwd)" 2>/dev/null)
  if [ "$REPO_NAME" != "submariner-operator" ]; then
    echo "ℹ️  Not in submariner-operator, changing directory..."

    if [ ! -d "$OPERATOR_REPO" ]; then
      die "Repository not found at $OPERATOR_REPO" \
        "   Clone it first: git clone https://github.com/submariner-io/submariner-operator"
    fi

    cd "$OPERATOR_REPO" || die "Failed to change directory to $OPERATOR_REPO"
    echo "✓ Changed to $(pwd)"
  fi

  # Validate it's a git repo
  git rev-parse --git-dir &>/dev/null || die "Not a git repository: $(pwd)"

  echo ""
  echo "✓ Prerequisites verified: git, sed, awk, curl, jq, sha256sum/shasum"
  echo "✓ Repository: submariner-operator at $(pwd)"
}

# ━━━ STEP 1: PARSE ARGUMENTS AND DETECT VERSION ━━━

parse_args_and_detect_version() {
  local VERSION_ARG="${1:-}"

  if [ $# -gt 1 ]; then
    die "Too many arguments." \
      "Usage: konflux-bundle-setup.sh [version]
Example: konflux-bundle-setup.sh 0.23"
  fi

  if [ -n "$VERSION_ARG" ]; then
    # Validate format: 0.Y or 0.Y.Z
    if ! echo "$VERSION_ARG" | grep -qE '^0\.[0-9]+(\.[0-9]+)?$'; then
      die "Invalid version format: $VERSION_ARG" \
        "Expected: 0.Y or 0.Y.Z (e.g., 0.23 or 0.23.0)"
    fi

    # Extract major.minor (0.23.0 → 0.23)
    VERSION=$(echo "$VERSION_ARG" | grep -oE '^[0-9]+\.[0-9]+')
    echo "ℹ️  Using provided version: $VERSION"
  else
    # Auto-detect from current branch
    local CURRENT_BRANCH
    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
    if [ -z "$CURRENT_BRANCH" ] || [ "$CURRENT_BRANCH" = "HEAD" ]; then
      die "Not on a branch (detached HEAD)" \
        "Provide version argument: konflux-bundle-setup.sh <version>"
    fi

    # Extract version from branch name
    case "$CURRENT_BRANCH" in
      konflux-submariner-bundle-*)
        # Bot branch format: konflux-submariner-bundle-0-23
        local TEMP VERSION_MINOR_LOCAL VERSION_MAJOR_LOCAL
        TEMP="${CURRENT_BRANCH#konflux-submariner-bundle-}"  # "0-23"
        VERSION_MINOR_LOCAL="${TEMP##*-}"                     # "23"
        VERSION_MAJOR_LOCAL="${TEMP%-*}"                      # "0"

        # Validate extraction worked
        case "$VERSION_MAJOR_LOCAL" in
          ''|*[!0-9]*)
            die "Bot branch does not match expected pattern: $CURRENT_BRANCH" \
              "Expected: konflux-submariner-bundle-{major}-{minor}"
            ;;
        esac
        case "$VERSION_MINOR_LOCAL" in
          ''|*[!0-9]*)
            die "Bot branch does not match expected pattern: $CURRENT_BRANCH" \
              "Expected: konflux-submariner-bundle-{major}-{minor}"
            ;;
        esac

        VERSION="${VERSION_MAJOR_LOCAL}.${VERSION_MINOR_LOCAL}"
        echo "ℹ️  Auto-detected version from bot branch: $VERSION"
        ;;
      release-*)
        # Release branch format: release-0.23
        VERSION="${CURRENT_BRANCH#release-}"
        if ! echo "$VERSION" | grep -qE '^0\.[0-9]+$'; then
          die "Release branch does not match expected pattern: $CURRENT_BRANCH" \
            "Expected: release-{major}.{minor}"
        fi
        echo "ℹ️  Auto-detected version from release branch: $VERSION"
        ;;
      *)
        die "Cannot auto-detect version from branch: $CURRENT_BRANCH" \
          "Expected branch format:
  - konflux-submariner-bundle-{major}-{minor} (bot PR branch)
  - release-{major}.{minor} (release branch)

Provide version argument: konflux-bundle-setup.sh <version>"
        ;;
    esac
  fi

  # Parse version into components
  VERSION_MINOR="${VERSION##*.}"
  VERSION_DASH="${VERSION//./-}"

  # Calculate ACM version: Submariner 0.X → ACM 2.(X-7)
  ACM_VERSION="2.$((VERSION_MINOR - 7))"

  # Validate ACM version is positive
  if [ "$((VERSION_MINOR - 7))" -lt 0 ]; then
    die "ACM version would be negative: $ACM_VERSION" \
      "   Minimum supported Submariner version is 0.7 (ACM 2.0)"
  fi

  # Calculate previous version for copying bundle infrastructure
  PREV_VERSION_MINOR=$((VERSION_MINOR - 1))
  PREV_VERSION="0.${PREV_VERSION_MINOR}"
  PREV_VERSION_DASH="0-${PREV_VERSION_MINOR}"
  PREV_RELEASE_BRANCH="release-${PREV_VERSION}"

  # Construct branch names
  RELEASE_BRANCH="release-${VERSION}"
  BOT_BRANCH="konflux-submariner-bundle-${VERSION_DASH}"

  echo ""
  echo "✓ Version configuration:"
  echo "  Submariner version: $VERSION"
  echo "  ACM version: $ACM_VERSION"
  echo "  Release branch: $RELEASE_BRANCH"
  echo "  Bot branch: $BOT_BRANCH"
}

# ━━━ STEP 2: CHECKOUT BRANCH ━━━

checkout_branch() {
  echo ""
  echo "Checking for branches..."

  # Try release branch first if it has .tekton/ (bot PR already merged)
  if git show-ref --verify --quiet "refs/heads/$RELEASE_BRANCH" && \
     git ls-tree -r "$RELEASE_BRANCH" -- .tekton/ 2>/dev/null | grep -q .; then
    git checkout "$RELEASE_BRANCH" || die "Failed to checkout branch: $RELEASE_BRANCH"
    echo "✅ Checked out: $RELEASE_BRANCH (bot PR already merged)"

  elif git show-ref --verify --quiet "refs/heads/$BOT_BRANCH"; then
    # Bot branch exists locally
    git checkout "$BOT_BRANCH" || die "Failed to checkout branch: $BOT_BRANCH"
    echo "✅ Checked out: $BOT_BRANCH (bot PR pending)"

  else
    # Try fetching bot branch from origin
    echo "ℹ️  Neither branch found locally, trying origin..."

    if git fetch origin "$BOT_BRANCH:$BOT_BRANCH" 2>/dev/null; then
      git checkout "$BOT_BRANCH" || die "Failed to checkout branch: $BOT_BRANCH"
      echo "✅ Checked out: $BOT_BRANCH (fetched from origin)"
    else
      die "Neither release nor bot branch found" \
        "
Expected one of:
  - Release branch: $RELEASE_BRANCH (with .tekton/ directory)
  - Bot branch: $BOT_BRANCH

Ensure Step 2 (configure-downstream) is complete.
The bot creates a PR adding .tekton/ config to the release branch.

To proceed, manually checkout one of these branches:
  git fetch origin && git checkout $BOT_BRANCH
  git fetch origin && git checkout $RELEASE_BRANCH"
    fi
  fi

  # Verify .tekton/ directory exists
  if [ ! -d ".tekton" ]; then
    die ".tekton/ directory not found on current branch" \
      "   Branch: $(git rev-parse --abbrev-ref HEAD)

The bot should have created .tekton/ files.
Ensure Step 2 (configure-downstream) is complete."
  fi

  echo "✓ Branch verified with .tekton/ directory"
}

# ━━━ STEP 3: ADD YAMLLINT IGNORE ━━━

add_yamllint_ignore() {
  # Check if .tekton already in .yamllint.yml ignore list
  if grep -q '\.tekton' .yamllint.yml 2>/dev/null; then
    echo "ℹ️  YAMLlint ignore already present (.tekton in .yamllint.yml)"
  else
    echo "Adding .tekton to YAMLlint ignore..."

    # Copy .yamllint.yml from previous release
    git checkout "${PREV_RELEASE_BRANCH}" -- .yamllint.yml || \
      die "Failed to copy .yamllint.yml from ${PREV_RELEASE_BRANCH}"

    git add .yamllint.yml
    commit_changes "Ignore .tekton in YAMLlint" "YAMLlint ignore added"
  fi
}

# ━━━ STEP 4: ADD BUNDLE INFRASTRUCTURE ━━━

add_bundle_infrastructure() {
  echo "Copying bundle infrastructure from ${PREV_RELEASE_BRANCH}..."

  # Copy bundle files from existing branch
  git checkout "${PREV_RELEASE_BRANCH}" -- bundle.Dockerfile.konflux config/bundle/ config/manager/patches/ || \
    die "Failed to copy bundle files from ${PREV_RELEASE_BRANCH}" \
      "   Ensure ${PREV_RELEASE_BRANCH} branch exists with bundle infrastructure"

  echo "✓ Copied bundle.Dockerfile.konflux, config/bundle/, and config/manager/patches/"

  # Update version references in bundle files
  echo "Updating version strings..."

  # Calculate previous ACM version for replacement
  local PREV_ACM_VERSION="2.$((PREV_VERSION_MINOR - 7))"

  # Escape dots for sed patterns (0.22 → 0\.22)
  local PREV_VERSION_ESCAPED="${PREV_VERSION/./\\.}"
  local PREV_ACM_ESCAPED="${PREV_ACM_VERSION/./\\.}"

  # Replace version strings in bundle files
  sed -i \
    -e "s/${PREV_VERSION_ESCAPED}/${VERSION}/g" \
    -e "s/${PREV_VERSION_DASH}/${VERSION_DASH}/g" \
    -e "s/${PREV_ACM_ESCAPED}/${ACM_VERSION}/g" \
    bundle.Dockerfile.konflux config/bundle/kustomization.yaml config/bundle/patches/submariner.csv.config.yaml

  # Update tekton to use Konflux bundle Dockerfile
  sed -i 's|value: bundle.Dockerfile$|value: bundle.Dockerfile.konflux|' \
    .tekton/submariner-bundle-*.yaml

  # Update BASE_BRANCH in konflux.args
  sed -i "s/BASE_BRANCH=.*/BASE_BRANCH=${RELEASE_BRANCH}/" .tekton/konflux.args

  # Verify critical files were created/modified
  [ -f bundle.Dockerfile.konflux ] || die "bundle.Dockerfile.konflux not found"
  [ -d config/bundle ] || die "config/bundle/ directory not found"
  [ -f config/manager/patches/related-images.deployment.config.yaml ] || \
    die "config/manager/patches/related-images.deployment.config.yaml not found"
  grep -q "BASE_BRANCH=${RELEASE_BRANCH}" .tekton/konflux.args || \
    die "BASE_BRANCH not updated in konflux.args"

  # Sync operator-sdk version from bundle.Dockerfile (kept up to date by make bundle)
  if [ -f bundle.Dockerfile ]; then
    local SDK_VERSION
    SDK_VERSION=$(grep -oP 'metrics\.builder=\K[^ ]+' bundle.Dockerfile || true)
    if [ -n "$SDK_VERSION" ]; then
      sed -i "s/metrics\.builder=.*/metrics.builder=${SDK_VERSION}/" bundle.Dockerfile.konflux
      echo "✓ Synced operator-sdk version: ${SDK_VERSION}"
    fi
  fi

  echo "✓ Version strings updated (${VERSION}, ${VERSION_DASH}, ${ACM_VERSION})"

  # Commit changes. Skip if nothing staged: this step re-derives its inputs
  # deterministically (checkout-from-prev + fixed seds), so a re-run stages an
  # identical tree and an unconditional `git commit` would die at a no-op.
  # `--cached` (not a working-tree check) because the -f paths are gitignored —
  # untracked/ignored files never show in `git diff`, only in the staged index.
  git add -f bundle.Dockerfile.konflux config/bundle/ config/manager/patches/ .tekton/
  if git diff --cached --quiet; then
    echo "ℹ️  Bundle infrastructure already present (no commit needed)"
  else
    commit_changes "Add Konflux bundle infrastructure for ${RELEASE_BRANCH}" \
      "Bundle infrastructure configured"
  fi
}

# ━━━ STEP 5: VERIFY BUNDLE IMAGES ━━━

verify_bundle_images() {
  local IMAGE_FILE="config/manager/patches/related-images.deployment.config.yaml"

  echo "Verifying bundle images configuration..."

  if [ ! -f "$IMAGE_FILE" ]; then
    die "Image file not found: $IMAGE_FILE" \
      "
This file should have been copied from ${PREV_RELEASE_BRANCH} in Step 4.
Check that Step 4 completed successfully."
  fi

  # Check for registry.redhat.io URLs with SHA256 digests
  if ! grep -q "registry.redhat.io.*@sha256:" "$IMAGE_FILE"; then
    die "Image file has unexpected format" \
      "
Expected registry.redhat.io URLs with SHA256 digests.
File: $IMAGE_FILE

This should have been copied from ${PREV_RELEASE_BRANCH} in Step 4."
  fi

  echo "✓ Bundle images inherited from ${PREV_RELEASE_BRANCH}"
  echo "  (Images reference ${PREV_VERSION} component SHAs - this is expected)"
  echo ""
  echo "ℹ️  Update SHAs after ${VERSION} component builds complete:"
  echo "  Workflow: ~/.agents/workflows/bundle-sha-update.md"
  echo "  What it does: Updates image SHAs from Konflux snapshots (requires oc login)"
}

# ━━━ STEP 6: ADD OLM FEATURE ANNOTATIONS ━━━

add_olm_feature_annotations() {
  local CSV_FILE="config/manifests/bases/submariner.clusterserviceversion.yaml"

  echo "Checking OLM feature annotations..."

  # Check if annotations already exist
  if grep -q "features.operators.openshift.io/disconnected" "$CSV_FILE"; then
    echo "ℹ️  OLM feature annotations already present"
  else
    echo "Adding OLM feature annotations..."

    # Add feature annotations after description line
    sed -i '/description: Creates and manages Submariner deployments./a\
    features.operators.openshift.io/disconnected: "true"\
    features.operators.openshift.io/fips-compliant: "true"\
    features.operators.openshift.io/proxy-aware: "false"\
    features.operators.openshift.io/tls-profiles: "false"\
    features.operators.openshift.io/token-auth-aws: "false"\
    features.operators.openshift.io/token-auth-azure: "false"\
    features.operators.openshift.io/token-auth-gcp: "false"' "$CSV_FILE"

    git add "$CSV_FILE"
    commit_changes "Add required OLM feature annotations to CSV base" \
      "OLM feature annotations added (7 annotations)"
  fi
}

# ━━━ STEP 7: ADD SUBSCRIPTION ANNOTATION ━━━

add_subscription_annotation() {
  local CSV_FILE="config/manifests/bases/submariner.clusterserviceversion.yaml"

  echo "Checking subscription annotation..."

  # Check if annotation already exists
  if grep -q "valid-subscription" "$CSV_FILE"; then
    echo "ℹ️  Subscription annotation already present"
  else
    echo "Adding subscription annotation..."

    # Add subscription annotation after suggested-namespace line
    sed -i '/operatorframework.io\/suggested-namespace: submariner-operator/a\
    operators.openshift.io/valid-subscription: '\''["OpenShift Platform Plus", "Red Hat\
      Advanced Cluster Management for Kubernetes"]'\''' "$CSV_FILE"

    git add "$CSV_FILE"
    commit_changes "Add required subscription annotation to CSV base" \
      "Subscription annotation added"
  fi
}

# ━━━ STEP 8: ADD BUILD ARGS FILE ━━━

add_build_args_file() {
  echo "Checking build-args-file parameter..."

  local file
  for file in .tekton/submariner-bundle-*.yaml; do
    grep -q "name: build-args-file" "$file" && continue
    echo "Adding build-args-file parameter to $file..."
    sed -i '/value: bundle.Dockerfile.konflux$/a\  - name: build-args-file\n    value: .tekton/konflux.args' \
      "$file"
  done

  git add .tekton/submariner-bundle-*.yaml
  if git diff --cached --quiet; then
    echo "ℹ️  Build args file parameter already present in all files"
  else
    commit_changes "Add build args file to bundle tekton config" \
      "Build args file parameter added"
  fi
}

# ━━━ STEP 9: ENABLE HERMETIC BUILDS AND SBOM ━━━

enable_hermetic_builds() {
  echo "Checking hermetic builds and SBOM parameters..."

  local file
  for file in .tekton/submariner-bundle-*.yaml; do
    grep -q "name: hermetic" "$file" && continue
    echo "Adding hermetic builds and SBOM parameters to $file..."
    sed -i '/value: \.tekton\/konflux\.args$/a\  - name: hermetic\n    value: "true"\n  - name: build-source-image\n    value: "true"' \
      "$file"
  done

  git add .tekton/submariner-bundle-*.yaml
  if git diff --cached --quiet; then
    echo "ℹ️  Hermetic builds and SBOM parameters already present in all files"
  else
    commit_changes "Enable hermetic builds and SBOM for bundle" \
      "Hermetic builds and SBOM enabled"
  fi
}

# ━━━ STEP 10: ADD MULTI-PLATFORM SUPPORT ━━━

add_multiplatform() {
  echo "Checking multi-platform support..."

  local file
  for file in .tekton/submariner-bundle-*.yaml; do
    grep -q "build-platforms" "$file" && continue
    echo "Adding multi-platform support to $file..."
    sed -i '/value: bundle.Dockerfile.konflux$/a\  - name: build-platforms\n    value:\n    - linux/x86_64\n    - linux/ppc64le\n    - linux/s390x\n    - linux/arm64' \
      "$file"
  done

  git add .tekton/submariner-bundle-*.yaml
  if git diff --cached --quiet; then
    echo "ℹ️  Multi-platform support already present in all files"
  else
    commit_changes "Add multi-platform build support to bundle" \
      "Multi-platform support added (x86_64, ppc64le, s390x, arm64)"
  fi
}

# ━━━ STEP 11: ADD FILE CHANGE FILTERS ━━━

add_file_change_filters() {
  echo "Adding file change filters to CEL expressions..."

  # Process both pull-request and push files
  local FILE_TYPE CURRENT_FILE PREV_FILE PREV_VERSION_ESCAPED
  for FILE_TYPE in pull-request push; do
    CURRENT_FILE=".tekton/submariner-bundle-${VERSION_DASH}-${FILE_TYPE}.yaml"
    PREV_FILE=".tekton/submariner-bundle-${PREV_VERSION_DASH}-${FILE_TYPE}.yaml"

    echo "Processing $CURRENT_FILE..."

    # Copy complete working file from previous release (try local first, then remote)
    if git show "${PREV_RELEASE_BRANCH}:${PREV_FILE}" > "${CURRENT_FILE}.new" 2>/dev/null; then
      echo "  Copied from local ${PREV_RELEASE_BRANCH}"
    elif git show "origin/${PREV_RELEASE_BRANCH}:${PREV_FILE}" > "${CURRENT_FILE}.new" 2>/dev/null; then
      echo "  Copied from origin/${PREV_RELEASE_BRANCH}"
    else
      echo "⚠️  Could not copy ${PREV_FILE} from ${PREV_RELEASE_BRANCH} (tried local and origin)"
      echo "   Skipping file change filters for $FILE_TYPE"
      continue
    fi

    # Verify file was copied successfully
    if [ ! -s "${CURRENT_FILE}.new" ]; then
      die "Copied file is empty: ${CURRENT_FILE}.new"
    fi

    # Update version references (escape dots for sed patterns)
    PREV_VERSION_ESCAPED="${PREV_VERSION/./\\.}"

    sed -i \
      -e "s/${PREV_VERSION_DASH}/${VERSION_DASH}/g" \
      -e "s/release-${PREV_VERSION_ESCAPED}/release-${VERSION}/g" \
      "${CURRENT_FILE}.new"

    # Validate YAML before replacing original
    if command -v yq &>/dev/null; then
      if ! yq eval '.' "${CURRENT_FILE}.new" > /dev/null 2>&1; then
        rm -f "${CURRENT_FILE}.new"
        die "YAML invalid after version update in ${CURRENT_FILE}.new"
      fi
    fi

    # Verify final file is not empty before replacing
    if [ ! -s "${CURRENT_FILE}.new" ]; then
      rm -f "${CURRENT_FILE}.new"
      die "Processed file is empty: ${CURRENT_FILE}.new"
    fi

    # Replace original with updated version
    mv "${CURRENT_FILE}.new" "$CURRENT_FILE"

    echo "✓ Updated $FILE_TYPE file"
  done

  git add .tekton/submariner-bundle-*.yaml
  if git diff --cached --quiet; then
    echo "ℹ️  File change filters already present (no commit needed)"
  else
    commit_changes "Avoid building bundle when updating operator

Add file change filters to CEL expressions to prevent
unnecessary bundle builds when only operator files change." \
      "File change filters added"
  fi
}

# ━━━ STEP 12: UPDATE TASK REFERENCES ━━━

update_task_refs() {
  echo "Updating Tekton task references..."

  # Download and verify the pipeline-patcher (pinned SHA, checksum, and download
  # hardening all live in scripts/lib/pipeline-patcher.sh, shared with
  # konflux-component-setup.sh).
  local SCRIPT
  SCRIPT=$(download_and_verify_patcher) || \
    die "Failed to download/verify pipeline-patcher" \
      "Check network connectivity and GitHub access"

  echo "✓ Script checksum verified"

  # Run bump-task-refs (updates all .tekton files, including operator)
  echo "$SCRIPT" | bash -s bump-task-refs

  # Stage all .tekton changes (bundle + operator files). Skip the commit if the
  # patcher was a no-op — the bot-generated .tekton files may already reference
  # the latest task versions (or this is a re-run), so nothing is staged and an
  # unconditional `git commit` would die at the final step despite success.
  # Mirrors the guard in konflux-component-setup.sh update_task_refs.
  git add .tekton/
  if git diff --cached --quiet; then
    echo "ℹ️  Task references already up to date (no commit needed)"
  else
    commit_changes "Update Tekton task references to latest versions" \
      "Task references updated"
  fi
}

# ━━━ STEP 13: FINAL VERIFICATION AND SUMMARY ━━━

print_summary() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Final Verification"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  # 1. Count commits
  local CURRENT_BRANCH COMMIT_COUNT
  CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
  COMMIT_COUNT=$(git --no-pager log "origin/${CURRENT_BRANCH}..HEAD" --oneline 2>/dev/null | wc -l || echo "0")
  echo "✓ Commits created: $COMMIT_COUNT"

  if [ "$COMMIT_COUNT" -lt 6 ] || [ "$COMMIT_COUNT" -gt 9 ]; then
    echo "⚠️  Warning: Expected 6-9 commits, found $COMMIT_COUNT"
  fi

  # 2. Verify clean working tree
  if [ -z "$(git status --porcelain)" ]; then
    echo "✓ Working tree clean"
  else
    echo "⚠️  Warning: Working tree not clean"
    git status --short
  fi

  # 3. Verify all 5 required parameters in spec.params
  echo ""
  echo "Verifying required parameters..."

  local PULL_REQUEST_FILE=".tekton/submariner-bundle-${VERSION_DASH}-pull-request.yaml"
  local PARAMS_SECTION
  PARAMS_SECTION=$(awk '/^spec:$/,/^  pipelineSpec:$/ {print}' "$PULL_REQUEST_FILE")

  local REQUIRED_PARAMS=(
    "dockerfile|bundle.Dockerfile.konflux"
    "build-args-file|.tekton/konflux.args"
    "hermetic|\"true\""
    "build-source-image|\"true\""
    "build-platforms|"
  )

  local PARAMS_OK=true NAME VALUE
  for PARAM_PAIR in "${REQUIRED_PARAMS[@]}"; do
    NAME="${PARAM_PAIR%%|*}"
    VALUE="${PARAM_PAIR##*|}"

    if echo "$PARAMS_SECTION" | grep -q "name: $NAME" && \
       { [ -z "$VALUE" ] || echo "$PARAMS_SECTION" | grep -q "value: $VALUE"; }; then
      echo "  ✓ $NAME${VALUE:+: $VALUE}"
    else
      echo "  ❌ Missing: $NAME${VALUE:+: $VALUE}"
      PARAMS_OK=false
    fi
  done

  if [ "$PARAMS_OK" = false ]; then
    echo ""
    die "Some required parameters are missing"
  fi

  # 4. Run make yamllint
  echo ""
  echo "Running YAML validation..."
  if command -v make &>/dev/null && make yamllint &>/dev/null; then
    echo "✓ YAML validation passed"
  else
    echo "⚠️  Warning: make yamllint failed or not available"
  fi

  # Display summary
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "✅ Bundle Setup Complete"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "Summary:"
  echo "   Version: $VERSION"
  echo "   Branch: $CURRENT_BRANCH"
  echo "   Commits: $COMMIT_COUNT"
  echo ""
  echo "Recent commits:"
  git --no-pager log "origin/${CURRENT_BRANCH}..HEAD" --oneline 2>/dev/null || git --no-pager log --oneline -"$COMMIT_COUNT"
  echo ""
  echo "Files modified:"
  git --no-pager diff --stat "origin/${CURRENT_BRANCH}..HEAD" 2>/dev/null || echo "  (cannot compute diff - no tracking branch)"
  echo ""
  echo "Next steps:"
  echo "   1. Review commits: git log -p origin/${CURRENT_BRANCH}..HEAD"
  echo "   2. Verify changes: git diff origin/${CURRENT_BRANCH}..HEAD"
  local _gh_user _fork
  _gh_user=$(get_gh_user)
  _fork=$(fork_remote "$OPERATOR_REPO" "$_gh_user")
  echo "   3. Push to update bot PR: git push $_fork $CURRENT_BRANCH"
  echo "   4. Wait for Konflux build (~15-30 min)"
  echo "   5. Verify bundle EC tests pass"
  echo ""
  echo "Verification commands:"
  echo "   oc get snapshots -n submariner-tenant | grep submariner-bundle-${VERSION_DASH}"
  echo "   oc get snapshot <name> -n submariner-tenant -o yaml | grep -A5 test.appstudio"
}

# ━━━ MAIN ━━━

main() {
  local input_version="${1:-}"
  check_prerequisites
  parse_args_and_detect_version "$@"

  # Tracker integration (input_version preserves 3-segment before parse overwrites VERSION to 2-segment)
  TRACKER_LIB="${TRACKER_LIB:-$SCRIPT_DIR/lib/jira-tracker.sh}"
  # shellcheck source=/dev/null
  [ -f "$TRACKER_LIB" ] && source "$TRACKER_LIB" 2>/dev/null || true
  TRACKER=$(find_release_tracker "$input_version" 2>/dev/null || true)
  [ -n "${TRACKER:-}" ] && update_step "$input_version" "tektonBundle" "in_progress" '{}' "$TRACKER"

  checkout_branch
  add_yamllint_ignore
  add_bundle_infrastructure
  verify_bundle_images
  add_olm_feature_annotations
  add_subscription_annotation
  add_build_args_file
  enable_hermetic_builds
  add_multiplatform
  add_file_change_filters
  update_task_refs
  print_summary

  # Push summary — only emit when a commit was actually created (idempotent re-runs
  # exit 0 without committing; emitting a phantom push entry would confuse the conductor)
  if [ "$COMMIT_CREATED" = true ] && [ -n "${AUTORELEASE_PUSH_LOG:-}" ]; then
    local current_branch _gh_user _fork
    current_branch=$(git rev-parse --abbrev-ref HEAD)
    _gh_user=$(get_gh_user)
    _fork=$(fork_remote "$OPERATOR_REPO" "$_gh_user")
    printf '\n  cd %s\n  git push %s %s\n' "$OPERATOR_REPO" "$_fork" "$current_branch" >> "$AUTORELEASE_PUSH_LOG"
  fi

  # review level: script stays in_progress. User must push the Tekton config changes
  # and wait for Konflux to rebuild, then explicitly mark complete.
  if [ -n "${TRACKER:-}" ]; then
    local data
    # shellcheck disable=SC2034
    data=$(jq -n --arg ver "$VERSION" '{version:$ver}' | jq -c .) || data="{}"
  fi
}

main "$@"
