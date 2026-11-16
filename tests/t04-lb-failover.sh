#!/usr/bin/env bash
# T04 — Power off lb01: the ERP VIP must move to lb02 with minimal interruption.
source "$(dirname "$0")/lib/common.sh"
init_test T04 "Power off lb01"

wait_until 30 "baseline HTTP 200" code_is 200 || exit 1
[[ "$(vip_lb)" == "lb01" ]] && good "VIP is on lb01 (baseline)" || note "VIP is on $(vip_lb) before the test"

start_probe
t0=$(now)
virsh destroy lb01 >/dev/null 2>&1 || bad "could not power off lb01"

wait_until 30 "VIP owned by lb02" lb_is lb02 || true
detection="$(probe_first_failure "$t0")"
wait_until 30 "ERP VIP serving from lb02" code_is 200 || true
rto="$(probe_rto "$t0")"
stop_probe

avail="$(probe_availability)"
note "detection=${detection:-?}s rto=${rto:-?}s availability=${avail}% | x-lb=$(vip_lb)"
ssh_vm "$LB02" 'sudo tail -n 3 /var/log/ha-erp/vip-transitions.log' 2>/dev/null | sed 's/^/  /' || true

if [[ -n "$rto" ]] && awk -v r="$rto" 'BEGIN{exit !(r<=8)}'; then
  good "RTO ${rto}s <= 8s"
  result=pass
else
  bad "RTO ${rto:-none}s exceeds 8s"
  result=fail
fi
[[ "${avail%%.*}" -ge 99 ]] && good "availability ${avail}% >= 99%" || bad "availability ${avail}% < 99%"

record_result "$result" "$rto" "$detection" "lb01 destroyed, VIP on lb02"
[[ "$result" == pass ]]
