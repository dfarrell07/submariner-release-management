#!/usr/bin/env bash
# Preparation is isolated, resumable, and never commits, pushes, or applies.
set -euo pipefail
exec python3 "$(dirname "${BASH_SOURCE[0]}")/fbc-onboard.py" "$@"
