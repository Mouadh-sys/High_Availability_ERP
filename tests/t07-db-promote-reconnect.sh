#!/usr/bin/env bash
# T07 — Promote erp02, move the DB VIP, reconnect Odoo, prove writes work.
source "$(dirname "$0")/lib/common.sh"
init_test T07 "Promote standby and reconnect"

require_vault || exit 1
failure_epoch="$(cat "$EVIDENCE_DIR/.failure_epoch" 2>/dev/null || now)"
note "failure was injected at $(date -u -d "@${failure_epoch}" +%FT%TZ)"

start_probe
(cd "$ROOT_DIR" && make db-failover) 2>&1 | tee -a "$LOG_FILE"
playbook_rc=${PIPESTATUS[0]}

wait_until 180 "ERP VIP serving after promotion" code_is 200 || true
rto="$(probe_rto "$failure_epoch")"
stop_probe
avail="$(probe_availability)"
note "rto=${rto:-?}s availability=${avail}% | x-lb=$(vip_lb) | backends=$(backend_states)"

state="$(db_in_recovery)"
if [[ "$state" == "f" ]]; then
  good "DB VIP points at a writable primary"
else
  bad "DB VIP is not writable (pg_is_in_recovery=${state:-unknown})"
fi

write_id="$(db_psql "create table if not exists ha_erp_probe(id serial primary key, ts timestamptz default now()); insert into ha_erp_probe default values returning id" | tr -d ' \n')"
if [[ -n "$write_id" ]]; then
  good "write through the DB VIP succeeded (probe row ${write_id})"
else
  bad "write through the DB VIP failed"
fi

users="$(db_psql "select count(*) from res_users")"
attachments="$(db_psql "select count(*) from ir_attachment")"
note "integrity: res_users=${users:-?} ir_attachment=${attachments:-?}"

repl="$(ssh_vm "$ERP02" 'sudo -u postgres psql -tAc "select count(*) from pg_stat_replication"' | tr -d ' \n')"
note "replication senders now on erp02: ${repl:-0} (expected 0 until erp01 rejoins)"

if [[ "$playbook_rc" -eq 0 && "$state" == "f" && -n "$write_id" ]] \
   && [[ -n "$rto" ]] && awk -v r="$rto" 'BEGIN{exit !(r<=120)}'; then
  result=pass
  good "database failover completed (RTO ${rto}s <= 120s)"
else
  result=fail
  bad "database failover failed or exceeded 120s (playbook rc=${playbook_rc})"
fi

record_result "$result" "$rto" "" "promotion via playbooks/db-failover.yml; users=${users:-?}; attachments=${attachments:-?}"
[[ "$result" == pass ]]
