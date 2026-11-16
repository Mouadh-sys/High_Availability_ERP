#!/usr/bin/env bash
# T03 — Stop Odoo on erp02: erp01 must carry the load.
source "$(dirname "$0")/lib/common.sh"
init_test T03 "Stop Odoo on erp02"

wait_until 30 "baseline HTTP 200" code_is 200 || exit 1
note "backends before: $(backend_states)"

start_probe
t0=$(now)
ssh_vm "$ERP02" 'sudo systemctl stop ha-erp-odoo' || bad "could not stop Odoo on erp02"

wait_until 30 "erp02 marked DOWN" backend_is erp02 DOWN || true
detection="$(probe_first_failure "$t0")"
wait_until 30 "ERP VIP still serving" code_is 200 || true
rto="$(probe_rto "$t0")"
stop_probe

avail="$(probe_availability)"
note "detection=${detection:-?}s rto=${rto:-?}s availability=${avail}%"
note "backends after: $(backend_states) | served by $(vip_lb)"

ssh_vm "$ERP02" 'sudo systemctl start ha-erp-odoo' || bad "could not restart Odoo on erp02"
wait_until 90 "erp02 back UP" backend_is erp02 UP || true

if [[ -n "$rto" ]] && awk -v r="$rto" 'BEGIN{exit !(r<=10)}'; then
  good "RTO ${rto}s <= 10s"
  result=pass
else
  bad "RTO ${rto:-none}s exceeds 10s"
  result=fail
fi
[[ "${avail%%.*}" -ge 99 ]] && good "availability ${avail}% >= 99%" || bad "availability ${avail}% < 99%"

record_result "$result" "$rto" "$detection" "odoo stopped on erp02, restored"
[[ "$result" == pass ]]
