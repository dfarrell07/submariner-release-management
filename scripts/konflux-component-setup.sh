#!/bin/bash
# Automate Konflux component setup on new release branches
#
# Usage: konflux-component-setup.sh [repo] [component] [version]
#
# Arguments (all optional, order-independent):
#   repo:      Repository shortcut (operator, submariner, lighthouse, shipyard, subctl),
#              full path, or relative path. Default: current directory.
#   component: Component name (e.g., submariner-operator, lighthouse-agent).
#              Auto-detected for single-component repos when version provided.
#   version:   Release version (e.g., 0.23). Auto-detected from branch if not provided.
#
# Handles 8 components across 5 repositories:
#   submariner-operator (operator repo)
#   submariner-gateway, submariner-globalnet, submariner-route-agent (submariner repo)
#   lighthouse-agent, lighthouse-coredns (lighthouse repo)
#   nettest (shipyard repo)
#   subctl (subctl repo)
#
# Does NOT handle bundle (different workflow).
#
# Exit codes:
#   0: Success (all steps completed)
#   1: Failure (prerequisites, validation, or step failed)

set -euo pipefail

# Locate this script's directory so shared libs source regardless of CWD (this
# script cds into component repos during execution). Computed before any cd.
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

# Component metadata: prefetch_type:has_cpe:special_files
# prefetch_type: gomod, gomod+rpm, rpm
# has_cpe: yes/no (whether component needs CPE label update)
# special_files: comma-separated list of special files to copy (e.g., metricsproxy)
declare -A COMPONENT_META=(
  ["submariner-operator"]="gomod:yes:"
  ["submariner-gateway"]="gomod+rpm:yes:"
  ["submariner-globalnet"]="gomod+rpm:yes:"
  ["submariner-route-agent"]="gomod+rpm:yes:"
  ["lighthouse-agent"]="gomod:yes:"
  ["lighthouse-coredns"]="gomod:yes:"
  ["nettest"]="rpm:yes:metricsproxy"
  ["subctl"]="gomod:yes:"
)

# Repository shortcuts
declare -A REPO_SHORTCUTS=(
  ["operator"]="$HOME/go/src/submariner-io/submariner-operator"
  ["submariner-operator"]="$HOME/go/src/submariner-io/submariner-operator"
  ["submariner"]="$HOME/go/src/submariner-io/submariner"
  ["lighthouse"]="$HOME/go/src/submariner-io/lighthouse"
  ["shipyard"]="$HOME/go/src/submariner-io/shipyard"
  ["subctl"]="$HOME/go/src/submariner-io/subctl"
)

# ━━━ GLOBAL VARIABLES ━━━

COMPONENT=""
LOCKFILE_COMPONENT=""
VERSION_MAJOR=""
VERSION_MINOR=""
VERSION_DASHED=""
VERSION_DOTTED=""
TARGET_BRANCH=""
PREV_VERSION=""
ACM_VERSION=""
PREFETCH_TYPE=""
HAS_CPE=""
SPECIAL_FILES=""
CURRENT_BRANCH=""
declare -a TEKTON_FILES=()

# ━━━ HELPERS ━━━

die() {
  echo "❌ ERROR: $1"
  [ -n "${2:-}" ] && echo "$2"
  exit 1
}

commit_changes() {
  # $1 = commit message
  # $2 (optional) = success message (defaults to "Changes committed")
  git commit -s -m "$1" || die "Failed to commit changes"
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

  # Check bash version
  local BASH_MAJOR
  BASH_MAJOR=$(bash -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null)
  if [ -z "$BASH_MAJOR" ]; then
    BASH_MAJOR=$(bash --version 2>/dev/null | head -1 | sed -nE 's/.*version ([0-9]+).*/\1/p')
  fi

  if [ -z "$BASH_MAJOR" ] || [ "$BASH_MAJOR" -lt 4 ]; then
    local BASH_VER
    BASH_VER=$(bash --version 2>/dev/null | head -1 || echo "unknown")
    die "bash 4.0+ required (current: $BASH_VER)" \
        "This script uses associative arrays (declare -A) which require bash 4.0+."
  fi

  echo "✓ Prerequisites verified: bash 4.0+, git, sed, awk, curl, jq, sha256sum/shasum"
}

# ━━━ STEP 1: DETECT REPOSITORY AND COMPONENT ━━━

# Auto-detect component from repository name (for single-component repos)
auto_detect_component() {
  local VERSION_ARG="${1:-}"
  local REPO_NAME
  REPO_NAME=$(basename "$(pwd)")

  case "$REPO_NAME" in
    submariner-operator)
      COMPONENT="submariner-operator"
      echo "ℹ️  Auto-detected component: $COMPONENT"
      ;;
    shipyard)
      COMPONENT="nettest"
      echo "ℹ️  Auto-detected component: $COMPONENT"
      ;;
    subctl)
      COMPONENT="subctl"
      echo "ℹ️  Auto-detected component: $COMPONENT"
      ;;
    submariner)
      if [ -n "$VERSION_ARG" ]; then
        die "submariner repo has 3 components:" \
            "  submariner-gateway, submariner-globalnet, submariner-route-agent
Please specify component explicitly."
      else
        die "submariner repo has 3 components" \
            "  Please specify component explicitly."
      fi
      ;;
    lighthouse)
      if [ -n "$VERSION_ARG" ]; then
        die "lighthouse repo has 2 components:" \
            "  lighthouse-agent, lighthouse-coredns
Please specify component explicitly."
      else
        die "lighthouse repo has 2 components" \
            "  Please specify component explicitly."
      fi
      ;;
    *)
      die "Cannot auto-detect component from repo: $REPO_NAME" \
          "Please specify component explicitly."
      ;;
  esac
}

detect_repo_and_component() {
  local ARG1="${1:-}"
  local ARG2="${2:-}"
  local ARG3="${3:-}"

  if [ $# -gt 3 ]; then
    die "Too many arguments." \
        "Usage: konflux-component-setup.sh [repo] [component] [version]"
  fi

  local REPO=""
  local VERSION=""

  # Parse arguments (order-independent, detect type by pattern)
  for arg in "$ARG1" "$ARG2" "$ARG3"; do
    [ -z "$arg" ] && continue

    # Expand tilde
    arg="${arg/#\~/$HOME}"

    case "$arg" in
      # Version format: 0.23
      [0-9].[0-9]|[0-9].[0-9][0-9]|[0-9][0-9].[0-9]|[0-9][0-9].[0-9][0-9])
        if [ -n "$VERSION" ]; then
          die "Multiple versions specified"
        fi
        VERSION="$arg"
        ;;
      # Path patterns
      /*|./*|../*)
        if [ -n "$REPO" ]; then
          die "Multiple repositories specified"
        fi
        REPO="$arg"
        ;;
      # Repository shortcuts or component names
      *)
        # Some names (e.g., "submariner-operator") exist in both maps.
        # Disambiguate: if repo is already set, treat as component; vice versa.
        if [ -n "${COMPONENT_META[$arg]:-}" ] && [ -n "${REPO_SHORTCUTS[$arg]:-}" ]; then
          # Ambiguous — use context to decide
          if [ -n "$REPO" ] && [ -z "$COMPONENT" ]; then
            COMPONENT="$arg"
          elif [ -z "$REPO" ] && [ -n "$COMPONENT" ]; then
            REPO="${REPO_SHORTCUTS[$arg]}"
          elif [ -z "$REPO" ] && [ -z "$COMPONENT" ]; then
            # Neither set — default to repo shortcut (matches original behavior)
            REPO="${REPO_SHORTCUTS[$arg]}"
          else
            die "Both repo and component already specified, and '$arg' is ambiguous"
          fi
        # Check if it's a known component
        elif [ -n "${COMPONENT_META[$arg]:-}" ]; then
          if [ -n "$COMPONENT" ]; then
            die "Multiple components specified"
          fi
          COMPONENT="$arg"
        # Check if it's a known shortcut
        elif [ -n "${REPO_SHORTCUTS[$arg]:-}" ]; then
          if [ -n "$REPO" ]; then
            # If it resolves to the same repo, it's a redundant arg — skip
            if [ "$REPO" = "${REPO_SHORTCUTS[$arg]}" ]; then
              continue
            fi
            die "Multiple repositories specified"
          fi
          REPO="${REPO_SHORTCUTS[$arg]}"
        # Try as directory path
        elif [ -d "$arg" ]; then
          if [ -n "$REPO" ]; then
            die "Multiple repositories specified"
          fi
          REPO="$arg"
        else
          die "Unknown argument: $arg" \
              "Expected: repo shortcut, component name, or version (e.g., 0.23)"
        fi
        ;;
    esac
  done

  # Default repo to current directory
  REPO="${REPO:-.}"

  # Validate repo exists
  if [ ! -d "$REPO" ]; then
    case "$REPO" in
      */go/src/submariner-io/*)
        local SHORTCUT
        SHORTCUT=$(basename "$REPO")
        die "Repository not found: $REPO" \
            "The '$SHORTCUT' shortcut expects repos at: ~/go/src/submariner-io/
Your repos may be in a different location.

Solutions:
  1. Use full path: konflux-component-setup.sh /path/to/your/$SHORTCUT
  2. Clone repos to: ~/go/src/submariner-io/"
        ;;
      *)
        die "Repository not found: $REPO"
        ;;
    esac
  fi

  # Validate it's a git repo
  git -C "$REPO" rev-parse --git-dir &>/dev/null || \
    die "Not a git repository: $REPO"

  # Change to repository directory
  if [ "$REPO" != "." ]; then
    cd "$REPO" || die "Cannot change to directory: $REPO"
    echo "ℹ️  Working in repository: $REPO"
  fi

  # If version provided, checkout the branch and set version variables
  if [ -n "$VERSION" ]; then
    # Auto-detect component from repo if not specified
    if [ -z "$COMPONENT" ]; then
      auto_detect_component "$VERSION"
    fi

    # Parse version into major/minor
    VERSION_MAJOR="${VERSION%%.*}"
    VERSION_MINOR="${VERSION##*.}"

    # Construct branch names
    local VERSION_DASH="${VERSION//./-}"
    local RELEASE_BRANCH="release-${VERSION}"
    local BOT_BRANCH="konflux-${COMPONENT}-${VERSION_DASH}"

    # Try release branch first if it has this component's .tekton files (bot PR already merged)
    if git show-ref --verify --quiet "refs/heads/$RELEASE_BRANCH" && \
       git ls-tree -r "$RELEASE_BRANCH" -- ".tekton/${COMPONENT}-${VERSION_DASH}-"* 2>/dev/null | grep -q .; then
      git checkout "$RELEASE_BRANCH" || die "Failed to checkout branch: $RELEASE_BRANCH"
      echo "✅ Checked out: $RELEASE_BRANCH (bot PR already merged)"

    elif git show-ref --verify --quiet "refs/heads/$BOT_BRANCH"; then
      git checkout "$BOT_BRANCH" || die "Failed to checkout branch: $BOT_BRANCH"
      echo "✅ Checked out: $BOT_BRANCH (bot PR pending)"

    else
      die "Neither release nor bot branch found locally" \
          "Expected one of:
  - Release branch: $RELEASE_BRANCH (with .tekton/ directory)
  - Bot branch: $BOT_BRANCH

Ensure Step 2 (configure-downstream) is complete.
The bot creates a PR adding .tekton/ config to the release branch.

To proceed, manually checkout one of these branches:
  git fetch origin && git checkout $BOT_BRANCH
  git fetch origin && git checkout $RELEASE_BRANCH"
    fi
  else
    # No version provided - extract from current branch
    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
    if [ -z "$CURRENT_BRANCH" ] || [ "$CURRENT_BRANCH" = "HEAD" ]; then
      die "Not on a branch (detached HEAD)" \
          "Provide version argument: konflux-component-setup.sh <repo> <component> <version>"
    fi

    # Validate branch is a bot or release branch
    case "$CURRENT_BRANCH" in
      konflux-*)
        # Bot branch format: konflux-{component}-{major}-{minor}
        local TEMP="${CURRENT_BRANCH#konflux-}"
        VERSION_MINOR="${TEMP##*-}"
        TEMP="${TEMP%-*}"
        VERSION_MAJOR="${TEMP##*-}"
        TEMP="${TEMP%-*}"

        # Validate extraction worked
        case "$VERSION_MAJOR" in
          ''|*[!0-9]*)
            die "Bot branch does not match expected pattern: $CURRENT_BRANCH" \
                "Expected: konflux-{component}-{major}-{minor}
Example: konflux-submariner-operator-0-23"
            ;;
        esac
        case "$VERSION_MINOR" in
          ''|*[!0-9]*)
            die "Bot branch does not match expected pattern: $CURRENT_BRANCH" \
                "Expected: konflux-{component}-{major}-{minor}
Example: konflux-submariner-operator-0-23"
            ;;
        esac

        if [ -z "$COMPONENT" ]; then
          COMPONENT="$TEMP"
          echo "ℹ️  Detected component from branch: $COMPONENT"
        fi
        ;;

      release-*)
        # Release branch format: release-{major}.{minor}
        if [ -z "$COMPONENT" ]; then
          auto_detect_component
        fi

        local VERSION_STR="${CURRENT_BRANCH#release-}"
        VERSION_MAJOR="${VERSION_STR%%.*}"
        VERSION_MINOR="${VERSION_STR##*.}"
        ;;

      *)
        die "Not on a bot or release branch (current: $CURRENT_BRANCH)" \
            "Expected patterns:
  - Bot branch: konflux-{component}-{version} (e.g., konflux-submariner-operator-0-23)
  - Release branch: release-{version} (e.g., release-0.23)

Either checkout a branch manually or provide version argument:
  konflux-component-setup.sh <repo> <component> <version>"
        ;;
    esac

    # Validate version numbers
    case "$VERSION_MAJOR" in
      ''|*[!0-9]*)
        die "Could not extract version from branch: $CURRENT_BRANCH" \
            "Extracted: VERSION_MAJOR='$VERSION_MAJOR' VERSION_MINOR='$VERSION_MINOR'"
        ;;
    esac
    case "$VERSION_MINOR" in
      ''|*[!0-9]*)
        die "Could not extract version from branch: $CURRENT_BRANCH" \
            "Extracted: VERSION_MAJOR='$VERSION_MAJOR' VERSION_MINOR='$VERSION_MINOR'"
        ;;
    esac
  fi

  # Get current branch (after checkout if VERSION path)
  if [ -z "$CURRENT_BRANCH" ]; then
    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
    if [ -z "$CURRENT_BRANCH" ] || [ "$CURRENT_BRANCH" = "HEAD" ]; then
      die "Not on a branch (detached HEAD)"
    fi
  fi

  # Validate component is known
  if [ -z "${COMPONENT_META[$COMPONENT]:-}" ]; then
    echo "❌ ERROR: Unknown component: $COMPONENT"
    echo ""
    echo "Known components:"
    for comp in "${!COMPONENT_META[@]}"; do
      echo "  - $comp"
    done | sort
    exit 1
  fi

  # Set derived variables
  VERSION_DASHED="${VERSION_MAJOR}-${VERSION_MINOR}"
  VERSION_DOTTED="${VERSION_MAJOR}.${VERSION_MINOR}"
  TARGET_BRANCH="release-${VERSION_DOTTED}"
  PREV_VERSION=$((VERSION_MINOR - 1))
  ACM_VERSION=$((VERSION_MINOR - 7))

  if [ "$ACM_VERSION" -lt 0 ]; then
    die "ACM version would be negative: 2.$ACM_VERSION" \
        "Minimum supported version is 0.7 (ACM 2.0)"
  fi

  # Validate .tekton directory exists
  [ -d .tekton ] || die ".tekton directory not found" \
      "The Konflux bot must create the initial PR with .tekton files first."

  # Validate previous release branch exists
  git rev-parse --verify "origin/release-${VERSION_MAJOR}.${PREV_VERSION}" &>/dev/null || \
    die "Previous release branch not found: release-${VERSION_MAJOR}.${PREV_VERSION}" \
        "This script needs to copy files from the previous release."

  # Extract component metadata
  IFS=':' read -r PREFETCH_TYPE HAS_CPE SPECIAL_FILES <<< "${COMPONENT_META[$COMPONENT]}"

  # Determine lockfile component name (strips submariner- prefix)
  case "$COMPONENT" in
    submariner-*)
      LOCKFILE_COMPONENT="${COMPONENT#submariner-}"
      ;;
    *)
      LOCKFILE_COMPONENT="$COMPONENT"
      ;;
  esac

  # Set TEKTON_FILES array
  TEKTON_FILES=(.tekton/"${COMPONENT}-${VERSION_DASHED}"-*.yaml)

  # Summary
  echo ""
  echo "━━━ Configuration Summary ━━━"
  echo "Component:      $COMPONENT"
  echo "Current branch: $CURRENT_BRANCH"
  echo "Target branch:  $TARGET_BRANCH"
  echo "Previous ver:   ${VERSION_MAJOR}.${PREV_VERSION}"
  echo "ACM version:    2.${ACM_VERSION}"
  echo "Prefetch type:  $PREFETCH_TYPE"
  echo "Has CPE label:  $HAS_CPE"
  if [ -n "$SPECIAL_FILES" ]; then
    echo "Special files:  $SPECIAL_FILES"
  fi
  echo ""
}

# ━━━ STEP 2: CONFIGURE YAMLLINT IGNORE ━━━

configure_yamllint() {
  echo "━━━ Step 2: Configure YAMLlint Ignore ━━━"

  local CHANGED=false

  # Add .tekton
  if grep -q '\.tekton' .yamllint.yml 2>/dev/null; then
    echo "ℹ️  .tekton already in yamllint ignore"
  else
    sed -i '/^ignore: |$/a\  .tekton' .yamllint.yml || \
      die "Failed to add .tekton to yamllint ignore"
    echo "✓ Added .tekton to yamllint ignore"
    CHANGED=true
  fi

  # Add .rpm-lockfiles if component has RPM dependencies
  case "$PREFETCH_TYPE" in
    *rpm*)
      if grep -q '\.rpm-lockfiles' .yamllint.yml 2>/dev/null; then
        echo "ℹ️  .rpm-lockfiles already in yamllint ignore"
      else
        sed -i '/^ignore: |$/a\  .rpm-lockfiles' .yamllint.yml || \
          die "Failed to add .rpm-lockfiles to yamllint ignore"
        echo "✓ Added .rpm-lockfiles to yamllint ignore"
        CHANGED=true
      fi
      ;;
  esac

  if [ "$CHANGED" = true ]; then
    git add .yamllint.yml || die "Failed to stage .yamllint.yml"
    commit_changes "Configure yamllint ignore for Konflux directories" "Committed yamllint configuration"
  else
    echo "✅ YAMLlint already configured (no commit needed)"
  fi
}

# ━━━ STEP 3: COPY AND CONFIGURE KONFLUX DOCKERFILE ━━━

add_konflux_dockerfile() {
  echo "━━━ Step 3: Add Konflux Dockerfile ━━━"

  local DOCKERFILE="package/Dockerfile.${COMPONENT}.konflux"

  # Copy Dockerfile from previous release
  git show "origin/release-${VERSION_MAJOR}.${PREV_VERSION}:${DOCKERFILE}" > "${DOCKERFILE}" || \
    die "Could not copy Dockerfile from previous release" \
        "Expected: $DOCKERFILE on branch release-${VERSION_MAJOR}.${PREV_VERSION}"
  echo "✓ Copied Dockerfile from release-${VERSION_MAJOR}.${PREV_VERSION}"

  # Copy special files if needed
  if [ -n "$SPECIAL_FILES" ]; then
    local file SPECIAL_PATH
    for file in $(echo "$SPECIAL_FILES" | tr ',' ' '); do
      SPECIAL_PATH="scripts/${COMPONENT}/${file}.konflux"
      if git show "origin/release-${VERSION_MAJOR}.${PREV_VERSION}:${SPECIAL_PATH}" > "${SPECIAL_PATH}" 2>/dev/null; then
        chmod +x "$SPECIAL_PATH"
        if [ -f "$SPECIAL_PATH" ]; then
          echo "✓ Copied special file: $SPECIAL_PATH"
        else
          echo "⚠️  Warning: Special file copy succeeded but file not found: $SPECIAL_PATH"
        fi
      else
        echo "⚠️  Warning: Could not copy special file: $SPECIAL_PATH"
      fi
    done
  fi

  # Update version references in Dockerfile
  sed -i "s/release-${VERSION_MAJOR}.${PREV_VERSION}/${TARGET_BRANCH}/g" "$DOCKERFILE" || \
    die "Failed to update branch references in Dockerfile"
  grep -q "${TARGET_BRANCH}" "$DOCKERFILE" || \
    die "Branch reference update failed - ${TARGET_BRANCH} not found in Dockerfile"
  echo "✓ Updated branch references: release-${VERSION_MAJOR}.${PREV_VERSION} -> ${TARGET_BRANCH}"

  # Update CPE label if component has it
  if [ "$HAS_CPE" = "yes" ]; then
    if grep -q "cpe=" "$DOCKERFILE"; then
      sed -i "s/cpe=\"cpe:\/a:redhat:acm:[0-9.]*::el9\"/cpe=\"cpe:\/a:redhat:acm:2.${ACM_VERSION}::el9\"/" "$DOCKERFILE" || \
        die "Failed to update CPE label in Dockerfile"
      if grep -q "cpe=\"cpe:/a:redhat:acm:2.${ACM_VERSION}::el9\"" "$DOCKERFILE"; then
        echo "✓ Updated CPE label: ACM 2.${ACM_VERSION}"
      else
        die "CPE label update verification failed"
      fi
    else
      echo "⚠️  Warning: CPE label not found in Dockerfile (component may not need it)"
    fi
  fi

  # Fix com.github.url to point to correct repo
  local CURRENT_REPO
  CURRENT_REPO=$(basename "$(pwd)")
  if grep -q 'com.github.url=' "$DOCKERFILE"; then
    sed -i "s|com.github.url=\"https://github.com/submariner-io/[^\"]*\"|com.github.url=\"https://github.com/submariner-io/${CURRENT_REPO}\"|" "$DOCKERFILE"
    echo "✓ Set com.github.url to submariner-io/${CURRENT_REPO}"
  fi

  # Update version label for Y-stream (initial version)
  if grep -q 'version=' "$DOCKERFILE"; then
    sed -i "s/version=\"[^\"]*\"/version=\"v${VERSION_MAJOR}.${VERSION_MINOR}.0\"/" "$DOCKERFILE" || \
      die "Failed to update version label in Dockerfile"
    grep -q "version=\"v${VERSION_MAJOR}.${VERSION_MINOR}.0\"" "$DOCKERFILE" || \
      die "Version label update verification failed"
    echo "✓ Updated version label: v${VERSION_MAJOR}.${VERSION_MINOR}.0"
  else
    echo "⚠️  Warning: No version label found in Dockerfile"
  fi

  # Remove obsolete go generate line if present (operator only)
  if [ "$COMPONENT" = "submariner-operator" ]; then
    if grep -q "^RUN go generate pkg/embeddedyamls/generate.go$" "$DOCKERFILE"; then
      sed -i '/^RUN go generate pkg\/embeddedyamls\/generate.go$/d' "$DOCKERFILE" || \
        die "Failed to remove obsolete go generate line"
      echo "✓ Removed obsolete go generate line"
    fi
  fi

  # Update Tekton config to use Konflux Dockerfile (only if not already .konflux)
  local file _all_have
  _all_have=true
  for file in "${TEKTON_FILES[@]}"; do
    grep -q "package/Dockerfile.${COMPONENT}.konflux" "$file" 2>/dev/null || { _all_have=false; break; }
  done
  if [ "$_all_have" = "true" ]; then
    echo "✓ Tekton already references Konflux Dockerfile"
  else
    for file in "${TEKTON_FILES[@]}"; do
      [ -f "$file" ] || die "No Tekton files found matching pattern: .tekton/${COMPONENT}-${VERSION_DASHED}-*.yaml"
      sed -i "s|package/Dockerfile.${COMPONENT}$|package/Dockerfile.${COMPONENT}.konflux|g" "$file" || \
        die "Failed to update Tekton config to use Konflux Dockerfile"
    done

    if grep -q "package/Dockerfile.${COMPONENT}.konflux" "${TEKTON_FILES[@]}"; then
      echo "✓ Updated Tekton to use Konflux Dockerfile"
    else
      die "Tekton config update verification failed"
    fi
  fi

  # Commit changes
  git add package/ "${TEKTON_FILES[@]}" || exit 1
  # Also add scripts/ if it exists (optional - only nettest has special files)
  if [ -d scripts/ ]; then
    git add scripts/ || true
  fi
  # Re-run safe: on a second run the Dockerfile regenerates byte-identically
  # (deterministic seds, no timestamps) and the Tekton edits are already present,
  # so nothing stages. Skip the commit instead of dying on an empty commit,
  # matching Step 4's guard.
  if git diff --cached --quiet; then
    echo "✅ Konflux Dockerfile already configured (no commit needed)"
  else
    commit_changes "Add Konflux Dockerfile for ${COMPONENT}" "Dockerfile configured and committed"
  fi
}

# ━━━ STEP 4: ADD RPM LOCKFILE SUPPORT (CONDITIONAL) ━━━

add_rpm_lockfile() {
  echo "━━━ Step 4: Add RPM Lockfile Support ━━━"

  # Skip if no RPM dependencies
  case "$PREFETCH_TYPE" in
    *rpm*) ;; # Has RPM dependencies - proceed
    *)
      echo "ℹ️  Component has no RPM dependencies - skipping"
      return 0
      ;;
  esac

  # Check commands exist
  command -v podman &>/dev/null || \
    die "podman not found. Install: sudo dnf install podman"
  command -v subscription-manager &>/dev/null || \
    die "subscription-manager not found. Install: sudo dnf install subscription-manager"

  echo ""

  # Copy lockfile infrastructure
  mkdir -p .rpm-lockfiles
  git show "origin/devel:.rpm-lockfiles/update-lockfile.sh" > .rpm-lockfiles/update-lockfile.sh || \
    die "Could not copy update-lockfile.sh from devel"

  # Copy additional scripts if they exist
  local script
  for script in check-repo-access.sh verify-packages.sh; do
    if git show "origin/devel:.rpm-lockfiles/${script}" > ".rpm-lockfiles/${script}" 2>/dev/null; then
      chmod +x ".rpm-lockfiles/${script}"
    fi
  done

  chmod +x .rpm-lockfiles/update-lockfile.sh || \
    die "Failed to make update-lockfile.sh executable"

  # Copy component-specific lockfile directory from previous release
  git archive "origin/release-0.${PREV_VERSION}" ".rpm-lockfiles/${LOCKFILE_COMPONENT}/" | tar -x || \
    die "Could not copy lockfile directory from previous release" \
        "Expected: .rpm-lockfiles/${LOCKFILE_COMPONENT}/ on branch release-0.${PREV_VERSION}"

  # Verify repository access before expensive lockfile generation
  if [ -x .rpm-lockfiles/check-repo-access.sh ]; then
    .rpm-lockfiles/check-repo-access.sh || \
      die "Repository access failed" \
          "Fix: sudo subscription-manager unregister
     sudo subscription-manager clean
     sudo subscription-manager register --org='<ORG_ID>' --activationkey='<KEY_NAME>'

   First time? See full setup guide:
   https://github.com/submariner-io/submariner/blob/devel/.rpm-lockfiles/README.md"
  fi

  # Generate lockfile
  local BRANCH_FOR_LOCKFILE
  BRANCH_FOR_LOCKFILE=$(git rev-parse --abbrev-ref HEAD)
  echo "ℹ️  Generating RPM lockfile for $LOCKFILE_COMPONENT..."
  .rpm-lockfiles/update-lockfile.sh "$BRANCH_FOR_LOCKFILE" "$LOCKFILE_COMPONENT" || \
    die "Lockfile generation failed" \
        "This usually means subscription-manager is not registered or lacks repo access.

Fix: sudo subscription-manager unregister
     sudo subscription-manager clean
     sudo subscription-manager register --org='<ORG_ID>' --activationkey='<KEY_NAME>'

Verify: .rpm-lockfiles/check-repo-access.sh  (all should show OK, not 403)
Debug:  .rpm-lockfiles/verify-packages.sh $BRANCH_FOR_LOCKFILE

Full setup guide: .rpm-lockfiles/README.md
  or: https://github.com/submariner-io/submariner/blob/devel/.rpm-lockfiles/README.md"

  # Verify lockfile was created
  [ -f ".rpm-lockfiles/${LOCKFILE_COMPONENT}/rpms.lock.yaml" ] || \
    die "Lockfile not created: .rpm-lockfiles/${LOCKFILE_COMPONENT}/rpms.lock.yaml"

  git add .rpm-lockfiles/ || die "Failed to stage .rpm-lockfiles/"
  if git diff --cached --quiet; then
    echo "✅ RPM lockfile unchanged from previous release (no commit needed)"
  else
    commit_changes "Add RPM lockfile support for ${LOCKFILE_COMPONENT}" "RPM lockfile added and committed"
  fi
}

# ━━━ STEP 5: ADD BUILD ARGS FILE (OPERATOR ONLY) ━━━

add_build_args() {
  echo "━━━ Step 5: Add Build Args File ━━━"

  if [ "$COMPONENT" != "submariner-operator" ]; then
    echo "ℹ️  Component is not operator - skipping"
    return 0
  fi

  # Check if already configured (all files must have the parameter)
  local _f _all_have=true
  for _f in "${TEKTON_FILES[@]}"; do
    grep -q "^  - name: build-args-file$" "$_f" 2>/dev/null || { _all_have=false; break; }
  done
  if [ "$_all_have" = true ] && \
     [ -f .tekton/konflux.args ] && \
     grep -q "BASE_BRANCH=${TARGET_BRANCH}" .tekton/konflux.args 2>/dev/null; then
    echo "ℹ️  Build args file already configured"
    return 0
  fi

  # Copy konflux.args from previous release
  git show "origin/release-${VERSION_MAJOR}.${PREV_VERSION}:.tekton/konflux.args" > .tekton/konflux.args || \
    die "Could not copy .tekton/konflux.args from previous release"
  echo "✓ Copied .tekton/konflux.args from release-${VERSION_MAJOR}.${PREV_VERSION}"

  # Update version references
  sed -i "s/release-${VERSION_MAJOR}.${PREV_VERSION}/${TARGET_BRANCH}/g" .tekton/konflux.args || \
    die "Failed to update version references in konflux.args"
  grep -q "${TARGET_BRANCH}" .tekton/konflux.args || \
    die "Version update verification failed in konflux.args"
  echo "✓ Updated branch references in konflux.args"

  # Add build-args-file parameter to Tekton config
  local file
  for file in "${TEKTON_FILES[@]}"; do
    [ -f "$file" ] || die "No Tekton files found matching pattern: .tekton/${COMPONENT}-${VERSION_DASHED}-*.yaml"
    grep -q '^  - name: build-args-file$' "$file" && continue
    sed -i '/value: package\/Dockerfile.submariner-operator.konflux$/a\  - name: build-args-file\n    value: .tekton/konflux.args' "$file" || \
      die "Failed to add build-args-file parameter to Tekton config"
  done

  grep -q "name: build-args-file" "${TEKTON_FILES[@]}" || \
    die "build-args-file parameter not found in Tekton config after adding"
  echo "✓ Added build-args-file parameter to Tekton config"

  git add "${TEKTON_FILES[@]}" .tekton/konflux.args || exit 1
  commit_changes "Add hermetic build args file for ${COMPONENT}" "Build args file configured and committed"
}

# ━━━ STEP 6: ENABLE HERMETIC BUILDS ━━━

enable_hermetic_builds() {
  echo "━━━ Step 6: Enable Hermetic Builds ━━━"

  # Check if already configured (all files must have the parameter)
  local _f _all_have=true
  for _f in "${TEKTON_FILES[@]}"; do
    grep -q "^  - name: hermetic$" "$_f" 2>/dev/null || { _all_have=false; break; }
  done
  if [ "$_all_have" = true ]; then
    echo "ℹ️  Hermetic builds already enabled"
    return 0
  fi

  # Build prefetch-input JSON based on type
  local PREFETCH_JSON
  case "$PREFETCH_TYPE" in
    gomod+rpm)
      PREFETCH_JSON="[{\"type\": \"gomod\", \"path\": \".\"}, {\"type\": \"gomod\", \"path\": \"tools\"}, {\"type\": \"rpm\", \"path\": \"./.rpm-lockfiles/${LOCKFILE_COMPONENT}\"}]"
      ;;
    gomod)
      case "$COMPONENT" in
        lighthouse-coredns)
          PREFETCH_JSON="[{\"type\": \"gomod\", \"path\": \"./coredns\"}]"
          ;;
        subctl)
          PREFETCH_JSON="[{\"type\": \"gomod\", \"path\": \".\"}]"
          ;;
        *)
          PREFETCH_JSON="[{\"type\": \"gomod\", \"path\": \".\"}, {\"type\": \"gomod\", \"path\": \"tools\"}]"
          ;;
      esac
      ;;
    rpm)
      PREFETCH_JSON="[{\"type\": \"rpm\", \"path\": \"./.rpm-lockfiles/${COMPONENT}\"}]"
      ;;
    *)
      die "Unknown prefetch type: $PREFETCH_TYPE"
      ;;
  esac

  echo "ℹ️  Prefetch configuration: $PREFETCH_JSON"

  # Add hermetic build parameters
  local file
  for file in "${TEKTON_FILES[@]}"; do
    [ -f "$file" ] || die "No Tekton files found matching pattern: .tekton/${COMPONENT}-${VERSION_DASHED}-*.yaml"
    awk -v prefetch="$PREFETCH_JSON" '
      /^  pipelineSpec:$/ {
        print "  - name: prefetch-input"
        print "    value: '\''" prefetch "'\''"
        print "  - name: hermetic"
        print "    value: \"true\""
      }
      { print }
    ' "$file" > "$file.tmp" && mv "$file.tmp" "$file" || \
      die "Failed to add hermetic build parameters to $file"
  done

  # Verify BOTH parameters were added to EVERY file. A single grep across all
  # files would pass on partial application (one file matches for all), and the
  # previous "A || !B" form passed when both params were missing.
  for file in "${TEKTON_FILES[@]}"; do
    grep -q "name: hermetic" "$file" && grep -q "name: prefetch-input" "$file" || \
      die "Hermetic build parameters not found in $file after adding"
  done

  git add "${TEKTON_FILES[@]}" || exit 1
  commit_changes "Enable hermetic builds with prefetching for ${COMPONENT}" "Hermetic builds enabled and committed"
}

# ━━━ STEP 7: ADD MULTI-PLATFORM SUPPORT ━━━

add_multiplatform() {
  echo "━━━ Step 7: Add Multi-Platform Support ━━━"

  # Check if already configured (all files must have the parameter)
  local _f _all_have=true
  for _f in "${TEKTON_FILES[@]}"; do
    grep -q "linux/arm64" "$_f" 2>/dev/null || { _all_have=false; break; }
  done
  if [ "$_all_have" = true ]; then
    echo "ℹ️  Multi-platform already enabled"
    return 0
  fi

  local file
  for file in "${TEKTON_FILES[@]}"; do
    [ -f "$file" ] || die "No Tekton files found matching pattern: .tekton/${COMPONENT}-${VERSION_DASHED}-*.yaml"
    grep -q 'linux/arm64' "$file" && continue
    sed -i '/^    - linux\/x86_64$/a\    - linux/arm64\n    - linux/ppc64le\n    - linux/s390x' "$file" || \
      die "Failed to add multi-platform support to Tekton config"
  done

  for file in "${TEKTON_FILES[@]}"; do
    grep -q "linux/arm64" "$file" || \
      die "Multi-platform architectures not found in $file after adding"
  done

  git add "${TEKTON_FILES[@]}" || exit 1
  if git diff --cached --quiet; then
    echo "✅ Multi-platform already set in all files (no commit needed)"
  else
    commit_changes "Add multi-platform build support for ${COMPONENT}" "Multi-platform support enabled and committed"
  fi
}

# ━━━ STEP 8: ENABLE SBOM GENERATION ━━━

enable_sbom() {
  echo "━━━ Step 8: Enable SBOM Generation ━━━"

  # Check if already configured (all files must have the parameter)
  local _f _all_have=true
  for _f in "${TEKTON_FILES[@]}"; do
    grep -q "^  - name: build-source-image$" "$_f" 2>/dev/null || { _all_have=false; break; }
  done
  if [ "$_all_have" = true ]; then
    echo "ℹ️  SBOM generation already enabled"
    return 0
  fi

  local file
  for file in "${TEKTON_FILES[@]}"; do
    [ -f "$file" ] || die "No Tekton files found matching pattern: .tekton/${COMPONENT}-${VERSION_DASHED}-*.yaml"
    grep -q '^  - name: build-source-image$' "$file" && continue
    sed -i '/  - name: hermetic$/,/    value: "true"$/{
      /    value: "true"$/a\  - name: build-source-image\n    value: "true"
    }' "$file" || \
      die "Failed to add build-source-image parameter to Tekton config"
  done

  for file in "${TEKTON_FILES[@]}"; do
    grep -q "name: build-source-image" "$file" || \
      die "build-source-image parameter not found in $file after adding"
  done

  git add "${TEKTON_FILES[@]}" || exit 1
  if git diff --cached --quiet; then
    echo "✅ SBOM already enabled in all files (no commit needed)"
  else
    commit_changes "Enable SBOM generation for ${COMPONENT}" "SBOM generation enabled and committed"
  fi
}

# ━━━ STEP 9: UPDATE TASK REFERENCES ━━━

update_task_refs() {
  echo "━━━ Step 9: Update Task References ━━━"

  echo "ℹ️  Downloading pipeline-patcher..."
  # Download and verify the pipeline-patcher (pinned SHA, checksum, and download
  # hardening all live in scripts/lib/pipeline-patcher.sh, shared with
  # konflux-bundle-setup.sh).
  local SCRIPT
  SCRIPT=$(download_and_verify_patcher) || \
    die "Failed to download/verify pipeline-patcher" \
      "Check network connectivity and GitHub access"
  echo "✓ Checksum verified"

  # Save non-component files before patcher runs (protect bundle, etc.)
  local TEMP_DIR
  TEMP_DIR=$(mktemp -d)
  local file FOUND tf
  for file in .tekton/*.yaml; do
    FOUND=false
    for tf in "${TEKTON_FILES[@]}"; do
      [ "$file" = "$tf" ] && FOUND=true && break
    done
    if [ "$FOUND" = false ]; then
      cp "$file" "$TEMP_DIR/" 2>/dev/null || true
    fi
  done

  # Run patcher
  echo "ℹ️  Updating task references..."
  echo "$SCRIPT" | bash -s bump-task-refs || {
    rm -rf "$TEMP_DIR"
    die "Pipeline patcher execution failed"
  }

  # Restore non-component files
  for file in "$TEMP_DIR"/*.yaml; do
    [ -f "$file" ] && cp "$file" .tekton/
  done
  rm -rf "$TEMP_DIR"

  # Check if component files changed
  if git diff --quiet "${TEKTON_FILES[@]}"; then
    echo "ℹ️  Task references already up to date"
    return 0
  fi

  git add "${TEKTON_FILES[@]}" || exit 1
  commit_changes "Update Tekton task references to latest versions" "Task references updated and committed"
}

# ━━━ STEP 10: ADD FILE CHANGE FILTERS (OPERATOR ONLY) ━━━

add_file_change_filters() {
  echo "━━━ Step 10: Add File Change Filters ━━━"

  if [ "$COMPONENT" != "submariner-operator" ]; then
    echo "ℹ️  Component is not operator - skipping file change filters"
    return 0
  fi

  # Check if already applied - both files must have filters to skip
  local FILTER_COUNT
  FILTER_COUNT=$({ grep -l "pathChanged()" "${TEKTON_FILES[@]}" 2>/dev/null || true; } | wc -l)
  if [ "$FILTER_COUNT" -eq 2 ]; then
    echo "ℹ️  File change filters already present in both files"
    return 0
  fi

  local PREV_VERSION_DASHED="${VERSION_MAJOR}-${PREV_VERSION}"

  echo "📋 Copying CEL expressions from release-${VERSION_MAJOR}.${PREV_VERSION} branch..."

  local FILE_TYPE CURRENT_FILE PREV_FILE CEL_LINE CEL_LINE_UPDATED
  for FILE_TYPE in pull-request push; do
    CURRENT_FILE=".tekton/${COMPONENT}-${VERSION_DASHED}-${FILE_TYPE}.yaml"
    PREV_FILE=".tekton/${COMPONENT}-${PREV_VERSION_DASHED}-${FILE_TYPE}.yaml"

    if [ ! -f "$CURRENT_FILE" ]; then
      echo "⚠️  Warning: $CURRENT_FILE not found, skipping"
      continue
    fi

    # Extract CEL expression from previous branch. `|| true`: git show (missing
    # ref/file) or grep (no match) exits non-zero, which under set -o pipefail
    # would abort before the friendly empty-CEL_LINE handler below.
    CEL_LINE=$(git show "origin/release-${VERSION_MAJOR}.${PREV_VERSION}:${PREV_FILE}" 2>/dev/null | \
      grep 'pipelinesascode.tekton.dev/on-cel-expression:' || true)

    if [ -z "$CEL_LINE" ]; then
      echo "⚠️  Could not extract CEL from ${PREV_FILE} - previous branch may not have filters yet"
      continue
    fi

    # Update version numbers in the expression
    CEL_LINE_UPDATED=$(echo "$CEL_LINE" | \
      sed -e "s/release-${VERSION_MAJOR}.${PREV_VERSION}/release-${VERSION_MAJOR}.${VERSION_MINOR}/g" \
          -e "s/${COMPONENT}-${PREV_VERSION_DASHED}/${COMPONENT}-${VERSION_DASHED}/g")

    # Verify max-keep-runs exists before modifying
    grep -q 'pipelinesascode.tekton.dev/max-keep-runs:' "$CURRENT_FILE" || {
      echo "⚠️  Warning: max-keep-runs annotation not found in $CURRENT_FILE"
      echo "   Cannot add file change filters without insertion point. Skipping."
      continue
    }

    # Delete bot's CEL expression (handles both 1-line and 2-line formats)
    awk '/pipelinesascode.tekton.dev\/on-cel-expression:/ {
      skip=1
      next
    }
    skip && /^[[:space:]]+==/ {
      skip=0
      next
    }
    {
      skip=0
      print
    }' "$CURRENT_FILE" > "${CURRENT_FILE}.tmp" || {
      rm -f "${CURRENT_FILE}.tmp"
      die "Failed to delete bot's CEL expression from $CURRENT_FILE"
    }
    mv "${CURRENT_FILE}.tmp" "$CURRENT_FILE" || \
      die "Failed to replace $CURRENT_FILE after CEL deletion"

    # Insert updated CEL expression after max-keep-runs
    awk -v cel="$CEL_LINE_UPDATED" \
      '/pipelinesascode.tekton.dev\/max-keep-runs:/ {print; print cel; next} {print}' \
      "$CURRENT_FILE" > "${CURRENT_FILE}.tmp" || {
      rm -f "${CURRENT_FILE}.tmp"
      die "Failed to insert updated CEL expression into $CURRENT_FILE"
    }
    mv "${CURRENT_FILE}.tmp" "$CURRENT_FILE" || \
      die "Failed to replace $CURRENT_FILE with updated version"

    # Validate YAML syntax
    yq eval '.' "$CURRENT_FILE" > /dev/null 2>&1 || {
      git checkout "$CURRENT_FILE"
      die "YAML validation failed for $CURRENT_FILE after adding CEL expression"
    }

    echo "✓ Added file change filters to $CURRENT_FILE"
  done

  # Check if any changes were made
  if git diff --quiet "${TEKTON_FILES[@]}"; then
    echo "⚠️  No changes made - previous branch may not have filters configured yet."
    echo "   Skipping commit. Filters will need to be added manually."
    return 0
  fi

  git add "${TEKTON_FILES[@]}" || exit 1
  commit_changes "Add file change filters for operator builds

Add file change filters to CEL expressions in Tekton pipelines.
This prevents operator builds when only bundle files change,
reducing unnecessary pipeline runs." "File change filters added and committed"
}

# ━━━ STEP 11: SUMMARY AND NEXT STEPS ━━━

print_summary() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "✅ Setup Complete for $COMPONENT"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  local COMMIT_COUNT
  # `|| echo 0`: if origin/$TARGET_BRANCH is absent, git log exits non-zero and
  # (with pipefail) would abort under set -e before this summary prints. Fall
  # back to a numeric 0 so the "Commits created" line stays valid.
  COMMIT_COUNT=$(git --no-pager log "origin/${TARGET_BRANCH}..HEAD" --oneline 2>/dev/null | wc -l | tr -d ' ' || echo 0)
  echo "📝 Commits created: $COMMIT_COUNT"
  git --no-pager log "origin/${TARGET_BRANCH}..HEAD" --oneline 2>/dev/null || echo "(Could not fetch commit log)"
  echo ""

  if git diff --quiet && git diff --cached --quiet; then
    echo "✅ Working tree clean"
  else
    echo "⚠️  Uncommitted changes detected:"
    git status --short
  fi

  echo ""
  echo "━━━ Next Steps ━━━"
  echo ""
  echo "1. Review changes:"
  echo "   git log origin/${TARGET_BRANCH}..HEAD"
  echo "   git diff origin/${TARGET_BRANCH}..HEAD"
  echo ""
  echo "2. Validate YAML syntax:"
  echo "   yq eval '.' .tekton/*.yaml > /dev/null && echo '✅ Valid'"
  echo ""
  echo "3. Push to remote:"
  local _gh_user _fork
  _gh_user=$(get_gh_user)
  _fork=$(fork_remote "$(pwd)" "$_gh_user")
  echo "   git push $_fork $CURRENT_BRANCH --force-with-lease"
  echo ""
  echo "4. Wait for build (~15-30 min) and verify:"
  echo "   oc get snapshots -n submariner-tenant --sort-by=.metadata.creationTimestamp | grep ${COMPONENT}"
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ━━━ MAIN ━━━

main() {
  check_prerequisites
  detect_repo_and_component "$@"
  configure_yamllint
  add_konflux_dockerfile
  add_rpm_lockfile
  add_build_args
  enable_hermetic_builds
  add_multiplatform
  enable_sbom
  update_task_refs
  add_file_change_filters
  print_summary
}

main "$@"
