#!/usr/bin/env bash
# 02 — Create the four VMs from the Debian 13 cloud image with cloud-init.
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

[[ -f "$BASE_IMAGE" ]] || die "base image missing: $BASE_IMAGE (run ./scripts/00-host-preflight.sh)"
[[ "$(virsh net-info "$NET_NAME" 2>/dev/null | awk '/^Active/{print $2}')" == "yes" ]] \
  || die "network $NET_NAME is not active (run ./scripts/01-create-network.sh)"
[[ -f "$SSH_KEY.pub" ]] || die "SSH public key missing: $SSH_KEY.pub"

step "Requesting sudo for image storage and domain creation"
sudo -v || die "sudo is required (libvirt images live in $IMAGES_DIR)"
sudo install -d -m 0770 -o "$USER" -g kvm "$IMAGES_DIR"
CLOUD_DIR="$IMAGES_DIR/cloud-init"
mkdir -p "$CLOUD_DIR"

TZ_VALUE="${HA_ERP_TZ:-Africa/Tunis}"
KEY_VALUE="$(cat "$SSH_KEY.pub")"

render_cloud_init() { # render_cloud_init <name>
  local name="$1" fqdn="${1}.ha-erp.lab" dir="$CLOUD_DIR/$1"
  mkdir -p "$dir"
  cat > "$dir/meta-data" <<EOF
instance-id: ha-erp-${name}
local-hostname: ${name}
EOF
  cat > "$dir/user-data" <<EOF
#cloud-config
hostname: ${name}
fqdn: ${fqdn}
manage_etc_hosts: true
preserve_hostname: false
timezone: ${TZ_VALUE}
growpart:
  mode: auto
  devices: ['/']
resize_rootfs: true
users:
  - name: debian
    gecos: Debian
    groups: [sudo, adm]
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - ${KEY_VALUE}
ssh_pwauth: false
disable_root: true
package_update: true
packages:
  - qemu-guest-agent
  - curl
  - ca-certificates
  - jq
runcmd:
  - [ systemctl, enable, --now, qemu-guest-agent ]
  - [ sh, -c, "grep -q 'erp.ha-erp.lab' /etc/hosts || printf '%s\\n' '192.168.50.1 host.ha-erp.lab host' '192.168.50.10 erp.ha-erp.lab erp' '192.168.50.11 lb01.ha-erp.lab lb01' '192.168.50.12 lb02.ha-erp.lab lb02' '192.168.50.21 erp01.ha-erp.lab erp01' '192.168.50.22 erp02.ha-erp.lab erp02' >> /etc/hosts" ]
EOF
  ok "cloud-init rendered: $dir"
}

created=()
for name in "${VM_ORDER[@]}"; do
  step "VM $name"
  if domain_exists "$name"; then
    info "already defined ($(domain_state "$name")) — skipping"
    continue
  fi

  ram="$(vm_ram "$name")"
  vcpu="$(vm_cpu "$name")"
  disk="$(vm_disk "$name")"
  mac="$(vm_mac "$name")"
  ip="$(vm_ip "$name")"
  overlay="$IMAGES_DIR/${name}.qcow2"

  render_cloud_init "$name"

  if [[ ! -f "$overlay" ]]; then
    info "creating ${disk}G thin overlay"
    sudo qemu-img create -q -f qcow2 -F qcow2 -b "$BASE_IMAGE" "$overlay" "${disk}G"
  else
    info "reusing existing overlay $overlay"
  fi

  info "defining domain: ${vcpu} vCPU, ${ram} MiB, ${mac} -> ${ip}"
  sudo virt-install \
    --name "$name" \
    --memory "$ram" \
    --vcpus "$vcpu" \
    --cpu host-passthrough \
    --disk "path=${overlay},bus=virtio,cache=none" \
    --import \
    --network "network=${NET_NAME},model=virtio,mac=${mac}" \
    --cloud-init "user-data=${CLOUD_DIR}/${name}/user-data,meta-data=${CLOUD_DIR}/${name}/meta-data" \
    --os-variant debian12 \
    --graphics none \
    --noautoconsole \
    --autostart >/dev/null

  created+=("$name")
  ok "defined and booting"
done

step "Waiting for SSH (cloud-init may take 60-120 s per VM)"
for name in "${VM_ORDER[@]}"; do
  ip="$(vm_ip "$name")"
  if wait_for_ssh "$ip" 240; then
    ok "$name reachable at $ip ($(ssh "${SSH_OPTS[@]}" "debian@$ip" 'hostname; . /etc/os-release; echo $PRETTY_NAME' | tr '\n' ' '))"
  else
    warn "$name not reachable yet — check: virsh console $name (login via cloud-init user 'debian')"
  fi
done

step "Leases"
virsh net-dhcp-leases "$NET_NAME" | sed 's/^/  /'

step "Summary"
printf '  %-7s %-16s %-6s %-6s %-7s\n' VM ADDRESS vCPU RAM DISK
for name in "${VM_ORDER[@]}"; do
  printf '  %-7s %-16s %-6s %-6s %-7s\n' "$name" "$(vm_ip "$name")" "$(vm_cpu "$name")" \
    "$(vm_ram "$name")M" "$(vm_disk "$name")G"
done
echo
ok "VMs provisioned — next: make bootstrap && make site (see docs/deployment-guide.md)"
info "user: debian, key: $SSH_KEY, no password login"
