#!/usr/bin/env bash
# T06 — Stop the PostgreSQL primary and fence it. Measures RPO, not uptime.
source "$(dirname "$0")/lib/common.sh"
init_test T06 "Stop PostgreSQL primary and fence"

if ! db_ready; then
  bad "ODOO_DB_PASSWORD is required for T06 (see tests/.env.example)"; exit 1
fi

lag="$(ssh_vm "$ERP02" 'sudo -u postgres psql -tAc "select coalesce(extract(epoch from (now()-pg_last_xact_replay_timestamp()))::int,-1)"' | tr -d ' \n')"
bytes="$(ssh_vm "$ERP01" 'sudo -u postgres psql -tAc "select coalesce(sum(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)),0) from pg_stat_replication"' | tr -d ' \n')"
note "before failure: replay lag ${lag:-?}s, unreplicated WAL ${bytes:-?} bytes"

t0=$(now)
printf '%s\n' "$t0" > "$EVIDENCE_DIR/.failure_epoch"
start_probe

note "stopping PostgreSQL on erp01 at $(date -u -d "@${t0}" +%FT%TZ)"
ssh_vm "$ERP01" 'sudo systemctl stop postgresql@16-main' || bad "could not stop PostgreSQL on erp01"
sleep 2
virsh destroy erp01 >/dev/null 2>&1 || note "erp01 already off"
note "erp01 powered off (fence)"

# The standby must still be a standby and must still be reachable directly.
ok=1
wait_until 30 "erp02 still answers locally" ssh_vm "$ERP02" 'true' || ok=0
state="$(ssh_vm "$ERP02" 'sudo -u postgres psql -tAc "select pg_is_in_recovery()"' | tr -d ' \n')"
if [[ "$state" == "t" ]]; then
  good "erp02 is still a standby and can be promoted"
else
  bad "erp02 is not in recovery (state=${state:-unknown}) — do not promote"
  ok=0
fi

stop_probe
note "availability during the database outage: $(probe_availability)% (expected to be low by design)"
note "RPO evidence: ${bytes:-0} bytes of WAL were not replayed at fence time (lag ${lag:-?}s)"

if [[ $ok -eq 1 ]]; then
  record_result pass "" "" "primary stopped+fenced; rpo_bytes=${bytes:-0}; lag_s=${lag:-?}"
else
  record_result fail "" "" "standby not promotable"
fi
[[ $ok -eq 1 ]]
