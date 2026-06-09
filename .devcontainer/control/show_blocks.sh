#!/usr/bin/env sh
# Usage:  show_blocks
# Prints the last 30 lines of the Squid access log.
tail -n 30 /var/log/squid/access.log
