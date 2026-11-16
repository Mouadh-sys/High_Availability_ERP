#!/usr/bin/env bash
# Continuous availability probe. Emits CSV: epoch_seconds,http_code,active_lb
# usage: probe.sh [duration_seconds] [interval_seconds]
set -uo pipefail

duration="${1:-60}"
interval="${2:-0.5}"
target="${PROBE_TARGET:-http://192.168.50.10/web/login}"
deadline=$(( $(date +%s) + duration ))

while (( $(date +%s) < deadline )); do
  ts=$(date +%s.%3N)
  raw=$(curl -sS -o /dev/null -D - -w '\nCODE:%{http_code}\n' --max-time 3 "$target" 2>/dev/null || true)
  code=$(awk -F: '/^CODE:/{print $2}' <<<"$raw" | tr -d '\r')
  lb=$(awk 'tolower($1)=="x-lb:"{print $2}' <<<"$raw" | tr -d '\r')
  [[ -z "$code" ]] && code="000"
  printf '%s,%s,%s\n' "$ts" "$code" "${lb:-unknown}"
  sleep "$interval"
done
