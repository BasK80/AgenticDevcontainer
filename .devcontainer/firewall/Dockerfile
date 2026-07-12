FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
      squid socat procps ca-certificates python3 tzdata dnsmasq \
    && rm -rf /var/lib/apt/lists/*
COPY squid.conf /etc/squid/squid.conf
COPY dnsmasq.conf /etc/dnsmasq.conf
# Feature-set definitions (baseline + one .list per toggleable feature). The
# entrypoint refreshes /policy/features.defs from these on every start, so the
# baked image is the source of truth for what each feature grants.
COPY features/ /etc/squid/features/
COPY entrypoint.sh watcher.sh blockfeed.sh build-acl.sh fw auditlog.py /usr/local/bin/
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
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/watcher.sh /usr/local/bin/blockfeed.sh /usr/local/bin/build-acl.sh /usr/local/bin/fw /usr/local/bin/auditlog.py
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
