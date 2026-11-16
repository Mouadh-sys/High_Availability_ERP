#!/usr/bin/env bash
# T05 — Restore lb01: it must reclaim the VIP without flapping the service.
source "$(dirname "$0")/lib/common.sh"
init_test T05 "Restore lb01 and reclaim VIP"

if ! virsh domstate lb02 >/dev/null 2>&1; then
  bad "lb02 is not defined — run T04 first"; exit 1
fi

wait_until 20 "baseline 200" code_is 200 || exit 1
note "VIP currently on $(vip_lb)"

start_probe
t0=$(now)
if [[ "$(virsh domstate lb01 2>/dev/null)" != "running" ]]; then
  virsh start lb01 >/dev/null 2>&1 || bad "could not start lb01"
fi
wait_until 90 "lb01 reachable over SSH" ssh_vm "$LB01" true || true
wait_until 120 "VIP back on lb01" lb_is lb01 || true
rto="$(probe_rto "$t0")"
stop_probe

avail="$(probe_availability)"
note "rto=${rto:-?}s availability=${avail}% | x-lb=$(vip_lb)"
ssh_vm "$LB01" 'sudo tail -n 3 /var/log/ha-erp/vip-transitions.log' 2>/dev/null | sed 's/^/  /' || true

if [[ "$(vip_lb)" == "lb01" ]]; then
  good "preemption returned the VIP to lb01"
  result=pass
else
  bad "VIP did not return to lb01 (x-lb=$(vip_lb))"
  result=fail
fi
[[ "${avail%%.*}" -ge 99 ]] && good "availability ${avail}% >= 99%" || bad "availability ${avail}% < 99%"

record_result "$result" "$rto" "" "lb01 restored, VIP reclaimed"
[[ "$result" == pass ]]
