FROM debian:trixie-slim
COPY allow.sh /usr/local/bin/allow
COPY deny.sh  /usr/local/bin/deny
RUN chmod +x /usr/local/bin/allow /usr/local/bin/deny
CMD ["sleep", "infinity"]
