#!/usr/bin/env bash
# Exact release records take precedence over the historical date heuristic.
[ -n "${_FBC_SCOPE_SOURCED:-}" ] && return 0
_FBC_SCOPE_SOURCED=1
# shellcheck source=ocp-version.sh
source "$(dirname "${BASH_SOURCE[0]}")/ocp-version.sh"
: "${FBC_DATE_MATCH_WINDOW_SECS:=259200}"
# Syntax support does not activate a catalog. Add 5-0 after onboarding is verified.
: "${FBC_OCP_VERSIONS:=4-16 4-17 4-18 4-19 4-20 4-21 4-22}"
FBC_OCP_VERSIONS=$(ocp_list_normalize "$FBC_OCP_VERSIONS") || return 1
readonly FBC_OCP_VERSIONS

# get_fbc_ocp_scope <root> <sub-major.minor> <full-version-dash> <env> <ocp-list>
# Outputs full IDs. Empty means unknown, never proof of an empty release scope.
get_fbc_ocp_scope() {
  local root="$1" mm="$2" fvd="$3" env="$4" candidates
  candidates=$(ocp_list_normalize "$5") || return
  local ocp yaml component epoch=0 fbc_epoch diff
  local versions=()
  component=$(find "$root/releases/$mm/$env/" -name "submariner-$fvd-$env-*.yaml" 2>/dev/null | sort | tail -1) || true
  if [[ "${component##*/}" =~ -([0-9]{8})-[0-9]+\.yaml$ ]]; then
    epoch=$(date -d "${BASH_REMATCH[1]}" +%s 2>/dev/null) || epoch=0
  fi
  for ocp in $candidates; do
    for yaml in "$root/releases/fbc/$ocp/$env/submariner-fbc-$ocp-$fvd-$env-"*.yaml; do
      if [ -f "$yaml" ]; then versions+=("$ocp"); break; fi
    done
    [[ " ${versions[*]} " == *" $ocp "* ]] && continue
    [ "$epoch" -gt 0 ] || continue
    # Never attribute a modern record for a different release by date proximity.
    for yaml in "$root/releases/fbc/$ocp/$env/submariner-fbc-$ocp-$env-"*.yaml; do
      [ -f "$yaml" ] || continue
      [[ "${yaml##*/}" =~ -([0-9]{8})-[0-9]+\.yaml$ ]] || continue
      fbc_epoch=$(date -d "${BASH_REMATCH[1]}" +%s 2>/dev/null) || continue
      diff=$((fbc_epoch - epoch))
      if [ "${diff#-}" -le "$FBC_DATE_MATCH_WINDOW_SECS" ]; then
        versions+=("$ocp"); break
      fi
    done
  done
  echo "${versions[*]}"
}
