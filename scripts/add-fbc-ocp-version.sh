#!/bin/bash
# Add FBC support for new OCP version in Konflux release data
#
# Usage: add-fbc-ocp-version.sh <ocp-version> <min-submariner-version>
#
# Arguments:
#   ocp-version: OCP version (e.g., 4.22 or 4-22)
#   min-submariner-version: Minimum Submariner version for this OCP (e.g., 0.23)
#
# What it does:
#   - Auto-detects previous OCP version from existing overlays
#   - Creates feature branch (subm-fbc-configure-4-22) from main
#   - Creates 3 commits with 17 total files:
#     - Commit 1: 8 YAML overlay files (FBC overlay structure)
#     - Commit 2: 7 auto-generated Kustomize manifests + kustomization.yaml update
#     - Commit 3: 2 FBC RPA files updated (applications list)
#   - Verifies all changes before committing
#   - Outputs push command, MR instructions, and Phase 2 instructions
#
# Exit codes:
#   0: Success (all 3 commits created)
#   1: Failure (prerequisites, validation, or commit failed)

set -euo pipefail

OCP_VERSION="${1:-}"
MIN_SUB="${2:-}"

if [ -z "$OCP_VERSION" ] || [ -z "$MIN_SUB" ]; then
  echo "❌ Error: Two arguments required"
  echo "   Usage: add-fbc-ocp-version.sh <ocp-version> <min-submariner-version>"
  echo "   Example: add-fbc-ocp-version.sh 4.22 0.23"
  exit 1
fi

# ━━━ PREREQUISITES VALIDATION ━━━

cd ~/konflux/konflux-release-data || {
  echo "❌ Error: konflux-release-data repository not found at ~/konflux/konflux-release-data"
  exit 1
}

test -f "tenants-config/build-single.sh" || {
  echo "❌ Error: Invalid konflux-release-data repository (missing build-single.sh)"
  exit 1
}

git diff-index --quiet HEAD -- 2>/dev/null || {
  echo "❌ Error: Working tree has uncommitted changes"
  echo "   Commit or stash changes before running this script"
  git status --short
  exit 1
}

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
if [ "$CURRENT_BRANCH" != "main" ]; then
  echo "⚠️  On branch $CURRENT_BRANCH - switching to main"
  git checkout main
fi

git fetch origin main 2>/dev/null || echo "⚠️  git fetch failed - working with cached remote state"
if ! git merge-base --is-ancestor origin/main HEAD 2>/dev/null; then
  echo "⚠️  Local main behind origin/main - fast-forwarding"
  git merge --ff-only origin/main
fi

# ━━━ VERSION NORMALIZATION ━━━

# Normalize OCP version: accept 4.22 or 4-22
OCP_VERSION="${OCP_VERSION//./-}"
echo "$OCP_VERSION" | grep -qE '^4-[0-9]+$' || {
  echo "❌ Error: Invalid OCP version format '$OCP_VERSION'"
  echo "   Expected: 4.XX or 4-XX (e.g., 4.22 or 4-22)"
  exit 1
}

NEW="$OCP_VERSION"
NEW_DOT="${NEW//-/.}"

echo "$MIN_SUB" | grep -qE '^0\.[0-9]+$' || {
  echo "❌ Error: Invalid min Submariner version format '$MIN_SUB'"
  echo "   Expected: 0.XX (e.g., 0.23)"
  exit 1
}

# ━━━ VERSION AUTO-DETECTION ━━━

FBC_OVERLAY_DIR="tenants-config/cluster/kflux-prd-rh02/tenants/submariner-tenant/overlay/application-submariner-fbc"

if [ -d "${FBC_OVERLAY_DIR}/${NEW}-overlay" ]; then
  echo "❌ Error: OCP ${NEW_DOT} already configured"
  echo "   Overlay directory exists: ${FBC_OVERLAY_DIR}/${NEW}-overlay"
  exit 1
fi

EXISTING_VERSIONS=$(find "${FBC_OVERLAY_DIR}" -maxdepth 1 -name '4-*-overlay' -printf '%f\n' 2>/dev/null | \
  sed 's/-overlay$//' | sort -t- -k2 -n)

if [ -z "$EXISTING_VERSIONS" ]; then
  echo "❌ Error: No previous FBC versions found"
  echo "   Expected at least one directory matching: ${FBC_OVERLAY_DIR}/4-*-overlay"
  exit 1
fi

PREV=$(echo "$EXISTING_VERSIONS" | tail -1)
PREV_DOT="${PREV//-/.}"

echo "✓ Version detection:"
echo "  Previous OCP: ${PREV_DOT}"
echo "  New OCP:      ${NEW_DOT}"
echo "  Min Submariner: ${MIN_SUB}"
echo ""

# ━━━ FEATURE BRANCH CREATION ━━━

BRANCH="subm-fbc-configure-${NEW}"

# Query the remote directly. show-ref reads the local remote-tracking ref,
# which is stale here — only `git fetch origin main` ran above, so a branch
# created (or deleted) remotely since the last full fetch would be misjudged.
if git ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1; then
  echo "❌ Error: Branch $BRANCH already exists on remote"
  echo "   Delete it first: git push origin --delete $BRANCH"
  echo "   Then re-run this script"
  exit 1
fi

if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
  echo "⚠️  Local branch $BRANCH exists - deleting and recreating"
  git branch -D "$BRANCH" >/dev/null 2>&1
fi

git checkout -b "$BRANCH" || {
  echo "❌ Error: Failed to create branch $BRANCH"
  exit 1
}

echo "✓ Created feature branch: $BRANCH"
echo ""

# ━━━ COMMIT 1: CREATE FBC OVERLAY STRUCTURE (8 files) ━━━

cd "$HOME/konflux/konflux-release-data/${FBC_OVERLAY_DIR}"

cp -r "${PREV}-overlay" "${NEW}-overlay"
cd "${NEW}-overlay"

find . -name "*.yaml" -exec sed -i \
    -e "s/$PREV/$NEW/g" \
    -e "s/$PREV_DOT/$NEW_DOT/g" {} +

FILE_COUNT=$(find . -name "*.yaml" | wc -l)
[ "$FILE_COUNT" -eq 8 ] || { echo "❌ Expected 8 YAML files, found $FILE_COUNT"; exit 1; }

grep -q "nameSuffix: -$NEW" kustomization.yaml || { echo "❌ nameSuffix not updated in kustomization.yaml"; exit 1; }

grep -rq "submariner-fbc-$NEW" . || { echo "❌ Application name not updated to submariner-fbc-$NEW"; exit 1; }

if grep -rq "$PREV" . || grep -rq "$PREV_DOT" .; then
  echo "❌ Old version references still present:"
  grep -rn "$PREV\|$PREV_DOT" . | head -3
  exit 1
fi

echo "   ✓ All verifications passed"

cd "$(git rev-parse --show-toplevel)"
git add "${FBC_OVERLAY_DIR}/${NEW}-overlay"
git commit -s -m "Add Submariner FBC $NEW_DOT overlay structure"

echo "✅ Commit 1: Created FBC overlay structure (8 files)"
echo "   - Copied ${PREV}-overlay → ${NEW}-overlay"
echo "   - Updated version strings (${PREV_DOT} → ${NEW_DOT})"
echo ""

# ━━━ COMMIT 2: ENABLE OVERLAY IN TENANT CONFIG (7 auto-generated + kustomization) ━━━

cd ~/konflux/konflux-release-data/tenants-config/cluster/kflux-prd-rh02/tenants/submariner-tenant

grep -q "overlay/application-submariner-fbc/$NEW-overlay" kustomization.yaml || {
  sed -i "/overlay\/application-submariner-fbc\/$PREV-overlay/a\\  - overlay/application-submariner-fbc/$NEW-overlay" kustomization.yaml
}

cd ~/konflux/konflux-release-data/tenants-config
./build-single.sh submariner-tenant

# || COUNT=0: a non-matching glob makes ls exit non-zero, which under
# set -o pipefail would abort before the friendly "found $COUNT" error below.
COUNT=$(ls auto-generated/cluster/kflux-prd-rh02/tenants/submariner-tenant/*fbc*"${NEW}"*.yaml 2>/dev/null | wc -l) || COUNT=0
[ "$COUNT" -eq 7 ] || { echo "❌ Error: Expected 7 auto-generated FBC files, found $COUNT"; exit 1; }

cd "$(git rev-parse --show-toplevel)"
git add tenants-config/cluster/kflux-prd-rh02/tenants/submariner-tenant/kustomization.yaml
git add tenants-config/auto-generated/cluster/kflux-prd-rh02/tenants/submariner-tenant/
git commit -s -m "Enable Submariner FBC $NEW_DOT in tenant config"

echo "✅ Commit 2: Enabled FBC overlay in tenant config"
echo "   - Added overlay entry to kustomization.yaml"
echo "   - Generated 7 auto-generated manifests"
echo ""

# ━━━ COMMIT 3: UPDATE FBC RPAs (2 files) ━━━

cd ~/konflux/konflux-release-data/config/kflux-prd-rh02.0fk9.p1/product/ReleasePlanAdmission/submariner

for RPA in submariner-fbc-stage.yaml submariner-fbc-prod.yaml; do
  grep -q "submariner-fbc-$NEW" "$RPA" || {
    sed -i "/submariner-fbc-$PREV$/a\\    - submariner-fbc-$NEW" "$RPA"
  }
done

for RPA in submariner-fbc-stage.yaml submariner-fbc-prod.yaml; do
  grep -q "submariner-fbc-$NEW" "$RPA" || { echo "❌ $RPA missing submariner-fbc-$NEW"; exit 1; }
done
echo "   ✓ Both FBC RPAs updated"

cd "$(git rev-parse --show-toplevel)"
git add config/kflux-prd-rh02.0fk9.p1/product/ReleasePlanAdmission/submariner/submariner-fbc-stage.yaml
git add config/kflux-prd-rh02.0fk9.p1/product/ReleasePlanAdmission/submariner/submariner-fbc-prod.yaml
COMMIT3_CREATED=false
if git diff --cached --quiet; then
  echo "⚠️  RPAs already updated - skipping commit 3"
else
  git commit -s -m "Add Submariner FBC $NEW_DOT to RPAs"
  COMMIT3_CREATED=true
fi

if [ "$COMMIT3_CREATED" = "true" ]; then
  echo "✅ Commit 3: Added FBC $NEW_DOT to RPAs (2 files)"
  echo ""
fi

# ━━━ SUMMARY ━━━

echo "━━━ SUMMARY ━━━"
echo ""
COMMIT_COUNT=2
[ "$COMMIT3_CREATED" = "true" ] && COMMIT_COUNT=3
echo "✅ Phase 1 complete: $COMMIT_COUNT commits in konflux-release-data"
echo "   - 8 overlay files created"
echo "   - 7 auto-generated manifests built"
echo "   - 2 RPA files updated"
echo "   - Branch: $BRANCH"
echo ""
echo "📋 Review changes:"
echo "   git log --oneline -3"
echo "   git diff main...$BRANCH --stat"
echo ""
echo "🚀 Next steps (Phase 1):"
echo "   1. Review the commits above"
echo "   2. Push: git push origin $BRANCH"
echo "   3. Create MR in GitLab UI (auto-opens after push)"
echo "   4. After merge, wait for ArgoCD deploy (~5-10 min)"
echo ""
echo "🔜 Phase 2: After MR merges and bot PR appears in submariner-operator-fbc"
echo ""
echo "   cd ~/konflux/submariner-operator-fbc"
echo "   gh pr list --search \"submariner-fbc-${NEW}\""
echo ""
echo "   # Check out bot's branch:"
echo "   git checkout konflux-submariner-fbc-${NEW}"
echo ""
echo "   # Update drop-versions.json - add: \"${NEW_DOT}\": \"${MIN_SUB}\""
echo "   # Build catalogs:"
echo "   make build-catalogs validate-catalogs"
echo ""
echo "   # Fix Tekton build-args and path filters"
echo "   # See: CLAUDE.md → 'Add Support for New OCP Version'"
echo ""
echo "💡 If you need to start over:"
echo "   git checkout main"
echo "   git branch -D $BRANCH"
