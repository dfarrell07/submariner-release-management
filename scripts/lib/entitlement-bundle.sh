#!/usr/bin/env bash
# Helpers for the team entitlement bundle: the shared Red Hat org ID and
# activation key, sealed with GnuPG symmetric encryption (AES-256, iterated
# and salted SHA-512 key derivation, integrity-protected) and committed as
# secrets/entitlements.asc. One long random team password opens it.
#
# Sourced by setup-entitlements.sh and seal-entitlements.sh.
# Test hooks: ENTITLEMENT_BUNDLE, ENTITLEMENT_PASSWORD, XDG_CONFIG_HOME.

# shellcheck disable=SC2034  # variables are consumed by the scripts that source this
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_FILE="${ENTITLEMENT_BUNDLE:-$(cd "$_LIB_DIR/../.." && pwd)/secrets/entitlements.asc}"
PASSWORD_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/submariner-release-management/entitlement-password"
MIN_PASSWORD_LEN=43 # ~256 bits of base64

# Bundle fields we accept. Anything else in the file is ignored.
BUNDLE_KEYS="RH_ORG RH_ACTIVATION_KEY RH_REGISTRY_USER RH_REGISTRY_PASSWORD"

# Run gpg against a throwaway keyring so we never touch the user's own.
_gpg() {
  local home rc=0
  home=$(mktemp -d) || return 1
  GNUPGHOME="$home" gpg --batch --quiet --no-tty --pinentry-mode loopback "$@" || rc=$?
  rm -rf "$home"
  return "$rc"
}

# bundle_encrypt PASSWORD OUTFILE  (plaintext on stdin)
bundle_encrypt() {
  _gpg --passphrase-file <(printf '%s' "$1") --symmetric --armor \
    --cipher-algo AES256 --s2k-mode 3 --s2k-digest-algo SHA512 \
    --s2k-count 65011712 --compress-algo none -o "$2"
}

# bundle_decrypt PASSWORD FILE  (plaintext on stdout; stderr silenced)
bundle_decrypt() {
  _gpg --passphrase-file <(printf '%s' "$1") --decrypt "$2" 2>/dev/null
}

cached_password() {
  [ -s "$PASSWORD_FILE" ] && cat "$PASSWORD_FILE"
  return 0
}

save_password() {
  local dir
  dir=$(dirname "$PASSWORD_FILE")
  mkdir -p "$dir" && chmod 700 "$dir"
  (umask 077 && printf '%s' "$1" > "$PASSWORD_FILE")
}

# parse_bundle: read plaintext on stdin, export the allowed KEY=VALUE pairs
# as BUNDLE_<KEY>. Never evaluated as shell.
parse_bundle() {
  local line k v
  while IFS= read -r line || [ -n "$line" ]; do
    k=${line%%=*}
    v=${line#*=}
    case " $BUNDLE_KEYS " in
      *" $k "*) printf -v "BUNDLE_$k" '%s' "$v" ;;
    esac
  done
}
