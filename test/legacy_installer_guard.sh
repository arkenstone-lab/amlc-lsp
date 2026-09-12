#!/usr/bin/env sh
set -eu

installer=$1
shell=$(command -v sh)
# A regressed guard must not get as far as downloading or installing anything.
if output=$(env -u AMLC_LSP_LEGACY_TOOLS -u PREFIX PATH= "$shell" "$installer" 2>&1); then
  printf '%s\n' 'legacy installer ran without opt-in' >&2
  exit 1
fi
case "$output" in
  *'Legacy helper only.'*) ;;
  *) printf '%s\n' "$output" >&2; exit 1 ;;
esac

if output=$(env -u PREFIX AMLC_LSP_LEGACY_TOOLS=1 PATH= "$shell" "$installer" 2>&1); then
  printf '%s\n' 'legacy installer ran without an explicit prefix' >&2
  exit 1
fi
case "$output" in
  *'Set PREFIX to a dedicated legacy test installation directory'*) ;;
  *) printf '%s\n' "$output" >&2; exit 1 ;;
esac
