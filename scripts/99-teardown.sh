#!/usr/bin/env bash
# 99 — Destroy the lab (VMs + network). The Debian base image is kept.
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    -y|--yes) ASSUME_YES=1 ;;
    -h|--help) echo "usage: $0 [-y]"; exit 0 ;;
    *) die "unknown argument: $arg" ;;
  esac
done

confirm "Destroy ${#VM_ORDER[@]} VMs and network $NET_NAME? Overlays and cloud-init data are deleted." || exit 0

for name in "${VM_ORDER[@]}"; do
  step "VM $name"
  if ! domain_exists "$name"; then
    info "not defined"
    continue
  fi
  state="$(domain_state "$name")"
  if [[ "$state" != "shut off" ]]; then
    info "destroying ($state)"
    virsh destroy "$name" >/dev/null || true
  fi
  virsh undefine "$name" --remove-all-storage >/dev/null 2>&1 \
    || sudo virsh undefine "$name" --remove-all-storage \
    || { sudo rm -f "$IMAGES_DIR/${name}.qcow2"; virsh undefine "$name" || true; }
  sudo rm -rf "${IMAGES_DIR:?}/cloud-init/${name}"
  ok "removed"
done

step "Network $NET_NAME"
if virsh net-info "$NET_NAME" >/dev/null 2>&1; then
  virsh net-destroy "$NET_NAME" >/dev/null 2>&1 || true
  virsh net-undefine "$NET_NAME" >/dev/null 2>&1 || sudo virsh net-undefine "$NET_NAME"
  ok "removed"
else
  info "not defined"
fi

echo
ok "lab destroyed. Base image kept at $BASE_IMAGE"
