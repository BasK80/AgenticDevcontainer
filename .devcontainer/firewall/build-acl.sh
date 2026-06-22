#!/usr/bin/env bash
# build-acl.sh — emit the merged set of allowed domains (one per line, comments
# stripped, NOT sorted/deduped) to stdout. The caller prepends the
# "invalid.invalid" placeholder and pipes through `sort -u`.
#
# Layers, in order: baseline -> enabled features (transitively dep-closed)
# -> manual permanent (allowlist.acl.perm) -> ttl (ttl.tsv domain column).
#
# Scans both built-in definitions ($DEFS) and user-created definitions
# ($USER_DEFS) for feature .list files.
#
# Reads only; never mutates policy. Paths overridable via env for testing.
set -uo pipefail

POLICY="${POLICY_DIR:-/policy}"
DEFS="${FEATURE_DEFS:-$POLICY/features.defs}"
USER_DEFS="${USER_FEATURE_DEFS:-$POLICY/features.d}"
STATE="${FEATURE_STATE:-$POLICY/features.state}"
PERM="${PERM_FILE:-$POLICY/allowlist.acl.perm}"
TTL="${TTL_FILE:-$POLICY/ttl.tsv}"

# Resolve a feature .list file path (checks built-in first, then user).
_feat_file() {
  if [ -f "$DEFS/$1.list" ]; then
    echo "$DEFS/$1.list"
  elif [ -f "$USER_DEFS/$1.list" ]; then
    echo "$USER_DEFS/$1.list"
  fi
}

# Domains of a feature (comments + blank lines stripped).
_feat_domains() {
  local f
  f="$(_feat_file "$1")"
  [ -n "$f" ] && grep -vE '^[[:space:]]*(#|$)' "$f" 2>/dev/null
  return 0
}

# Space-separated dependencies declared in a feature's "# depends:" header.
_feat_deps() {
  local f
  f="$(_feat_file "$1")"
  [ -n "$f" ] && sed -n 's/^#[[:space:]]*depends:[[:space:]]*//p' "$f" 2>/dev/null | tr ',' ' '
  return 0
}

# Features explicitly turned on in the state file.
_enabled() {
  [ -f "$STATE" ] || return 0
  grep -E '^[A-Za-z0-9_-]+=on$' "$STATE" 2>/dev/null | sed 's/=on$//'
  return 0
}

# Transitive closure of enabled features over their dependencies.
declare -A _seen=()
_queue="$(_enabled)"
_closure=""
while [ -n "${_queue// }" ]; do
  _next=""
  for _f in $_queue; do
    [ -n "${_seen[$_f]:-}" ] && continue
    # Only real features (a definition file must exist in either dir).
    _ff="$(_feat_file "$_f")"
    [ -z "$_ff" ] && continue
    _seen[$_f]=1
    _closure="$_closure $_f"
    _next="$_next $(_feat_deps "$_f")"
  done
  _queue="$_next"
done

# Emit layers.
_feat_domains _baseline
for _f in $_closure; do
  _feat_domains "$_f"
done
[ -f "$PERM" ] && grep -vE '^[[:space:]]*(#|$)' "$PERM" 2>/dev/null
[ -s "$TTL" ]  && cut -f2 "$TTL" 2>/dev/null
exit 0
