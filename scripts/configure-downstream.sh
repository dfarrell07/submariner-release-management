#!/bin/bash
# Configure Konflux for new Submariner version (Y-stream releases)
#
# Usage: configure-downstream.sh <version>
#
# Arguments:
#   version: Submariner version (e.g., 0.24 or 0.24.0)
#
# What it does:
#   - Auto-detects previous version from existing overlays
#   - Creates feature branch (subm-configure-v0.24) from main
#   - Creates 3 commits with 49 total files:
#     - Commit 1: 26 YAML overlay files
#     - Commit 2: 22 auto-generated Kustomize manifests
#     - Commit 3: 2 ReleasePlanAdmission files (stage + prod)
#   - Verifies all changes before committing
#   - Outputs push command and MR instructions
#
# Exit codes:
#   0: Success (all 3 commits created)
#   1: Failure (prerequisites, validation, or commit failed)

set -euo pipefail

# Resolve script location before any cd so lib paths work from any clone location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INPUT_VERSION="${1:-}"

if [ -z "$INPUT_VERSION" ]; then
  echo "❌ Error: Version argument required"
  echo "   Usage: configure-downstream.sh <version>"
  echo "   Example: configure-downstream.sh 0.24"
  exit 1
fi

# ━━━ PREREQUISITES VALIDATION ━━━

# Change to konflux-release-data repository
cd ~/konflux/konflux-release-data || {
  echo "❌ Error: konflux-release-data repository not found at ~/konflux/konflux-release-data"
  exit 1
}

# Verify repository structure
test -f "tenants-config/build-single.sh" || {
  echo "❌ Error: Invalid konflux-release-data repository (missing build-single.sh)"
  exit 1
}

# Check for uncommitted changes (block on dirty working tree - too risky to auto-resolve)
git diff-index --quiet HEAD -- 2>/dev/null || {
  echo "❌ Error: Working tree has uncommitted changes"
  echo "   Commit or stash changes before running this script"
  git status --short
  exit 1
}

# Switch to main if needed
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
if [ "$CURRENT_BRANCH" != "main" ]; then
  echo "⚠️  On branch $CURRENT_BRANCH - switching to main"
  git checkout main
fi

# Fetch and fast-forward main to match origin
git fetch origin main 2>/dev/null || echo "⚠️  git fetch failed - working with cached remote state"
if ! git merge-base --is-ancestor origin/main HEAD 2>/dev/null; then
  echo "⚠️  Local main behind origin/main - fast-forwarding"
  git merge --ff-only origin/main
fi

# ━━━ VERSION AUTO-DETECTION ━━━

# Validate format: 0.Y or 0.Y.Z (Submariner major version is always 0)
echo "$INPUT_VERSION" | grep -qE '^0\.[0-9]+(\.[0-9]+)?$' || {
  echo "❌ Error: Invalid version format '$INPUT_VERSION'"
  echo "   Expected: 0.Y or 0.Y.Z (e.g., 0.23 or 0.23.1)"
  exit 1
}

# Tracker integration
TRACKER_LIB="${TRACKER_LIB:-$SCRIPT_DIR/lib/jira-tracker.sh}"
# shellcheck source=/dev/null
[ -f "$TRACKER_LIB" ] && source "$TRACKER_LIB" 2>/dev/null || true
TRACKER=$(find_release_tracker "$INPUT_VERSION" 2>/dev/null || true)

# Extract major.minor (0.23.1 → 0.23)
MAJOR_MINOR=$(echo "$INPUT_VERSION" | grep -oE '^[0-9]+\.[0-9]+')
NEW_MINOR=$(echo "$MAJOR_MINOR" | cut -d. -f2)

# Convert to hyphenated format (NEW version)
NEW="0-${NEW_MINOR}"

# Check if version already exists (before marking in_progress to avoid stuck tracker state)
OVERLAY_DIR="$HOME/konflux/konflux-release-data/tenants-config/cluster/kflux-prd-rh02/tenants/submariner-tenant/overlay/application-submariner"
if [ -d "${OVERLAY_DIR}/${NEW}-overlay" ]; then
  echo "❌ Error: Version ${MAJOR_MINOR} already configured"
  echo "   Overlay directory exists: ${NEW}-overlay"
  exit 1
fi

[ -n "${TRACKER:-}" ] && update_step "$INPUT_VERSION" "configureDownstream" "in_progress" '{}' "$TRACKER"

# Find all existing overlays and extract minor versions
EXISTING_VERSIONS=$(find "${OVERLAY_DIR}" -maxdepth 1 -name '[0-9]*-overlay' -printf '%f\n' 2>/dev/null | \
  sed 's/-overlay$//' | sed 's/^0-//' | sort -n)

if [ -z "$EXISTING_VERSIONS" ]; then
  echo "❌ Error: No previous versions found"
  echo "   Cannot auto-detect without existing overlays"
  echo "   Expected at least one directory matching: ${OVERLAY_DIR}/0-*-overlay"
  exit 1
fi

# Get most recent (highest) version
PREV_MINOR=$(echo "$EXISTING_VERSIONS" | tail -1)
PREV="0-${PREV_MINOR}"

# Calculate ACM versions: Submariner 0.X → ACM 2.(X-7)
PREV_ACM="2.$((PREV_MINOR - 7))"
NEW_ACM="2.$((NEW_MINOR - 7))"

# Validate ACM versions are positive
if [ "$((NEW_MINOR - 7))" -lt 0 ]; then
  echo "❌ Error: ACM version would be negative: 2.$((NEW_MINOR - 7))"
  echo "   Minimum supported version is 0.7 (ACM 2.0)"
  exit 1
fi

echo "✓ Version detection:"
echo "  Previous: ${PREV} (ACM ${PREV_ACM})"
echo "  New:      ${NEW} (ACM ${NEW_ACM})"
echo ""

# ━━━ FEATURE BRANCH CREATION ━━━

BRANCH="subm-configure-v${NEW//-/.}"

# Check if branch exists on remote (MUST NOT exist).
# Query the remote directly. show-ref reads the local remote-tracking ref,
# which is stale here — only `git fetch origin main` ran above, so a branch
# created (or deleted) remotely since the last full fetch would be misjudged.
if git ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1; then
  echo "❌ Error: Branch $BRANCH already exists on remote"
  echo "   Delete it first: git push origin --delete $BRANCH"
  echo "   Then re-run this skill"
  exit 1
fi

# Check if branch exists locally (auto-delete if safe)
if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
  echo "⚠️  Local branch $BRANCH exists - deleting and recreating"
  git branch -D "$BRANCH" >/dev/null 2>&1
fi

# Create branch from current HEAD (verified clean main)
git checkout -b "$BRANCH" || {
  echo "❌ Error: Failed to create branch $BRANCH"
  exit 1
}

echo "✓ Created feature branch: $BRANCH"
echo "  (All commits will be made on this branch)"
echo ""

# ━━━ COMMIT 1: CREATE OVERLAY STRUCTURE (26 files) ━━━

cd "${OVERLAY_DIR}"

# Copy overlay
cp -r "${PREV}-overlay" "${NEW}-overlay"
cd "${NEW}-overlay"

# Replace all version strings (3 patterns)
find . -name "*.yaml" -exec sed -i \
    -e "s/$PREV/$NEW/g" \
    -e "s/${PREV//-/.}/${NEW//-/.}/g" \
    -e "s/\/$PREV_ACM\//\/$NEW_ACM\//g" {} +

# Verify (5 checks with specific error messages)
FILE_COUNT=$(find . -name "*.yaml" | wc -l)
[ "$FILE_COUNT" -eq 26 ] || { echo "❌ Expected 26 YAML files, found $FILE_COUNT"; exit 1; }

grep -q "nameSuffix: -$NEW" kustomization.yaml || { echo "❌ nameSuffix not updated in kustomization.yaml"; exit 1; }

grep -q "value: submariner-$NEW" *.yaml || { echo "❌ Application name not updated to submariner-$NEW"; exit 1; }

grep -q "value: release-${NEW//-/.}" component-patch.yaml || { echo "❌ Git branch not updated to release-${NEW//-/.}"; exit 1; }

if grep -rEq "${PREV}|${PREV//-/.}|${PREV_ACM}" .; then
  echo "❌ Old version references still present:"
  grep -rE "${PREV}|${PREV//-/.}|${PREV_ACM}" . | head -3
  exit 1
fi

echo "   ✓ All verifications passed"

# Commit
cd "$(git rev-parse --show-toplevel)"
git add "tenants-config/cluster/kflux-prd-rh02/tenants/submariner-tenant/overlay/application-submariner/${NEW}-overlay"
git commit -s -m "Add Submariner v${NEW//-/.} overlay structure"

echo "✅ Commit 1: Created overlay structure (26 files)"
echo "   - Copied ${PREV}-overlay → ${NEW}-overlay"
echo "   - Updated version strings (${PREV} → ${NEW}, ${PREV_ACM} → ${NEW_ACM})"
echo "   - Verified: nameSuffix, application name, git branch, no old versions"
echo "   - Committed: Add Submariner v${NEW//-/.} overlay structure"
echo ""

# ━━━ COMMIT 2: ENABLE OVERLAY IN TENANT CONFIG (22 files) ━━━

cd ~/konflux/konflux-release-data/tenants-config/cluster/kflux-prd-rh02/tenants/submariner-tenant

# Add to kustomization.yaml (idempotent)
grep -q "overlay/application-submariner/$NEW-overlay" kustomization.yaml || {
  sed -i "/overlay\\/application-submariner\\/$PREV-overlay/a\\  - overlay/application-submariner/$NEW-overlay" kustomization.yaml
}

# Build manifests
cd ~/konflux/konflux-release-data/tenants-config
./build-single.sh submariner-tenant

# Verify (auto-generated files use hyphenated names like submariner-0-23.yaml)
# || COUNT=0: a non-matching glob makes ls exit non-zero, which under
# set -o pipefail would abort before the friendly "found $COUNT" error below.
COUNT=$(ls "auto-generated/cluster/kflux-prd-rh02/tenants/submariner-tenant/"*"-${NEW}.yaml" 2>/dev/null | wc -l) || COUNT=0
[ "$COUNT" -eq 22 ] || { echo "❌ Error: Expected 22 auto-generated files, found $COUNT"; exit 1; }

# Commit
cd "$(git rev-parse --show-toplevel)"
git add tenants-config/cluster/kflux-prd-rh02/tenants/submariner-tenant/kustomization.yaml
git add tenants-config/auto-generated/cluster/kflux-prd-rh02/tenants/submariner-tenant/
git commit -s -m "Enable Submariner v${NEW//-/.} in tenant config"

echo "✅ Commit 2: Enabled overlay in tenant config (22 files)"
echo "   - Added overlay entry to kustomization.yaml"
echo "   - Ran build-single.sh submariner-tenant"
echo "   - Generated 22 auto-generated manifests"
echo "   - Committed: Enable Submariner v${NEW//-/.} in tenant config"
echo ""

# ━━━ COMMIT 3: ADD STAGE/PROD RPAs (2 files) ━━━

cd ~/konflux/konflux-release-data/config/kflux-prd-rh02.0fk9.p1/product/ReleasePlanAdmission/submariner

# Copy RPAs
cp "submariner-release-plan-admission-prod-$PREV.yaml" "submariner-release-plan-admission-prod-$NEW.yaml"
cp "submariner-release-plan-admission-stage-$PREV.yaml" "submariner-release-plan-admission-stage-$NEW.yaml"

# Replace version strings (4 patterns)
sed -i -e "s/$PREV/$NEW/g" \
       -e "s/${PREV//-/.}/${NEW//-/.}/g" \
       -e "s/\"$PREV_ACM\"/\"$NEW_ACM\"/g" \
       -e "s/\\/$PREV_ACM\\//\\/$NEW_ACM\\//g" \
       "submariner-release-plan-admission-"*"-$NEW.yaml"

# Verify (5 checks with specific error messages)
grep -q "intention: staging" "submariner-release-plan-admission-stage-$NEW.yaml" || { echo "❌ Stage RPA intention not 'staging'"; exit 1; }

grep -q "intention: production" "submariner-release-plan-admission-prod-$NEW.yaml" || { echo "❌ Prod RPA intention not 'production'"; exit 1; }

# || COMPONENT_COUNT=0: grep -c exits 1 on zero matches (and 2 if the file is
# missing), which would abort under set -e before the friendly error below.
COMPONENT_COUNT=$(grep -c "url: registry" "submariner-release-plan-admission-prod-$NEW.yaml") || COMPONENT_COUNT=0
[ "$COMPONENT_COUNT" -eq 9 ] || { echo "❌ Expected 9 components in RPA, found $COMPONENT_COUNT"; exit 1; }

grep -q "product_version: \"$NEW_ACM\"" "submariner-release-plan-admission-prod-$NEW.yaml" || { echo "❌ Product version not set to \"$NEW_ACM\""; exit 1; }

PATCH_MATCHES=$(grep -E "v${NEW//-/.}\.[0-9]+-" "submariner-release-plan-admission-"*"-$NEW.yaml" 2>/dev/null || true)
if [ -n "$PATCH_MATCHES" ]; then
  echo "❌ Found patch version in RPA tags (should use minor version only)"
  echo "$PATCH_MATCHES" | head -3
  exit 1
fi

echo "   ✓ All verifications passed"

# Commit
cd "$(git rev-parse --show-toplevel)"
git add "config/kflux-prd-rh02.0fk9.p1/product/ReleasePlanAdmission/submariner/submariner-release-plan-admission-"*"-$NEW.yaml"
git commit -s -m "Add Submariner v${NEW//-/.} stage/prod RPAs"

echo "✅ Commit 3: Added stage/prod RPAs (2 files)"
echo "   - Copied RPA files (stage, prod)"
echo "   - Updated version strings and ACM version"
echo "   - Verified: intentions, component count (9), product version, tag format"
echo "   - Committed: Add Submariner v${NEW//-/.} stage/prod RPAs"
echo ""

# Append to push summary if conductor is running (before marking complete so the
# log entry is present if the step is recorded as done)
if [ -n "${AUTORELEASE_PUSH_LOG:-}" ]; then
  printf '\n  cd %s\n  git push origin %s\n' \
    "$HOME/konflux/konflux-release-data" "$BRANCH" \
    >> "$AUTORELEASE_PUSH_LOG"
fi

# Record completion in tracker
if [ -n "${TRACKER:-}" ]; then
  _tracker_data=$(jq -n --arg branch "$BRANCH" '{branch:$branch}' | jq -c .) || _tracker_data="{}"
  update_step "$INPUT_VERSION" "configureDownstream" "complete" "$_tracker_data" "$TRACKER"
fi

# ━━━ SUMMARY ━━━

echo "━━━ SUMMARY ━━━"
echo ""
echo "✅ All 3 commits completed successfully"
echo "   - 26 overlay files created"
echo "   - 22 auto-generated manifests built"
echo "   - 2 RPA files configured"
echo "   - Total: 49 files added"
echo "   - Branch: $BRANCH (currently checked out)"
echo ""
echo "📋 Review changes:"
echo "   git log --oneline -3                    # View commit messages"
echo "   git diff main...$BRANCH --stat          # View file changes summary"
echo "   git diff main...$BRANCH                 # View full diff"
echo ""
echo "🚀 Next steps:"
echo "   1. Review the commits above"
echo "   2. Push: git push origin $BRANCH"
echo "   3. Create MR in GitLab UI (auto-opens after push)"
echo "   4. After merge, wait for ArgoCD deploy (~5-10 min)"
echo "   5. Verify: oc get releaseplans -n submariner-tenant | grep -E \"stage-${NEW}|prod-${NEW}\""
echo ""
echo "💡 If you need to start over:"
echo "   git checkout main"
echo "   git branch -D $BRANCH"
