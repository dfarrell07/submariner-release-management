#!/usr/bin/env bash
# Submariner to ACM version mapping, shared by the setup, release-notes and
# tracker scripts. This is the only place that should do this math.
[ -n "${_ACM_VERSION_SOURCED:-}" ] && return 0
_ACM_VERSION_SOURCED=1

# Prints the ACM version (X.Y) for a Submariner 0.Y or 0.Y.Z release.
# Once a new release's ACM version is confirmed, add a row for it.
acm_version_for() {
  local minor
  if [[ ! "${1:-}" =~ ^0\.([0-9]+)(\.[0-9]+)?$ ]]; then
    echo "❌ ERROR: Invalid Submariner version '${1:-}' (expected 0.Y or 0.Y.Z)" >&2
    return 1
  fi
  minor=$((10#${BASH_REMATCH[1]}))
  case "$minor" in
    [7-9] | 1[0-9] | 2[0-4]) echo "2.$((minor - 7))" ;;
    25) echo "5.0" ;; # not 2.18: the 0.25 RPA has product_version "5.0"
    [0-6])
      echo "❌ ERROR: No ACM version for Submariner $1 (minimum is 0.7, ACM 2.0)" >&2
      return 1
      ;;
    *)
      echo "❌ ERROR: No ACM version recorded for Submariner $1." >&2
      echo "   Confirm the ACM release with the release owner (don't guess it), then add" >&2
      echo "   a row for $minor to acm_version_for in scripts/lib/acm-version.sh." >&2
      return 1
      ;;
  esac
}

# Sets the ACM CPE label in a Dockerfile and checks the result.
# Args: $1=file $2=ACM version (for example 5.0)
acm_set_cpe() {
  local file="$1" acm="$2"
  sed -i -E "s|cpe=\"cpe:/a:redhat:acm:[0-9.]*::el9\"|cpe=\"cpe:/a:redhat:acm:${acm}::el9\"|" "$file" || return 1
  grep -qF "cpe=\"cpe:/a:redhat:acm:${acm}::el9\"" "$file"
}
