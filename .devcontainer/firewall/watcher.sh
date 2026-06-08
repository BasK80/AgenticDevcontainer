#!/usr/bin/env bash
set -uo pipefail
PERM=/policy/allowlist.acl.perm
TTL=/policy/ttl.tsv
OUT=/policy/allowlist.acl
PLACEHOLDER="invalid.invalid"

while true; do
  now=$(date +%s)
  if [ -s "$TTL" ]; then
    awk -v now="$now" -F'\t' '($1+0)>now' "$TTL" > "$TTL.new" 2>/dev/null || true
    mv -f "$TTL.new" "$TTL" 2>/dev/null || true
  fi
  {
    echo "$PLACEHOLDER"
    [ -f "$PERM" ] && grep -vE '^[[:space:]]*(#|$)' "$PERM" 2>/dev/null
    [ -s "$TTL" ]  && cut -f2 "$TTL" 2>/dev/null
  } 2>/dev/null | sort -u > "$OUT.next"

  if ! cmp -s "$OUT.next" "$OUT" 2>/dev/null; then
    mv -f "$OUT.next" "$OUT"
    squid -k reconfigure 2>/dev/null || true
  else
    rm -f "$OUT.next"
  fi
  sleep 5
done
