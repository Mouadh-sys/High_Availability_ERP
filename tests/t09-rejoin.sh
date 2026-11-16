#!/usr/bin/env bash
# T09 — Rejoin the former primary as a streaming standby and restore the pool.
source "$(dirname "$0")/lib/common.sh"
init_test T09 "Restore and rejoin erp01"

require_vault || exit 1

if [[ "$(virsh domstate erp01 2>/dev/null)" != "running" ]]; then
  note "starting erp01"
  virsh start erp01 >/dev/null 2>&1 || bad "could not start erp01"
fi
wait_until 120 "erp01 reachable over SSH" ssh_vm "$ERP01" true || exit 1

# The fence marker written at promotion must keep the stale primary stopped.
if ssh_vm "$ERP01" 'sudo systemctl is-active --quiet postgresql@16-main'; then
  bad "erp01 started PostgreSQL while still fenced — split-brain guard failed"
else
  good "erp01 booted fenced (PostgreSQL blocked by the marker)"
fi

(cd "$ROOT_DIR" && make db-rejoin) 2>&1 | tee -a "$LOG_FILE"
rejoin_rc=${PIPESTATUS[0]}

wait_until 120 "erp01 backend UP in HAProxy" backend_is erp01 UP || true

state="$(ssh_vm "$ERP01" 'sudo -u postgres psql -tAc "select pg_is_in_recovery()"' | tr -d ' \n')"
lag="$(ssh_vm "$ERP02" 'sudo -u postgres psql -tAc "select coalesce(extract(epoch from (now()-pg_last_xact_replay_timestamp()))::int,-1)"' | tr -d ' \n')"
streaming="$(ssh_vm "$ERP02" 'sudo -u postgres psql -tAc "select count(*) from pg_stat_replication"' | tr -d ' \n')"
role="$(ssh_vm "$ERP01" 'cat /etc/ha-erp/db-role' | tr -d ' \n')"
vip_holder="$(ssh_vm "$ERP01" 'ip -4 -o addr show | grep -c 192.168.50.30 || true' | tr -d ' \n')"

note "erp01 pg_is_in_recovery=${state:-?} role=${role:-?} db_vip_addresses=${vip_holder:-?}"
note "streaming standbys: ${streaming:-0}, replay lag: ${lag:-?}s"

fail=0
[[ "$rejoin_rc" -eq 0 ]] && good "rejoin playbook completed" || { bad "rejoin playbook failed"; fail=1; }
[[ "$state" == "t" ]] && good "erp01 is a standby" || { bad "erp01 is not a standby"; fail=1; }
[[ "$role" == "standby" ]] && good "erp01 role marker is standby" || { bad "role marker is ${role:-missing}"; fail=1; }
[[ "${streaming:-0}" -ge 1 ]] && good "erp01 is streaming from erp02" || { bad "no streaming sender"; fail=1; }
[[ "${vip_holder:-0}" -eq 0 ]] && good "erp01 does not hold the DB VIP" || { bad "erp01 still holds the DB VIP"; fail=1; }
backend_states | grep -q 'erp01=UP' && good "erp01 is back in the HAProxy pool" || { bad "erp01 not in the pool"; fail=1; }

[[ $fail -eq 0 ]] && { record_result pass "" "" "erp01 rejoined as standby; lag=${lag:-?}s"; exit 0; }
record_result fail "" "" "rejoin incomplete"
exit 1
