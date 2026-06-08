#!/usr/bin/env bash
# Usage:  allow <domain> [ttl_seconds]
# Permanent if no ttl; temporary (auto-expiring) if a ttl is given.
set -euo pipefail
d="${1:?usage: allow <domain> [ttl_seconds]}"
ttl="${2:-}"
if [ -n "$ttl" ]; then
  printf '%s\t%s\n' "$(( $(date +%s) + ttl ))" "$d" >> /policy/ttl.tsv
  echo "added $d (ttl ${ttl}s) — active within ~5s"
else
  echo "$d" >> /policy/allowlist.acl.perm
  echo "added $d (permanent) — active within ~5s"
fi
