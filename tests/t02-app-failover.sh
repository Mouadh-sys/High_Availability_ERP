#!/usr/bin/env bash
# T02 — Stop Odoo on erp01: HAProxy must drain it and serve through erp02.
source "$(dirname "$0")/lib/common.sh"
init_test T02 "Stop Odoo on erp01"

wait_until 30 "baseline HTTP 200" code_is 200 || exit 1
note "backends before: $(backend_states)"

start_probe
t0=$(now)
note "injecting failure at $(date -u -d "@${t0}" +%FT%TZ)"
ssh_vm "$ERP01" 'sudo systemctl stop ha-erp-odoo' || bad "could not stop Odoo on erp01"

wait_until 30 "erp01 marked DOWN" backend_is erp01 DOWN || true
detection="$(probe_first_failure "$t0")"
wait_until 30 "ERP VIP still serving" code_is 200 || true
rto="$(probe_rto "$t0")"
stop_probe

avail="$(probe_availability)"
note "detection=${detection:-?}s rto=${rto:-?}s availability=${avail}%"
note "backends after: $(backend_states) | served by $(vip_lb)"

# Restore before grading so the lab is left healthy
ssh_vm "$ERP01" 'sudo systemctl start ha-erp-odoo' || bad "could not restart Odoo on erp01"
wait_until 90 "erp01 back UP" backend_is erp01 UP || true

if [[ -n "$rto" ]] && awk -v r="$rto" 'BEGIN{exit !(r<=10)}'; then
  good "RTO ${rto}s <= 10s"
  result=pass
else
  bad "RTO ${rto:-none}s exceeds 10s"
  result=fail
fi
note "availability ${avail}% over this short failover window (informational; the 99% target is T01's 60 s steady-state window)"

record_result "$result" "$rto" "$detection" "odoo stopped on erp01, restored"
[[ "$result" == pass ]]
