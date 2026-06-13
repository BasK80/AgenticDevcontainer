FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
      squid socat procps ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY squid.conf /etc/squid/squid.conf
COPY allowlist.default /etc/squid/allowlist.default
COPY entrypoint.sh watcher.sh blockfeed.sh fw /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/watcher.sh /usr/local/bin/blockfeed.sh /usr/local/bin/fw
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
