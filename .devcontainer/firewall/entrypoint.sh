#!/usr/bin/env bash
# No `set -e`: a benign setup hiccup must not kill the container before Squid
# can report its own error. Squid's exit code still propagates via `exec`.
set -uo pipefail

mkdir -p /policy
touch /policy/ttl.tsv 2>/dev/null || true

# First run: seed the permanent allowlist from the baked production default.
if [ ! -f /policy/allowlist.acl.perm ]; then
  cp /etc/squid/allowlist.default /policy/allowlist.acl.perm 2>/dev/null || touch /policy/allowlist.acl.perm
fi

# Build the live allowlist immediately so Squid starts with the full policy
# (avoids a deny-all race window while the watcher spins up).
{
  echo "invalid.invalid"
  grep -vE '^[[:space:]]*(#|$)' /policy/allowlist.acl.perm 2>/dev/null
  [ -s /policy/ttl.tsv ] && cut -f2 /policy/ttl.tsv 2>/dev/null
} 2>/dev/null | sort -u > /policy/allowlist.acl

mkdir -p /var/log/squid /var/spool/squid
chown -R proxy:proxy /var/log/squid /var/spool/squid 2>/dev/null || true
squid -z --foreground 2>/dev/null || true

# Squid execs as PID 1. If the previous container was killed ungracefully
# (e.g. VS Code shutting down its devcontainer), /run/squid.pid is left behind
# pointing at PID 1, which collides with the new instance and triggers
# "FATAL: Squid is already running". Clear it before launch.
rm -f /run/squid.pid

/usr/local/bin/watcher.sh &
/usr/local/bin/blockfeed.sh &

exec squid -N -d1
