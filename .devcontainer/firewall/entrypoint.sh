#!/usr/bin/env bash
# No `set -e`: a benign setup hiccup must not kill the container before Squid
# can report its own error. Squid's exit code still propagates via `exec`.
set -uo pipefail

mkdir -p /policy
touch /policy/ttl.tsv 2>/dev/null || true

# Feature definitions are image-owned: refresh the runtime copy from the baked
# defaults on every start so a rebuilt image always wins, while the toggle
# state (features.state) and manual edits in /policy persist. The control
# container reads these defs from /policy (it has no /etc/squid).
rm -rf /policy/features.defs 2>/dev/null || true
mkdir -p /policy/features.defs
cp /etc/squid/features/*.list /policy/features.defs/ 2>/dev/null || true

# First run: seed the toggle state. Safe-defaults ON; everything else opt-in.
if [ ! -f /policy/features.state ]; then
  defaults_on=" anthropic github npm opencode "
  for f in /policy/features.defs/*.list; do
    [ -e "$f" ] || continue
    name="$(basename "$f" .list)"
    [ "$name" = "_baseline" ] && continue
    case "$defaults_on" in
      *" $name "*) echo "$name=on" ;;
      *)           echo "$name=off" ;;
    esac
  done > /policy/features.state 2>/dev/null || true
fi

# Manual permanent allowlist (what `fw allow` writes) — starts empty.
touch /policy/allowlist.acl.perm 2>/dev/null || true

# Build the live allowlist immediately so Squid starts with the full policy
# (avoids a deny-all race window while the watcher spins up).
{
  echo "invalid.invalid"
  /usr/local/bin/build-acl.sh
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

# Long-term audit log: tail access.log into SQLite on the auditlog volume.
mkdir -p /auditlog 2>/dev/null || true
/usr/local/bin/auditlog.py &

# Local DNS resolver for the internal, default-deny development container so
# its tools can pre-resolve external hostnames (see apply-fix-web-proxy.sh).
# Egress itself stays enforced by Squid below.
# dnsmasq-listen-fix: this project derives a per-project subnet in
# initialize.sh, so the firewall's internal IP is NOT the hardcoded
# 172.28.0.2 in dnsmasq.conf. Bind dnsmasq to the real FIREWALL_IP so
# the development container's resolver target is actually served.
sed -i "s/^listen-address=.*/listen-address=127.0.0.1,${FIREWALL_IP:-172.28.0.2}/" /etc/dnsmasq.conf
dnsmasq --conf-file=/etc/dnsmasq.conf 2>/dev/null || true

exec squid -N -d1
