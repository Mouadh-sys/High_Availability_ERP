#!/usr/bin/env bash
# 01 — Create and start the ha-erp-net libvirt network.
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

XML="$ROOT_DIR/infra/libvirt/ha-erp-net.xml"
[[ -f "$XML" ]] || die "missing $XML"

step "Network $NET_NAME"
if virsh net-info "$NET_NAME" >/dev/null 2>&1; then
  ok "already defined"
  if [[ "$(virsh net-info "$NET_NAME" | awk '/^Active/{print $2}')" != "yes" ]]; then
    info "starting"
    virsh net-start "$NET_NAME"
  fi
else
  info "defining from $XML"
  virsh net-define "$XML"
  virsh net-autostart "$NET_NAME"
  virsh net-start "$NET_NAME"
  ok "created"
fi

step "Waiting for the bridge"
for _ in {1..20}; do
  [[ "$(virsh net-info "$NET_NAME" | awk '/^Active/{print $2}')" == "yes" ]] && break
  sleep 1
done
ip link show virbr50 >/dev/null 2>&1 && ok "virbr50 up ($(ip -4 -o addr show virbr50 | awk '{print $4}'))" \
  || die "virbr50 not present"

step "Summary"
virsh net-dumpxml "$NET_NAME" | sed -n '/<ip address/,/<\/dhcp>/p' | sed 's/^/  /'
echo
ok "reservations: .11 lb01, .12 lb02, .21 erp01, .22 erp02 | VIPs .10 and .30 are outside DHCP"
info "next: ./scripts/02-create-vms.sh"
