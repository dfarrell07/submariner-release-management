#!/usr/bin/env bash
# Seal the team's shared Red Hat credentials into secrets/entitlements.asc.
#
# Usage: seal-entitlements.sh [--new-password]
#
# Run by whoever holds the shared org ID and activation key: the first time,
# and again whenever the key changes. Everyone else just runs
# `make setup-entitlements`.
#
# Prompts for the org ID and activation key. Optionally seals a shared
# registry.redhat.io login too (otherwise each person logs in themselves).
#
# Password: reuses the existing team password (ENTITLEMENT_PASSWORD or the one
# saved on this machine) so a key rotation needs nothing from teammates but
# `git pull`. Otherwise, or with --new-password, generates a new 64-character
# random one and shows it once for you to share.
#
# Non-interactive: RH_ORG, RH_ACTIVATION_KEY, optionally RH_REGISTRY_USER and
# RH_REGISTRY_PASSWORD.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/entitlement-bundle.sh
source "$SCRIPT_DIR/lib/entitlement-bundle.sh"

die() { echo "❌ $1" >&2; [ -n "${2:-}" ] && echo "$2" >&2; exit 1; }

single_line() { # name value
  case "$2" in
    *$'\n'* | *$'\r'*) die "$1 must be a single line" ;;
  esac
}

main() {
  local new_password=false arg
  for arg in "$@"; do
    case "$arg" in
      --new-password) new_password=true ;;
      -h | --help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
      *) echo "Unknown option: $arg (see --help)" >&2; exit 2 ;;
    esac
  done
  command -v gpg &>/dev/null || die "gpg not found" "Install GnuPG (Fedora/RHEL: sudo dnf install gnupg2)"

  local org="${RH_ORG:-}" key="${RH_ACTIVATION_KEY:-}"
  local ruser="${RH_REGISTRY_USER:-}" rpass="${RH_REGISTRY_PASSWORD:-}"
  if [ -z "$org" ] || [ -z "$key" ]; then
    [ -t 0 ] || die "No terminal to prompt on" "Set RH_ORG and RH_ACTIVATION_KEY, or run this from a terminal."
    read -r -p "Shared Red Hat org ID: " org
    read -r -s -p "Shared activation key name (input hidden): " key
    echo
    read -r -p "Shared registry.redhat.io username (Enter to skip): " ruser
    if [ -n "$ruser" ]; then read -r -s -p "  password (input hidden): " rpass; echo; fi
  fi
  [ -n "$org" ] && [ -n "$key" ] || die "Org ID and activation key are both required"
  if [ -n "$ruser" ] || [ -n "$rpass" ]; then
    [ -n "$ruser" ] && [ -n "$rpass" ] || die "Registry username and password must be given together"
  fi
  single_line "Org ID" "$org"; single_line "Activation key" "$key"
  single_line "Registry username" "$ruser"; single_line "Registry password" "$rpass"

  local password="" generated=false
  if ! $new_password; then password="${ENTITLEMENT_PASSWORD:-$(cached_password)}"; fi
  if [ -n "$password" ]; then
    [ "${#password}" -ge "$MIN_PASSWORD_LEN" ] ||
      die "Team password is too short (need >= $MIN_PASSWORD_LEN characters)" \
        "Use --new-password to generate a strong one."
  else
    password=$(openssl rand -base64 48 | tr -d '\n')
    generated=true
  fi

  local plain
  plain=$(printf 'RH_ORG=%s\nRH_ACTIVATION_KEY=%s\n' "$org" "$key")
  if [ -n "$ruser" ]; then
    plain+=$(printf '\nRH_REGISTRY_USER=%s\nRH_REGISTRY_PASSWORD=%s' "$ruser" "$rpass")
  fi

  mkdir -p "$(dirname "$BUNDLE_FILE")"
  printf '%s\n' "$plain" | bundle_encrypt "$password" "$BUNDLE_FILE.tmp" ||
    { rm -f "$BUNDLE_FILE.tmp"; die "Encryption failed"; }
  # Verify before replacing: decrypt and compare.
  [ "$(bundle_decrypt "$password" "$BUNDLE_FILE.tmp")" = "$plain" ] ||
    { rm -f "$BUNDLE_FILE.tmp"; die "Verification failed; existing bundle left untouched"; }
  mv "$BUNDLE_FILE.tmp" "$BUNDLE_FILE"

  echo "✓ Sealed $BUNDLE_FILE"
  if $generated; then
    save_password "$password"
    cat <<MSG

New team password (shown once; also saved on this machine):

    $password

Give it to each teammate through your password manager. It is 64 random
characters; do not paste it into tickets or commit it. Teammates enter it
once on their first \`make setup-entitlements\`.
MSG
  else
    echo "  Reused the existing team password: teammates only need \`git pull\`."
  fi
  echo
  echo "Next: git add ${BUNDLE_FILE#"$PWD"/} && git commit -s -m 'Update entitlement bundle'"
}

main "$@"
