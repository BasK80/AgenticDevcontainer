FROM debian:trixie-slim
COPY allow.sh         /usr/local/bin/allow
COPY deny.sh          /usr/local/bin/deny
COPY show_blocks.sh   /usr/local/bin/show_blocks
COPY list_allows.sh   /usr/local/bin/list_allows
COPY tail_firewall.sh /usr/local/bin/tail_firewall
RUN chmod +x /usr/local/bin/allow \
             /usr/local/bin/deny \
             /usr/local/bin/show_blocks \
             /usr/local/bin/list_allows \
             /usr/local/bin/tail_firewall
CMD ["sleep", "infinity"]
