#!/bin/sh
# Keepalived notify hook — records VIP transitions as test evidence.
# usage (from keepalived notify_master/backup/fault): ha-erp-notify <state> <instance>
set -eu
state="${1:-unknown}"
instance="${2:-unknown}"
dir=/var/log/ha-erp
mkdir -p "$dir"
printf '%s %s %s %s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(hostname -s)" "$state" "$instance" \
  >> "$dir/vip-transitions.log"
