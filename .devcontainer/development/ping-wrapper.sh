#!/usr/bin/env bash
# ping wrapper — installed as ~/.local/bin/ping by post-start.sh
#
# Inside this dev container the development network has no default gateway
# (internal: true in docker-compose.yml). ping uses raw ICMP which bypasses
# the HTTP proxy, so DNS resolution and packet routing both fail regardless
# of the firewall allowlist.
#
# This wrapper explains that and suggests proxy-aware alternatives.

TARGET="${*: -1}"   # last argument (the host, ignoring flags)

cat >&2 <<EOF

  ping is not available in this dev container.

  The container's network has no default gateway — outbound traffic is
  intentionally routed only through the HTTP/HTTPS proxy (Squid on
  firewall:3128). ICMP packets and raw DNS queries cannot be routed out,
  so ping always fails with "Temporary failure in name resolution" or
  "Network is unreachable", regardless of the firewall allowlist.

  To test whether a host is reachable over HTTP/HTTPS, use curl instead:

    curl -I https://${TARGET:-<host>}          # HEAD request — shows HTTP status
    curl -sv https://${TARGET:-<host>} 2>&1 | head -20  # verbose — shows TLS + headers

  If the request is blocked by the firewall, you will receive HTTP 403.
  To allow a domain, run from the host:

    FW="agentic-\$(basename "\$PWD")-firewall"
    docker exec "\$FW" fw allow ${TARGET:-<domain>}

EOF
exit 1
