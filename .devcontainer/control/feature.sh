#!/usr/bin/env bash
# Usage:  feature <name> on|off
# Toggles a firewall feature-set by editing /policy/features.state. The firewall
# watcher recompiles the live allowlist within ~5s. Mirrors `fw feature` in the
# firewall container; both write the same shared /policy state.
set -euo pipefail
DEFS=/policy/features.defs
STATE=/policy/features.state

name="${1:?usage: feature <name> on|off}"
val="${2:?usage: feature <name> on|off}"
case "$val" in on|off) ;; *) echo "state must be 'on' or 'off'" >&2; exit 1 ;; esac
if [ ! -f "$DEFS/$name.list" ]; then
  echo "unknown feature: $name" >&2
  exit 1
fi

tmp="$(mktemp)"
if [ -f "$STATE" ] && grep -qE "^$name=" "$STATE"; then
  sed "s/^$name=.*/$name=$val/" "$STATE" > "$tmp"
else
  { [ -f "$STATE" ] && cat "$STATE"; echo "$name=$val"; } > "$tmp"
fi
mv -f "$tmp" "$STATE"
echo "feature $name=$val — effective within ~5s"
