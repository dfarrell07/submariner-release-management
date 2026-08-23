#!/bin/bash
# Derive which OCP versions a release actually targeted.
#
# FBC release YAML filenames don't carry the Submariner version (catalogs are
# cumulative across versions), so the only signal for "which OCP versions did
# THIS release ship to" is date proximity: the FBC releases are cut right after
# the component release succeeds, so their filename dates cluster around the
# latest component YAML for the version. Anchoring on the LATEST component YAML
# (sort | tail -1) picks the successful release, not an earlier failed retry.
#
# Pure filesystem reads, no network — unit-testable against a fixture tree.
#
# Sourced by autorelease.sh (auto-close scope), release-status.sh
# (get_release_ocp_scope wrapper), and test-fbc-scope.sh.

# Guard against double-sourcing.
[ -n "${_FBC_SCOPE_SOURCED:-}" ] && return 0
_FBC_SCOPE_SOURCED=1

# ±3 days: the window between a component release and its FBC releases. Override
# for tests via the environment; callers normally take the default.
: "${FBC_DATE_MATCH_WINDOW_SECS:=259200}"

# Supported OCP minors, newest last. The candidate set callers pass to
# get_fbc_ocp_scope; kept here so the FBC OCP range lives in one place.
# Tests may override by exporting FBC_OCP_VERSIONS *before* sourcing this file.
# Once set (from env or the default), pinned readonly to catch mid-session mutations.
: "${FBC_OCP_VERSIONS:=16 17 18 19 20 21 22}"
readonly FBC_OCP_VERSIONS

# get_fbc_ocp_scope <root> <major_minor> <full_version_dash> <env> <ocp_list>
#   root              repo root (the directory that contains releases/)
#   major_minor       Y-stream with dots, e.g. 0.24
#   full_version_dash full version with dashes, e.g. 0-24-1
#   env               stage | prod
#   ocp_list          space-separated OCP minors to consider, e.g. "16 17 ... 22"
# Echoes space-separated OCP minors this release targeted (e.g. "19 20 21 22"),
# or empty when undeterminable: no component YAML, an unparseable date, or no FBC
# YAML within the window. Empty means "don't know" — callers must treat it as a
# reason to hold off, never as "targeted nothing".
get_fbc_ocp_scope() {
  local root="$1" mm="$2" fvd="$3" env="$4" ocp_list="$5"
  local versions=""

  # Anchor the date window on the successful component release (latest attempt).
  local component_yaml
  component_yaml=$(find "$root/releases/$mm/$env/" -name "submariner-$fvd-$env-*.yaml" 2>/dev/null | sort | tail -1)
  [ -z "$component_yaml" ] && return

  local component_date_str component_epoch
  component_date_str=$(basename "$component_yaml" | grep -oP '\d{8}')
  component_epoch=$(date -d "$component_date_str" +%s 2>/dev/null || echo 0)
  [ "$component_epoch" -eq 0 ] && return

  local ocp_version yaml fbc_date_str fbc_epoch date_diff date_diff_abs
  for ocp_version in $ocp_list; do
    for yaml in "$root"/releases/fbc/4-"$ocp_version"/"$env"/*.yaml; do
      [ ! -f "$yaml" ] && continue

      fbc_date_str=$(basename "$yaml" | grep -oP '\d{8}')
      fbc_epoch=$(date -d "$fbc_date_str" +%s 2>/dev/null || echo 0)
      [ "$fbc_epoch" -eq 0 ] && continue

      date_diff=$((fbc_epoch - component_epoch))
      date_diff_abs=${date_diff#-}  # abs value

      if [ "$date_diff_abs" -le "$FBC_DATE_MATCH_WINDOW_SECS" ]; then
        versions="$versions $ocp_version"
        break  # this OCP version is in scope; move to the next
      fi
    done
  done

  echo "$versions" | xargs  # trim whitespace
}
