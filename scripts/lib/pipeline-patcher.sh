#!/bin/bash
# Shared helper: download and verify the konflux-pipeline-patcher script.
#
# Sourced by konflux-component-setup.sh and konflux-bundle-setup.sh, which both
# run `pipeline-patcher bump-task-refs` to refresh Tekton task references. The
# pinned commit and its checksum live here so a patcher bump is a one-line edit
# in a single place — previously they were duplicated in both scripts and had
# drifted (one hardened the curl download, the other had not).
#
# This file is meant to be sourced, not executed.

# Pinned upstream commit of simonbaird/konflux-pipeline-patcher and the sha256
# of the pipeline-patcher script at that commit. Bump both together.
PATCHER_SHA="b001763bb1cd0286a894cfb570fe12dd7f4504bd"
EXPECTED_SHA256="080ad5d7cf7d0cee732a774b7e4dda0e2ccf26b58e08a8516a3b812bc73beb53"

# Download the pinned pipeline-patcher script, verify its sha256, and print the
# verified script to stdout for the caller to pipe into `bash -s`. All
# diagnostics go to stderr; on any download or checksum failure this returns
# non-zero with empty stdout, so callers can write:
#
#   SCRIPT=$(download_and_verify_patcher) || die "..."
#
download_and_verify_patcher() {
  local script actual

  # -f: fail on HTTP errors (404/500) instead of capturing an error page, which
  # would otherwise flow into checksum verification as a misleading mismatch.
  script=$(curl -fsL "https://raw.githubusercontent.com/simonbaird/konflux-pipeline-patcher/${PATCHER_SHA}/pipeline-patcher") || {
    echo "Failed to download pipeline-patcher (check network / GitHub access)" >&2
    return 1
  }

  if [ -z "$script" ]; then
    echo "Downloaded pipeline-patcher script is empty" >&2
    return 1
  fi

  # echo (not printf) so the trailing newline matches how EXPECTED_SHA256 was
  # computed; changing this would invalidate the pinned checksum.
  if command -v sha256sum &>/dev/null; then
    actual=$(echo "$script" | sha256sum | cut -d' ' -f1)
  else
    actual=$(echo "$script" | shasum -a 256 | cut -d' ' -f1)
  fi

  if [ "$actual" != "$EXPECTED_SHA256" ]; then
    echo "Pipeline patcher checksum mismatch!" >&2
    echo "   Expected: $EXPECTED_SHA256" >&2
    echo "   Actual:   $actual" >&2
    echo "Security verification failed. Not executing downloaded script." >&2
    return 1
  fi

  # Command substitution in the caller strips the trailing newline either way,
  # so printf keeps the emitted bytes identical to the verified script.
  printf '%s' "$script"
}
