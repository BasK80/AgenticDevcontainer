#!/usr/bin/env bash
set -uo pipefail
LOG=/var/log/squid/access.log
RESP=/tmp/blocks.http

build() {
  {
    printf 'HTTP/1.1 200 OK\r\n'
    printf 'Content-Type: text/plain\r\n'
    printf 'Connection: close\r\n'
    printf '\r\n'
    b=$(grep -E 'DENIED|/403' "$LOG" 2>/dev/null | tail -n 50)
    if [ -n "$b" ]; then printf '%s\n' "$b"; else echo '(no blocked requests recorded yet)'; fi
  } > "$RESP.new" 2>/dev/null && mv -f "$RESP.new" "$RESP" 2>/dev/null || true
}

build
( while true; do build; sleep 3; done ) &

exec socat -T5 TCP-LISTEN:8099,reuseaddr,fork SYSTEM:"cat $RESP"
