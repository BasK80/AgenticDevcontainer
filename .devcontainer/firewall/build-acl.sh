#!/usr/bin/env bash
# build-acl.sh — emit the merged set of allowed domains (one per line, comments
# stripped, NOT sorted/deduped) to stdout. The caller prepends the
# "invalid.invalid" placeholder and pipes through `sort -u`.
#
# Layers, in order: baseline -> enabled features (transitively dep-closed)
# -> manual permanent (allowlist.acl.perm) -> ttl (ttl.tsv domain column).
#
# Reads only; never mutates policy. Paths overridable via env for testing.
set -uo pipefail

POLICY="${POLICY_DIR:-/policy}"
DEFS="${FEATURE_DEFS:-$POLICY/features.defs}"
STATE="${FEATURE_STATE:-$POLICY/features.state}"
PERM="${PERM_FILE:-$POLICY/allowlist.acl.perm}"
TTL="${TTL_FILE:-$POLICY/ttl.tsv}"

# Domains of a feature (comments + blank lines stripped).
_feat_domains() {
  local f="$DEFS/$1.list"
  [ -f "$f" ] && grep -vE '^[[:space:]]*(#|$)' "$f" 2>/dev/null
  return 0
}

# Space-separated dependencies declared in a feature's "# depends:" header.
_feat_deps() {
  local f="$DEFS/$1.list"
  [ -f "$f" ] && sed -n 's/^#[[:space:]]*depends:[[:space:]]*//p' "$f" 2>/dev/null | tr ',' ' '
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
    # Only real features (a definition file must exist).
    [ -f "$DEFS/$_f.list" ] || continue
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
