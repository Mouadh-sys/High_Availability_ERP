#!/usr/bin/env bash
# T01 — Normal operation: both backends UP, VIP served, replication and filestore healthy.
source "$(dirname "$0")/lib/common.sh"
init_test T01 "Normal operation"

fail=0
note "VIP: $(vip_code) via $(vip_lb) | backends: $(backend_states)"

[[ "$(vip_code)" == "200" ]] && good "ERP VIP returns HTTP 200" || { bad "ERP VIP does not return 200"; fail=1; }
backend_states | grep -q 'erp01=UP' && good "backend erp01 UP" || { bad "backend erp01 not UP"; fail=1; }
backend_states | grep -q 'erp02=UP' && good "backend erp02 UP" || { bad "backend erp02 not UP"; fail=1; }

start_probe
sleep 10
stop_probe
avail="$(probe_availability)"
note "availability over 10 s: ${avail}%"

# Twenty concurrent requests
tmp="$(mktemp -d)"
for i in $(seq 1 20); do
  curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 "http://${ERP_VIP}/web/login" > "$tmp/$i" &
done
wait
okn=$(grep -l '^200$' "$tmp"/* 2>/dev/null | wc -l)
if [[ "$okn" -eq 20 ]]; then good "20/20 concurrent requests succeeded"; else bad "$okn/20 concurrent requests succeeded"; fail=1; fi
rm -rf "$tmp"

# Database
if db_ready; then
  role="$(db_in_recovery)"
  [[ "$role" == "f" ]] && good "DB VIP is writable (pg_is_in_recovery=false)" || { bad "DB VIP not writable (pg_is_in_recovery=$role)"; fail=1; }
  for host in "$ERP01" "$ERP02"; do
    r="$(ssh_vm "$host" 'sudo -u postgres psql -tAc "select pg_is_in_recovery()"' | tr -d ' \n')"
    note "$host pg_is_in_recovery=$r"
  done
  lag="$(ssh_vm "$ERP02" 'sudo -u postgres psql -tAc "select coalesce(extract(epoch from (now()-pg_last_xact_replay_timestamp()))::int,-1)"' | tr -d ' \n')"
  note "replay lag: ${lag}s"
else
  note "ODOO_DB_PASSWORD not set — database checks skipped"
fi

# Shared filestore
for host in "$ERP01" "$ERP02"; do
  if ssh_vm "$host" 'mountpoint -q /srv/ha-erp/filestore'; then
    good "$host has the filestore mounted"
  else
    bad "$host is missing the filestore mount"
    fail=1
  fi
done

[[ $fail -eq 0 ]] && record_result pass "" "" "baseline" || record_result fail "" "" "baseline checks failed"
exit $fail
