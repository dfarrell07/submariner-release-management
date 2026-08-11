#!/bin/bash
# Create a Jira release tracker for a Submariner release
# Creates a parent Task with 15-18 Sub-task children (one per workflow step)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/jira-tracker.sh
source "$SCRIPT_DIR/lib/jira-tracker.sh"

# Parse arguments
VERSION=""
RELEASE_TYPE=""
QE_ASSIGNEE=""
DRY_RUN=false

usage() {
  echo "Usage: $0 <version> [options]"
  echo ""
  echo "Create a Jira release tracker for Submariner."
  echo ""
  echo "Arguments:"
  echo "  version              Submariner version (X.Y or X.Y.Z, e.g., 0.24 or 0.24.0)"
  echo ""
  echo "Options:"
  echo "  --y-stream           Force Y-stream (18 subtasks including branch setup)"
  echo "  --z-stream           Force Z-stream (15 subtasks, no branch setup)"
  echo "  --qe-assignee EMAIL  Assign QE testing subtask to this user"
  echo "  --dry-run            Print what would be created without creating anything"
  echo "                       (still does a read-only Jira check for an existing tracker)"
  echo "  --help               Show this help"
  echo ""
  echo "Examples:"
  echo "  $0 0.24.0                              # Auto-detect Y-stream"
  echo "  $0 0.24.1                              # Auto-detect Z-stream"
  echo "  $0 0.24.0 --qe-assignee qe@redhat.com  # Assign QE subtask"
  echo "  $0 0.24.0 --dry-run                    # Preview without creating"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --y-stream) RELEASE_TYPE="y-stream"; shift ;;
    --z-stream) RELEASE_TYPE="z-stream"; shift ;;
    --qe-assignee)
      [ $# -lt 2 ] && { echo "ERROR: --qe-assignee requires a value" >&2; exit 1; }
      QE_ASSIGNEE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --help|-h) usage; exit 0 ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      if [ -z "$VERSION" ]; then
        VERSION="$1"
      else
        echo "Unexpected argument: $1" >&2
        usage >&2
        exit 1
      fi
      shift
      ;;
  esac
done

if [ -z "$VERSION" ]; then
  echo "ERROR: Version argument required" >&2
  echo "" >&2
  usage >&2
  exit 1
fi

# Auto-expand 2-segment version (0.24 → 0.24.0)
if echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+$'; then
  VERSION="${VERSION}.0"
  echo "ℹ️  Expanded version to $VERSION" >&2
fi

# Validate version format before auth check
if ! echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "❌ Invalid version format: $VERSION" >&2
  echo "   Expected: X.Y or X.Y.Z (e.g., 0.24 or 0.24.0)" >&2
  exit 1
fi

# Set dry-run mode
if [ "$DRY_RUN" = "true" ]; then
  export JIRA_TRACKER_DRY_RUN=true
fi

# Verify Jira authentication. Required even for --dry-run: the idempotency
# check performs a read-only Jira query for an existing tracker, so without
# auth dry-run would fail deep inside with a cryptic "Could not query Jira"
# instead of this clear, upfront message.
if ! acli jira auth status </dev/null 2>/dev/null | grep -qi "authenticated\|Logged in"; then
  echo "❌ Not authenticated to Jira" >&2
  echo "   Run: acli jira auth login --web" >&2
  exit 1
fi

# Create the tracker
PARENT_KEY=$(create_release_tracker "$VERSION" "$RELEASE_TYPE" "$QE_ASSIGNEE")

if [ -n "$PARENT_KEY" ]; then
  echo "" >&2
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
  echo "Release tracker ready: $PARENT_KEY" >&2
  echo "  https://issues.redhat.com/browse/$PARENT_KEY" >&2
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
  echo "$PARENT_KEY"
fi
