#!/usr/bin/env bash
set -uo pipefail
TTL=/policy/ttl.tsv
OUT=/policy/allowlist.acl
PLACEHOLDER="invalid.invalid"

while true; do
  now=$(date +%s)
  # Prune expired TTL entries before recompiling.
  if [ -s "$TTL" ]; then
    awk -v now="$now" -F'\t' '($1+0)>now' "$TTL" > "$TTL.new" 2>/dev/null || true
    mv -f "$TTL.new" "$TTL" 2>/dev/null || true
  fi

  # Recompile: placeholder + baseline + enabled features (dep-closed) + manual
  # permanent + live TTL, sorted/deduped. See build-acl.sh for the layering.
  {
    echo "$PLACEHOLDER"
    /usr/local/bin/build-acl.sh
  } 2>/dev/null | sort -u > "$OUT.next"

  if ! cmp -s "$OUT.next" "$OUT" 2>/dev/null; then
    mv -f "$OUT.next" "$OUT"
    squid -k reconfigure 2>/dev/null || true
  else
    rm -f "$OUT.next"
  fi
  sleep 5
done
