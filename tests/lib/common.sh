#!/usr/bin/env bash
# Shared test helpers. Source from each test script.
# shellcheck shell=bash

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
EVIDENCE_DIR="${EVIDENCE_DIR:-$ROOT_DIR/evidence}"
RESULTS="$EVIDENCE_DIR/results.jsonl"
mkdir -p "$EVIDENCE_DIR"

if [[ -f "$TESTS_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  . "$TESTS_DIR/.env"
  set +a
fi

ERP_VIP="${ERP_VIP:-192.168.50.10}"
DB_VIP="${DB_VIP:-192.168.50.30}"
LB01="${LB01:-192.168.50.11}"
LB02="${LB02:-192.168.50.12}"
ERP01="${ERP01:-192.168.50.21}"
ERP02="${ERP02:-192.168.50.22}"
HAPROXY_STATS_PORT="${HAPROXY_STATS_PORT:-8404}"

ODOO_DB="${ODOO_DB:-ha_erp}"
ODOO_USER="${ODOO_USER:-odoo}"
ODOO_ADMIN_USER="${ODOO_ADMIN_USER:-admin}"

SSH_KEY="${SSH_KEY:-$HOME/.ssh/ha_erp_ed25519}"
SSH_OPTS=(-i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=no
          -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5)

if [[ -t 1 ]]; then
  C_OK=$'\033[32m'; C_ERR=$'\033[31m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_OK=''; C_ERR=''; C_DIM=''; C_OFF=''
fi

say()  { printf '%s\n' "$*" | tee -a "${LOG_FILE:-/dev/null}"; }
good() { say "  ${C_OK}[ok]${C_OFF}   $*"; }
bad()  { say "  ${C_ERR}[fail]${C_OFF} $*"; }
note() { say "  ${C_DIM}[info]${C_OFF} $*"; }

init_test() {
  TEST_ID="$1"
  TEST_TITLE="$2"
  STARTED_AT="$(date -u +%FT%TZ)"
  LOG_FILE="$EVIDENCE_DIR/${TEST_ID}-$(date -u +%Y%m%dT%H%M%SZ).log"
  PROBE_FILE="$EVIDENCE_DIR/${TEST_ID}-probe-$(date -u +%Y%m%dT%H%M%SZ).csv"
  say ""
  say "=============================================================="
  say " $TEST_ID — $TEST_TITLE"
  say " started $STARTED_AT"
  say "=============================================================="
  trap stop_probe EXIT
}

now() { date +%s.%N; }

ssh_vm() { local host="$1"; shift; ssh "${SSH_OPTS[@]}" "debian@${host}" "$@"; }

vip_code() {
  curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://${ERP_VIP}/web/login" 2>/dev/null || echo "000"
}

vip_lb() {
  curl -sI --max-time 3 "http://${ERP_VIP}/web/login" 2>/dev/null \
    | awk -F': ' 'tolower($1)=="x-lb"{print $2}' | tr -d '\r'
}

backend_states() {
  curl -s --max-time 3 "http://${ERP_VIP}:${HAPROXY_STATS_PORT}/stats;csv" 2>/dev/null \
    | awk -F, '$1=="be_erp" && $2!="FRONTEND"{printf "%s=%s ", $2, $18}'
}

wait_until() { # wait_until <timeout_s> <description> <command...>
  local timeout="$1" desc="$2" start=$SECONDS
  shift 2
  until "$@"; do
    if (( SECONDS - start >= timeout )); then
      bad "timeout ${timeout}s waiting for: ${desc}"
      return 1
    fi
    sleep 0.5
  done
  good "${desc} ($((SECONDS - start))s)"
  return 0
}

code_is()    { [[ "$(vip_code)" == "$1" ]]; }
backend_is() { [[ "$(backend_states)" == *"$1=$2"* ]]; }
lb_is()      { [[ "$(vip_lb)" == "$1" ]]; }

db_ready() { [[ -n "${ODOO_DB_PASSWORD:-}" ]]; }
db_psql()  { PGPASSWORD="${ODOO_DB_PASSWORD:-}" psql -h "$DB_VIP" -U "$ODOO_USER" -d "$ODOO_DB" -tAc "$1" 2>/dev/null; }
db_in_recovery() { db_psql "select pg_is_in_recovery()" | tr -d ' '; }

start_probe() {
  PROBE_PID=""
  "$TESTS_DIR/lib/probe.sh" 600 > "$PROBE_FILE" 2>/dev/null &
  PROBE_PID=$!
  sleep 1
  note "probe started (pid $PROBE_PID) -> $PROBE_FILE"
}

stop_probe() {
  if [[ -n "${PROBE_PID:-}" ]] && kill -0 "$PROBE_PID" 2>/dev/null; then
    kill "$PROBE_PID" 2>/dev/null || true
    wait "$PROBE_PID" 2>/dev/null || true
    note "probe stopped ($(wc -l < "$PROBE_FILE" 2>/dev/null || echo 0) samples)"
  fi
  PROBE_PID=""
}

probe_availability() {
  awk -F, 'NR>0 && $1 !~ /^#/ {tot++; if ($2=="200") ok++} END{if (tot>0) printf "%.1f", 100*ok/tot}' "${1:-$PROBE_FILE}"
}

probe_rto() { # probe_rto <failure_epoch>
  awk -F, -v f="$1" '$1+0 >= f+0 && $2=="200" {printf "%.2f", $1-f; exit}' "${PROBE_FILE}"
}

probe_first_failure() { # probe_first_failure <after_epoch>
  awk -F, -v f="$1" '$1+0 >= f+0 && $2!="200" {printf "%.2f", $1-f; exit}' "${PROBE_FILE}"
}

record_result() { # record_result <status> [rto] [detection] [notes]
  local status="$1" rto="${2:-}" det="${3:-}" notes="${4:-}"
  TEST_ID="$TEST_ID" STARTED_AT="$STARTED_AT" STATUS="$status" RTO="$rto" DET="$det" \
  AVAIL="$(probe_availability)" ACTIVE_LB="$(vip_lb)" BACKENDS="$(backend_states)" \
  NOTES="$notes" TEST_TITLE="$TEST_TITLE" \
  jq -nc '{
    test: env.TEST_ID,
    title: env.TEST_TITLE,
    started: env.STARTED_AT,
    finished: (now | todate),
    status: env.STATUS,
    rto_s: (if env.RTO == "" then null else (env.RTO | tonumber) end),
    detection_s: (if env.DET == "" then null else (env.DET | tonumber) end),
    availability_pct: (if env.AVAIL == "" then null else (env.AVAIL | tonumber) end),
    active_lb: env.ACTIVE_LB,
    backends: env.BACKENDS,
    notes: env.NOTES
  }' >> "$RESULTS"
  say "  result -> $(tail -n 1 "$RESULTS")"
}

require_vault() {
  if [[ -z "${ANSIBLE_VAULT_PASSWORD_FILE:-}" && ! -f "$HOME/.config/ha-erp/vault-pass" ]]; then
    bad "no Ansible Vault password available (set ANSIBLE_VAULT_PASSWORD_FILE)"
    return 1
  fi
  export ANSIBLE_VAULT_PASSWORD_FILE="${ANSIBLE_VAULT_PASSWORD_FILE:-$HOME/.config/ha-erp/vault-pass}"
}
