FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
      squid socat procps ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY squid.conf /etc/squid/squid.conf
COPY allowlist.default /etc/squid/allowlist.default
COPY entrypoint.sh watcher.sh blockfeed.sh fw /usr/local/bin/
# Firewall-aware error page: assemble a custom error_directory from Squid's
# stock English templates plus our ERR_FIREWALL_BLOCKED page, so a blocked
# request explains the allowlist (see squid.conf: error_directory + deny_info).
COPY ERR_FIREWALL_BLOCKED /tmp/ERR_FIREWALL_BLOCKED
RUN set -eu; \
    src="$(dirname "$(find /usr/share/squid* -name ERR_ACCESS_DENIED 2>/dev/null | head -n1)")"; \
    test -n "$src" && test -d "$src"; \
    mkdir -p /etc/squid/errors; \
    cp -a "$src"/. /etc/squid/errors/; \
    mv /tmp/ERR_FIREWALL_BLOCKED /etc/squid/errors/ERR_FIREWALL_BLOCKED
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/watcher.sh /usr/local/bin/blockfeed.sh /usr/local/bin/fw
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
