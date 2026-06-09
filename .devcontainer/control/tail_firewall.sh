#!/usr/bin/env sh
# Usage:  tail_firewall
# Follows the Squid access log.
exec tail -f /var/log/squid/access.log
