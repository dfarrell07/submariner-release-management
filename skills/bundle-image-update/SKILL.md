---
name: bundle-image-update
description: Update bundle component image SHAs from Konflux snapshots - automates SHA extraction, config file updates, bundle regeneration, and verification
version: 1.0.0
argument-hint: "[X.Y|X.Y.Z] [--snapshot name]"
user-invocable: true
allowed-tools: Bash
---

# Bundle Image Update Workflow

Automate updating bundle component image SHAs from Konflux snapshots.

**What this skill does:**

1. Validates prerequisites (bash version, oc login, repository)
2. Parses arguments and detects version from branch
3. Queries Konflux snapshot for latest passing builds
4. Extracts component SHAs from snapshot (7 unique + 1 duplicate)
5. Updates config file with new SHAs (preserves registry.redhat.io URLs)
6. Regenerates bundle with make bundle
7. Updates Dockerfile labels (version bumps only)
8. Verifies all SHAs match snapshot
9. Creates commit with appropriate message
10. Displays summary and next steps

**Usage:**

```bash
/bundle-image-update                              # Auto: latest snapshot, SHA-only
/bundle-image-update 0.23                         # Version bump to 0.23.0 (defaults to .0)
/bundle-image-update 0.21.2                       # Version bump to 0.21.2 (explicit patch)
/bundle-image-update --snapshot submariner-0-21-xxxxx  # Specific snapshot, SHA-only
/bundle-image-update 0.21.2 --snapshot submariner-0-21-xxxxx  # Version bump with specific snapshot
```

**Requirements:**

- `~/go/src/submariner-io/submariner-operator` repository must exist (auto-navigates if needed)
- Repository must be on a release branch (e.g., `release-0.21`)
- Must be logged into Konflux cluster: `oc login --web https://api.kflux-prd-rh02.0fk9.p1.openshiftapps.com:6443/`
- Bash 4.0+ (for associative arrays)

---

## Step 0: Prerequisites, Arguments, and Version Detection

Validate environment, parse arguments, and determine version/update type.

```bash
#!/bin/bash
set -euo pipefail

echo "=== Bundle Image Update ==="
echo ""

# Check bash version (works in both interactive and non-interactive shells)
BASH_MAJOR=$(bash -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null)
if [ -z "$BASH_MAJOR" ]; then
  # Fallback: parse from bash --version
  BASH_MAJOR=$(bash --version 2>/dev/null | head -1 | sed -nE 's/.*version ([0-9]+).*/\1/p')
fi

if [ -z "$BASH_MAJOR" ] || [ "$BASH_MAJOR" -lt 4 ]; then
  BASH_VER=$(bash --version 2>/dev/null | head -1 || echo "unknown")
  echo "❌ ERROR: Bash 4.0+ required (current: $BASH_VER)"
  echo "Associative arrays needed for component mapping"
  echo ""
  echo "macOS users: brew install bash"
  echo "Then ensure the new bash is in your PATH before /bin/bash"
  exit 1
fi

# Check oc login
if ! oc auth can-i get snapshots -n submariner-tenant &>/dev/null; then
  echo "❌ ERROR: Not logged into Konflux cluster"
  echo "Run: oc login --web https://api.kflux-prd-rh02.0fk9.p1.openshiftapps.com:6443/"
  exit 1
fi

# Navigate to submariner-operator repository
cd ~/go/src/submariner-io/submariner-operator 2>/dev/null || {
  echo "❌ ERROR: Repository not found at ~/go/src/submariner-io/submariner-operator"
  exit 1
}

# Check on release branch
BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [[ ! "$BRANCH" =~ ^release- ]]; then
  echo "❌ ERROR: Not on a release branch"
  echo "Current branch: $BRANCH"
  exit 1
fi

echo "✓ Prerequisites verified"
echo ""

# Parse arguments
VERSION_ARG=""
SNAPSHOT_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --snapshot)
      if [ -z "${2:-}" ]; then
        echo "❌ ERROR: --snapshot requires a value"
        echo "Usage: /bundle-image-update [X.Y|X.Y.Z] [--snapshot name]"
        echo "Example: /bundle-image-update 0.23 --snapshot submariner-0-23-xxxxx"
        exit 1
      fi
      SNAPSHOT_ARG="$2"
      shift 2
      ;;
    *)
      if [ -z "$VERSION_ARG" ]; then
        VERSION_ARG="$1"
      else
        echo "❌ ERROR: Unexpected argument: $1"
        echo "Usage: /bundle-image-update [X.Y|X.Y.Z] [--snapshot name]"
        echo "Example: /bundle-image-update 0.23 --snapshot submariner-0-23-xxxxx"
        exit 1
      fi
      shift
      ;;
  esac
done

# Extract version from branch if not provided
if [ -z "$VERSION_ARG" ]; then
  VERSION_DOT="${BRANCH#release-}"  # release-0.21 → 0.21
  # Validate auto-detected version format
  if ! echo "$VERSION_DOT" | grep -qE '^[0-9]+\.[0-9]+$'; then
    echo "❌ ERROR: Invalid version in branch name: $BRANCH"
    echo "   Expected branch format: release-X.Y (e.g., release-0.21)"
    echo "   Extracted version: $VERSION_DOT"
    exit 1
  fi
else
  # Validate format and default to .0 if patch version omitted
  if echo "$VERSION_ARG" | grep -qE '^[0-9]+\.[0-9]+$'; then
    # X.Y format → default to X.Y.0
    VERSION_ARG="${VERSION_ARG}.0"
    echo "ℹ️  Defaulting to $VERSION_ARG (patch version 0)"
  elif ! echo "$VERSION_ARG" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    # Invalid format
    echo "❌ ERROR: Invalid version format: $VERSION_ARG"
    echo "   Expected: X.Y or X.Y.Z (e.g., 0.23, 0.21.2)"
    exit 1
  fi
  VERSION_DOT=$(echo "$VERSION_ARG" | grep -oE '^[0-9]+\.[0-9]+')
fi

VERSION_DASH="${VERSION_DOT//./-}"  # 0.21 → 0-21

# Read current bundle version
CURRENT_VERSION=$(grep "^  version:" bundle/manifests/submariner.clusterserviceversion.yaml | head -1 | awk '{print $2}')

if ! echo "$CURRENT_VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "❌ ERROR: Invalid version format in CSV: $CURRENT_VERSION"
  echo "   Expected: X.Y.Z (e.g., 0.21.1)"
  exit 1
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

# Create state file (clean up old ones first to prevent confusion)
STATE_FILE="/tmp/bundle-image-update-${VERSION_DASH}.txt"
rm -f /tmp/bundle-image-update-*.txt
cat > "$STATE_FILE" <<EOF
VERSION_DOT="$VERSION_DOT"
VERSION_DASH="$VERSION_DASH"
CURRENT_VERSION="$CURRENT_VERSION"
TARGET_VERSION="$TARGET_VERSION"
UPDATE_TYPE="$UPDATE_TYPE"
SNAPSHOT_ARG="$SNAPSHOT_ARG"
EOF

echo "ℹ️  Version: $VERSION_DOT"
echo "ℹ️  Current bundle version: $CURRENT_VERSION"
echo "ℹ️  Target bundle version: $TARGET_VERSION"
echo "ℹ️  Update type: $UPDATE_TYPE"
echo ""
```

---

## Step 1: Query Snapshot and Extract SHAs

Find latest snapshot and extract component image SHAs. Prefers passing snapshots, falls back to
latest push snapshot if none passing (handles new version setup where bundle EC fails).

```bash
#!/bin/bash
set -euo pipefail

# Navigate to repository first
cd ~/go/src/submariner-io/submariner-operator 2>/dev/null || {
  echo "❌ ERROR: Repository not found at ~/go/src/submariner-io/submariner-operator"
  exit 1
}

# Detect version from branch to find correct state file
BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [[ ! "$BRANCH" =~ ^release- ]]; then
  echo "❌ ERROR: Not on a release branch: $BRANCH"
  exit 1
fi
VERSION_DOT="${BRANCH#release-}"
VERSION_DASH="${VERSION_DOT//./-}"
STATE_FILE="/tmp/bundle-image-update-${VERSION_DASH}.txt"

if [ ! -f "$STATE_FILE" ]; then
  echo "❌ ERROR: State file not found: $STATE_FILE"
  echo "Did Step 0 complete successfully?"
  exit 1
fi
source "$STATE_FILE"

echo "Querying Konflux snapshots..."

# Query latest passing snapshot (or use --snapshot arg)
if [ -n "$SNAPSHOT_ARG" ]; then
  SNAPSHOT="$SNAPSHOT_ARG"
  # Verify snapshot exists (pipe directly, don't store JSON in variable)
  CREATION_TIME=$(oc get snapshot "$SNAPSHOT" -n submariner-tenant -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null)
  if [ -z "$CREATION_TIME" ]; then
    echo "❌ ERROR: Snapshot not found: $SNAPSHOT"
    exit 1
  fi
  echo "ℹ️  Using specified snapshot: $SNAPSHOT (created $CREATION_TIME)"
else
  # Get snapshot names only (avoids JSON corruption with large result sets)
  SNAPSHOT_NAMES=$(oc get snapshots -n submariner-tenant \
    -l 'pac.test.appstudio.openshift.io/event-type in (push,retest-comment)' \
    --sort-by=.metadata.creationTimestamp -o name | \
    grep "^snapshot.appstudio.redhat.com/submariner-${VERSION_DASH}")

  if [ -z "$SNAPSHOT_NAMES" ]; then
    echo "❌ ERROR: No snapshots found for version ${VERSION_DOT}"
    exit 1
  fi

  # Try finding passing snapshot (check recent 20)
  SNAPSHOT=""
  for SNAP_NAME in $(echo "$SNAPSHOT_NAMES" | tail -20); do
    SNAP="${SNAP_NAME#snapshot.appstudio.redhat.com/}"
    STATUS=$(oc get snapshot "$SNAP" -n submariner-tenant \
      -o jsonpath='{.status.conditions[?(@.type=="AppStudioTestSucceeded")].status}' 2>/dev/null)
    if [ "$STATUS" = "True" ]; then
      SNAPSHOT="$SNAP"
    fi
  done

  if [ -z "$SNAPSHOT" ]; then
    echo "⚠️  No passing snapshot found - using latest push snapshot..."
    SNAPSHOT_NAME=$(echo "$SNAPSHOT_NAMES" | tail -1)
    SNAPSHOT="${SNAPSHOT_NAME#snapshot.appstudio.redhat.com/}"
    FALLBACK=true
  else
    FALLBACK=false
  fi

  # Display snapshot info (pipe directly, don't store in variable)
  CREATION_TIME=$(oc get snapshot "$SNAPSHOT" -n submariner-tenant -o jsonpath='{.metadata.creationTimestamp}')
  echo "ℹ️  Using snapshot: $SNAPSHOT (created $CREATION_TIME)"
  [ "$FALLBACK" = true ] && echo "   Note: Snapshot may have test failures (expected for new version setup)"
fi

echo ""

# Extract component SHAs (7 unique components)
echo "Extracting component SHAs from snapshot..."

# Component list (component-name:variable-name format for zsh compatibility)
for COMPONENT_PAIR in \
  "submariner-operator-${VERSION_DASH}:submariner-operator" \
  "submariner-gateway-${VERSION_DASH}:submariner-gateway" \
  "submariner-route-agent-${VERSION_DASH}:submariner-routeagent" \
  "submariner-globalnet-${VERSION_DASH}:submariner-globalnet" \
  "lighthouse-agent-${VERSION_DASH}:submariner-lighthouse-agent" \
  "lighthouse-coredns-${VERSION_DASH}:submariner-lighthouse-coredns" \
  "nettest-${VERSION_DASH}:submariner-nettest"
do
  COMPONENT="${COMPONENT_PAIR%%:*}"
  VAR_NAME="${COMPONENT_PAIR##*:}"

  # Pipe directly from oc to jq (don't store JSON in variable)
  SHA=$(oc get snapshot "$SNAPSHOT" -n submariner-tenant -o json | \
    jq -r ".spec.components[] | select(.name==\"$COMPONENT\") | .containerImage" | \
    grep -oP 'sha256:\K[a-f0-9]+')

  if [ -z "$SHA" ]; then
    echo "❌ ERROR: Failed to extract SHA for component: $COMPONENT"
    exit 1
  fi

  eval "RELATED_IMAGE_${VAR_NAME//-/_}=sha256:$SHA"
  echo "  ✓ $VAR_NAME: ${SHA:0:12}..."
done

# Metrics-proxy uses same SHA as nettest
RELATED_IMAGE_submariner_metrics_proxy="$RELATED_IMAGE_submariner_nettest"
SHA_DISPLAY="${RELATED_IMAGE_submariner_nettest#sha256:}"
echo "  ✓ submariner-metrics-proxy: ${SHA_DISPLAY:0:12}... (same as nettest)"

# Save to state file
cat >> "$STATE_FILE" <<EOF
SNAPSHOT="$SNAPSHOT"
RELATED_IMAGE_submariner_operator="$RELATED_IMAGE_submariner_operator"
RELATED_IMAGE_submariner_gateway="$RELATED_IMAGE_submariner_gateway"
RELATED_IMAGE_submariner_routeagent="$RELATED_IMAGE_submariner_routeagent"
RELATED_IMAGE_submariner_globalnet="$RELATED_IMAGE_submariner_globalnet"
RELATED_IMAGE_submariner_lighthouse_agent="$RELATED_IMAGE_submariner_lighthouse_agent"
RELATED_IMAGE_submariner_lighthouse_coredns="$RELATED_IMAGE_submariner_lighthouse_coredns"
RELATED_IMAGE_submariner_nettest="$RELATED_IMAGE_submariner_nettest"
RELATED_IMAGE_submariner_metrics_proxy="$RELATED_IMAGE_submariner_metrics_proxy"
EOF

echo "✓ Extracted 7 component SHAs from snapshot"
```

---

## Step 2: Update Related Images Config

Update config file with new SHAs while preserving registry.redhat.io URLs.

```bash
#!/bin/bash
set -euo pipefail

# Navigate to repository
cd ~/go/src/submariner-io/submariner-operator || {
  echo "❌ ERROR: Repository not found at ~/go/src/submariner-io/submariner-operator"
  exit 1
}

# Detect version from branch to find correct state file
BRANCH=$(git rev-parse --abbrev-ref HEAD)
VERSION_DOT="${BRANCH#release-}"
VERSION_DASH="${VERSION_DOT//./-}"
STATE_FILE="/tmp/bundle-image-update-${VERSION_DASH}.txt"

if [ ! -f "$STATE_FILE" ]; then
  echo "❌ ERROR: State file not found: $STATE_FILE"
  echo "Did Step 1 complete successfully?"
  exit 1
fi
source "$STATE_FILE"

CONFIG_FILE="config/manager/patches/related-images.deployment.config.yaml"

# Check if config file exists (created by bundle setup)
if [ ! -f "$CONFIG_FILE" ]; then
  echo "❌ ERROR: $CONFIG_FILE not found"
  echo ""
  echo "This file is created by the bundle Konflux setup process."
  echo "The repository needs bundle infrastructure before updating SHAs."
  echo ""
  echo "Run bundle setup first: /konflux-bundle-setup ${VERSION_DOT}"
  exit 1
fi

echo "Updating $CONFIG_FILE..."

# Update each RELATED_IMAGE variable (preserve registry.redhat.io URL)
for VAR in submariner-operator submariner-gateway submariner-routeagent submariner-globalnet \
           submariner-lighthouse-agent submariner-lighthouse-coredns submariner-nettest \
           submariner-metrics-proxy; do

  VAR_NAME="RELATED_IMAGE_${VAR//-/_}"
  # Use eval for zsh compatibility (instead of bash-specific ${!VAR_NAME})
  NEW_SHA=$(eval echo "\$${VAR_NAME}")

  # Replace SHA256 digest while preserving registry.redhat.io URL
  # Range: from "name: RELATED_IMAGE_..." to next line with "value:"
  sed -i "/name: RELATED_IMAGE_${VAR}/,/value:/ s|@sha256:[a-f0-9]*|@${NEW_SHA}|" "$CONFIG_FILE"

  echo "  ✓ RELATED_IMAGE_${VAR}"
done

# Update container image field (uses operator SHA)
# This is a separate kustomize patch with "op: replace" and "path: .../containers/0/image"
sed -i "/path:.*\/containers\/.*\/image$/,/value:/ s|@sha256:[a-f0-9]*|@${RELATED_IMAGE_submariner_operator}|" "$CONFIG_FILE"
echo "  ✓ Container image (uses operator SHA)"

echo ""
echo "✓ Updated $CONFIG_FILE with 9 SHA references"
```

---

## Step 3: Generate Bundle

Regenerate bundle manifests with make bundle.

```bash
#!/bin/bash
set -euo pipefail

# Navigate to repository
cd ~/go/src/submariner-io/submariner-operator || {
  echo "❌ ERROR: Repository not found at ~/go/src/submariner-io/submariner-operator"
  exit 1
}

# Detect version from branch to find correct state file
BRANCH=$(git rev-parse --abbrev-ref HEAD)
VERSION_DOT="${BRANCH#release-}"
VERSION_DASH="${VERSION_DOT//./-}"
STATE_FILE="/tmp/bundle-image-update-${VERSION_DASH}.txt"

if [ ! -f "$STATE_FILE" ]; then
  echo "❌ ERROR: State file not found: $STATE_FILE"
  echo "Did Step 1 complete successfully?"
  exit 1
fi
source "$STATE_FILE"

echo "Regenerating bundle..."

# Check if bundle directory exists
if [ ! -d "bundle" ]; then
  echo "❌ ERROR: bundle/ directory not found"
  echo ""
  echo "The bundle directory is required for make bundle to work."
  echo "Run bundle setup first: /konflux-bundle-setup ${VERSION_DOT}"
  exit 1
fi

# Remove v prefix if present (Makefile regex requires X.Y.Z format without v)
VERSION_NO_V="${TARGET_VERSION#v}"

# Run make bundle with semantic version (triggers IS_SEMANTIC_VERSION=true in Makefile)
if make bundle LOCAL_BUILD=1 VERSION="$VERSION_NO_V"; then
  echo "✓ Bundle regenerated successfully"
else
  echo "❌ ERROR: make bundle failed"
  exit 1
fi
```

---

## Step 4: Update Dockerfile Labels

Update version labels in bundle.Dockerfile.konflux (version bumps only).

```bash
#!/bin/bash
set -euo pipefail

# Navigate to repository
cd ~/go/src/submariner-io/submariner-operator || {
  echo "❌ ERROR: Repository not found at ~/go/src/submariner-io/submariner-operator"
  exit 1
}

# Detect version from branch to find correct state file
BRANCH=$(git rev-parse --abbrev-ref HEAD)
VERSION_DOT="${BRANCH#release-}"
VERSION_DASH="${VERSION_DOT//./-}"
STATE_FILE="/tmp/bundle-image-update-${VERSION_DASH}.txt"

if [ ! -f "$STATE_FILE" ]; then
  echo "❌ ERROR: State file not found: $STATE_FILE"
  echo "Did Step 1 complete successfully?"
  exit 1
fi
source "$STATE_FILE"

if [ "$UPDATE_TYPE" = "version-bump" ]; then
  echo "Updating Dockerfile labels for version bump..."

  # Check if bundle.Dockerfile.konflux exists
  if [ ! -f "bundle.Dockerfile.konflux" ]; then
    echo "❌ ERROR: bundle.Dockerfile.konflux not found"
    echo ""
    echo "This file is created by the bundle Konflux setup process."
    echo "Run bundle setup first: /konflux-bundle-setup ${VERSION_DOT}"
    echo ""
    echo "Or skip version bump and update SHAs only (omit version argument)"
    exit 1
  fi

  VERSION_NO_V="${TARGET_VERSION#v}"  # Remove v prefix if present

  sed -i \
    -e "s/csv-version=\"[^\"]*\"/csv-version=\"$VERSION_NO_V\"/" \
    -e "s/release=\"v[^\"]*\"/release=\"v$VERSION_NO_V\"/" \
    -e "s/version=\"v[^\"]*\"/version=\"v$VERSION_NO_V\"/" \
    bundle.Dockerfile.konflux

  # Verify labels updated
  if grep -q "csv-version=\"$VERSION_NO_V\"" bundle.Dockerfile.konflux && \
     grep -q "release=\"v$VERSION_NO_V\"" bundle.Dockerfile.konflux && \
     grep -q "version=\"v$VERSION_NO_V\"" bundle.Dockerfile.konflux; then
    echo "  ✓ csv-version=\"$VERSION_NO_V\""
    echo "  ✓ release=\"v$VERSION_NO_V\""
    echo "  ✓ version=\"v$VERSION_NO_V\""
    echo "✓ Dockerfile labels updated"
  else
    echo "❌ ERROR: Failed to update Dockerfile labels"
    exit 1
  fi
else
  echo "ℹ️  SHA-only update - skipping Dockerfile label update"
fi
```

---

## Step 5: Verify Changes

Verify all SHAs match snapshot and validate YAML.

```bash
#!/bin/bash
set -euo pipefail

# Navigate to repository
cd ~/go/src/submariner-io/submariner-operator || {
  echo "❌ ERROR: Repository not found at ~/go/src/submariner-io/submariner-operator"
  exit 1
}

# Detect version from branch to find correct state file
BRANCH=$(git rev-parse --abbrev-ref HEAD)
VERSION_DOT="${BRANCH#release-}"
VERSION_DASH="${VERSION_DOT//./-}"
STATE_FILE="/tmp/bundle-image-update-${VERSION_DASH}.txt"

if [ ! -f "$STATE_FILE" ]; then
  echo "❌ ERROR: State file not found: $STATE_FILE"
  echo "Did Step 1 complete successfully?"
  exit 1
fi
source "$STATE_FILE"

echo "=== Verifying SHAs match snapshot $SNAPSHOT ==="

ERRORS=0

# Verify each component SHA matches between snapshot and bundle CSV
# Component list (component-name:variable-name format for zsh compatibility)
for COMPONENT_PAIR in \
  "submariner-operator-${VERSION_DASH}:RELATED_IMAGE_submariner-operator" \
  "submariner-gateway-${VERSION_DASH}:RELATED_IMAGE_submariner-gateway" \
  "submariner-route-agent-${VERSION_DASH}:RELATED_IMAGE_submariner-routeagent" \
  "submariner-globalnet-${VERSION_DASH}:RELATED_IMAGE_submariner-globalnet" \
  "lighthouse-agent-${VERSION_DASH}:RELATED_IMAGE_submariner-lighthouse-agent" \
  "lighthouse-coredns-${VERSION_DASH}:RELATED_IMAGE_submariner-lighthouse-coredns" \
  "nettest-${VERSION_DASH}:RELATED_IMAGE_submariner-nettest"
do
  COMPONENT="${COMPONENT_PAIR%%:*}"
  VAR_NAME="${COMPONENT_PAIR##*:}"

  # Get SHA from snapshot (source of truth, pipe directly)
  SNAPSHOT_SHA=$(oc get snapshot "$SNAPSHOT" -n submariner-tenant -o json | \
    jq -r ".spec.components[] | select(.name==\"$COMPONENT\") | .containerImage" | \
    grep -o 'sha256:[a-f0-9]*')

  # Get SHA from bundle CSV (what we generated)
  BUNDLE_SHA=$(grep -A1 "name: $VAR_NAME" bundle/manifests/submariner.clusterserviceversion.yaml \
    | grep "value:" | grep -o 'sha256:[a-f0-9]*')

  # Verify both SHAs present and matching
  if [ -z "$SNAPSHOT_SHA" ] || [ -z "$BUNDLE_SHA" ]; then
    echo "✗ $COMPONENT: MISSING SHA!"
    echo "  Snapshot: ${SNAPSHOT_SHA:-<empty>}"
    echo "  Bundle:   ${BUNDLE_SHA:-<empty>}"
    ((ERRORS++))
  elif [ "$SNAPSHOT_SHA" = "$BUNDLE_SHA" ]; then
    echo "✓ $COMPONENT"
  else
    echo "✗ $COMPONENT: MISMATCH!"
    echo "  Snapshot: $SNAPSHOT_SHA"
    echo "  Bundle:   $BUNDLE_SHA"
    ((ERRORS++))
  fi
done

# Verify metrics-proxy uses nettest SHA (special case: same image, pipe directly)
NETTEST_SHA=$(oc get snapshot "$SNAPSHOT" -n submariner-tenant -o json | \
  jq -r ".spec.components[] | select(.name==\"nettest-${VERSION_DASH}\") | .containerImage" | \
  grep -o 'sha256:[a-f0-9]*')
METRICS_SHA=$(grep -A1 "name: RELATED_IMAGE_submariner-metrics-proxy" bundle/manifests/submariner.clusterserviceversion.yaml \
  | grep "value:" | grep -o 'sha256:[a-f0-9]*')

if [ -z "$NETTEST_SHA" ] || [ -z "$METRICS_SHA" ]; then
  echo "✗ metrics-proxy: MISSING SHA!"
  echo "  Expected (nettest): ${NETTEST_SHA:-<empty>}"
  echo "  Bundle:             ${METRICS_SHA:-<empty>}"
  ((ERRORS++))
elif [ "$NETTEST_SHA" = "$METRICS_SHA" ]; then
  echo "✓ metrics-proxy (uses nettest SHA)"
else
  echo "✗ metrics-proxy: MISMATCH!"
  echo "  Expected (nettest): $NETTEST_SHA"
  echo "  Bundle:             $METRICS_SHA"
  ((ERRORS++))
fi

echo ""

# Final result
if [ $ERRORS -eq 0 ]; then
  echo "✅ All SHAs verified - bundle matches snapshot!"
else
  echo "❌ VERIFICATION FAILED - $ERRORS mismatches found!"
  echo "DO NOT COMMIT. Review and fix SHA mismatches above."
  exit 1
fi

echo ""

# Validate YAML
echo "Validating YAML..."
if make yamllint; then
  echo "✓ YAML validation passed"
else
  echo "❌ YAML validation failed"
  exit 1
fi
```

---

## Step 6: Commit Changes

Create signed commit with all changes.

```bash
#!/bin/bash
set -euo pipefail

# Navigate to repository
cd ~/go/src/submariner-io/submariner-operator || {
  echo "❌ ERROR: Repository not found at ~/go/src/submariner-io/submariner-operator"
  exit 1
}

# Detect version from branch to find correct state file
BRANCH=$(git rev-parse --abbrev-ref HEAD)
VERSION_DOT="${BRANCH#release-}"
VERSION_DASH="${VERSION_DOT//./-}"
STATE_FILE="/tmp/bundle-image-update-${VERSION_DASH}.txt"

if [ ! -f "$STATE_FILE" ]; then
  echo "❌ ERROR: State file not found: $STATE_FILE"
  echo "Did Step 1 complete successfully?"
  exit 1
fi
source "$STATE_FILE"

echo "Creating commit..."

# Stage all bundle-related changes
git add config/manager/patches/related-images.deployment.config.yaml \
        bundle/ \
        config/bundle/kustomization.yaml \
        config/manifests/kustomization.yaml

# Stage Dockerfile and version-bumped files
if [ "$UPDATE_TYPE" = "version-bump" ]; then
  git add bundle.Dockerfile.konflux
fi

# Generate commit message based on update type
if [ "$UPDATE_TYPE" = "version-bump" ]; then
  COMMIT_MSG="Update bundle to $TARGET_VERSION

Updates container image SHAs to match Konflux snapshot.

Snapshot: $SNAPSHOT"
else
  COMMIT_MSG="Update bundle SHAs to latest

Updates container image SHAs to match Konflux snapshot.

Snapshot: $SNAPSHOT"
fi

# Create commit
git commit -s -m "$COMMIT_MSG"

echo "✓ Commit created"
```

---

## Step 7: Summary and Next Steps

Display summary, clean up state file, and show next steps.

```bash
#!/bin/bash
set -euo pipefail

# Navigate to repository
cd ~/go/src/submariner-io/submariner-operator || {
  echo "❌ ERROR: Repository not found at ~/go/src/submariner-io/submariner-operator"
  exit 1
}

# Detect version from branch to find correct state file
BRANCH=$(git rev-parse --abbrev-ref HEAD)
VERSION_DOT="${BRANCH#release-}"
VERSION_DASH="${VERSION_DOT//./-}"
STATE_FILE="/tmp/bundle-image-update-${VERSION_DASH}.txt"

if [ ! -f "$STATE_FILE" ]; then
  echo "❌ ERROR: State file not found: $STATE_FILE"
  echo "Did Step 1 complete successfully?"
  exit 1
fi
source "$STATE_FILE"

# Ensure cleanup on exit
trap 'rm -f "$STATE_FILE"' EXIT

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Bundle Image Update Complete"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📝 Summary:"
echo "   Update type: $UPDATE_TYPE"
echo "   Version: $CURRENT_VERSION → $TARGET_VERSION"
echo "   Snapshot: $SNAPSHOT"
echo "   Branch: $BRANCH"
echo ""
echo "📋 Commit created:"
git log -1 --oneline
echo ""
echo "📊 Files modified:"
git diff --stat HEAD~1
echo ""
echo "🚀 Next steps:"
echo "   1. Review changes: git show"
echo "   2. Push: git push origin $BRANCH"
echo "   3. Wait for bundle rebuild (~15-30 min)"
echo "   4. Verify: oc get snapshots -n submariner-tenant | grep submariner-bundle-${VERSION_DASH}"
echo ""
```
