#!/usr/bin/env bash
# 00 — Host preflight: verify the laptop can host the lab, prepare the base image.
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

problems=0

step "Platform"
[[ "$(uname -m)" == "x86_64" ]] && ok "x86_64" || { fail "unsupported architecture"; problems=1; }
grep -qE 'vmx|svm' /proc/cpuinfo && ok "hardware virtualization flag present" \
  || { fail "VT-x/AMD-V not exposed"; problems=1; }
if [[ -r /dev/kvm && -w /dev/kvm ]]; then ok "/dev/kvm readable and writable"; else fail "/dev/kvm not accessible"; problems=1; fi

step "libvirt"
if command -v virsh >/dev/null 2>&1 && virsh -c qemu:///system version >/dev/null 2>&1; then
  ok "virsh can reach qemu:///system ($(virsh -c qemu:///system version | awk -F'[ :]' '/libvirtd/{print $NF}'))"
else
  fail "cannot reach qemu:///system"
  info "run: sudo systemctl enable --now libvirtd && sudo usermod -aG libvirt,kvm \$USER (then re-login)"
  problems=1
fi
virsh -c qemu:///system net-info "$NET_NAME" >/dev/null 2>&1 \
  && info "network $NET_NAME already defined" \
  || info "network $NET_NAME will be created by ./scripts/01-create-network.sh"

step "Tooling"
require_cmd qemu-system-x86_64 virt-install qemu-img virsh ssh-keygen curl jq ansible ansible-playbook || problems=1
info "ansible: $(ansible --version 2>/dev/null | head -1)"

step "Resources"
read -r mem_total mem_avail < <(awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}END{print t, a}' /proc/meminfo)
avail_mib=$((mem_avail / 1024))
total_mib=$((mem_total / 1024))
ok "RAM: ${total_mib} MiB total, ${avail_mib} MiB available"
if (( avail_mib < 5600 )); then
  warn "less than 5.6 GiB available; the 5 GiB VM budget may swap or OOM."
  warn "close Firefox/IDE before phase 2. (measured 16 Nov 2026: 6.1 GiB available)"
fi
free_gib=$(df -BG --output=avail /var/lib/libvirt/images 2>/dev/null | tail -1 | tr -dc '0-9')
ok "disk free for images: ${free_gib:-?} GiB"
(( ${free_gib:-0} >= 40 )) || warn "thin-provisioned VMs need ~20 GiB actual, 36 GiB virtual; space is tight"

step "SSH key"
if [[ -f "$SSH_KEY" ]]; then
  ok "key present: $SSH_KEY"
else
  ssh-keygen -t ed25519 -f "$SSH_KEY" -N '' -C "ha-erp" >/dev/null
  ok "generated $SSH_KEY"
fi
ok "public key: $(cut -c1-40 "$SSH_KEY.pub")..."

step "Base image"
if [[ -f "$BASE_IMAGE" ]]; then
  ok "cached: $BASE_IMAGE ($(du -h "$BASE_IMAGE" | cut -f1))"
else
  info "downloading Debian 13 genericcloud image (~350 MB)"
  sudo install -d -m 0770 -o "$USER" -g kvm "$IMAGES_DIR"
  if ! curl -4 -fL --retry 5 --retry-all-errors --retry-delay 5 \
    --connect-timeout 20 --progress-bar -o "${BASE_IMAGE}.part" "$IMAGE_URL"; then
    rm -f "${BASE_IMAGE}.part"
    die "could not download base image from $IMAGE_URL; check host connectivity and re-run ./scripts/00-host-preflight.sh"
  fi
  mv "${BASE_IMAGE}.part" "$BASE_IMAGE"
  ok "downloaded to $BASE_IMAGE"
fi
qemu-img info "$BASE_IMAGE" | awk -F': ' '/virtual size/{print "  [info] virtual size: " $2}'

step "Privileges"
if sudo -n true 2>/dev/null; then
  ok "passwordless sudo available"
else
  warn "sudo will prompt for a password (needed for libvirt images/domains and the NFS export)"
  info "one-time: sudo systemctl enable --now libvirtd"
fi

step "Existing lab state"
if [[ -d /srv/ha-erp/filestore/.fence ]] && [[ -n "$(ls -A /srv/ha-erp/filestore/.fence 2>/dev/null)" ]]; then
  warn "fence markers present: $(ls /srv/ha-erp/filestore/.fence | tr '\n' ' ')"
  info "a fenced node will refuse to start PostgreSQL/Keepalived — run db-rejoin or clear them deliberately"
fi
for vm in "${VM_ORDER[@]}"; do
  if domain_exists "$vm"; then
    warn "$vm exists ($(domain_state "$vm")) — ./scripts/02-create-vms.sh will skip it"
  else
    info "$vm not defined"
  fi
done

echo
if (( problems > 0 )); then
  die "preflight found blocking problems; fix them and re-run"
fi
ok "preflight passed — next: ./scripts/01-create-network.sh"
