#!/usr/bin/env bash
# Usage:  deny <domain>
# Removes <domain> from the allowlist (permanent + temporary); re-blocked ~5s.
# Exact-match only — if the domain is reachable via a wildcard parent
# (e.g. .githubusercontent.com), remove that wildcard entry instead.
set -euo pipefail
d="${1:?usage: deny <domain>}"
PERM=/policy/allowlist.acl.perm
TTL=/policy/ttl.tsv
removed=0

if [ -f "$PERM" ] && grep -qxF "$d" "$PERM" 2>/dev/null; then
  grep -vxF "$d" "$PERM" > "$PERM.new" 2>/dev/null || true
  mv -f "$PERM.new" "$PERM"
  removed=1
fi

if [ -f "$TTL" ] && cut -f2 "$TTL" 2>/dev/null | grep -qxF "$d"; then
  awk -F'\t' -v d="$d" '$2!=d' "$TTL" > "$TTL.new" 2>/dev/null || true
  mv -f "$TTL.new" "$TTL"
  removed=1
fi

if [ "$removed" = 1 ]; then
  echo "removed $d — blocked again within ~5s"
else
  echo "note: '$d' is not an explicit allowlist entry."
  echo "      if it is still reachable it may be covered by a wildcard parent"
  echo "      (e.g. .githubusercontent.com). check with:  cat /policy/allowlist.acl"
fi
