#!/usr/bin/env bash
# Full identities are used in paths and resource names: 4-22, 5-0.
[ -n "${_OCP_VERSION_SOURCED:-}" ] && return 0
_OCP_VERSION_SOURCED=1

ocp_normalize() {
  local value="${1:-}"
  # Retain the historical minor-only API for external callers.
  [[ "$value" =~ ^[0-9]+$ ]] && value="4-$value"
  value="${value//./-}"
  if [[ ! "$value" =~ ^([1-9][0-9]*)-(0|[1-9][0-9]*)$ ]]; then
    echo "Invalid OCP version: ${1:-<empty>} (expected major.minor or major-minor)" >&2
    return 1
  fi
  printf '%s\n' "$value"
}

ocp_dot() {
  local value
  value=$(ocp_normalize "$1") || return
  printf '%s\n' "${value//-/.}"
}

ocp_sort() { sort -u -t- -k1,1n -k2,2n; }

ocp_list_normalize() {
  local value canonical normalized=()
  for value in $1; do
    canonical=$(ocp_normalize "$value") || return
    normalized+=("$canonical")
  done
  [ "${#normalized[@]}" -gt 0 ] || return 1
  printf '%s\n' "${normalized[@]}" | ocp_sort | xargs
}
