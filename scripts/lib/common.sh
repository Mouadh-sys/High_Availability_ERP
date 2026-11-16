#!/usr/bin/env bash
# Shared helpers for host-side scripts. Source, do not execute.
# shellcheck shell=bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

NET_NAME="${HA_ERP_NET:-ha-erp-net}"
IMAGES_DIR="${HA_ERP_IMAGES_DIR:-/var/lib/libvirt/images/ha-erp}"
BASE_IMAGE="${HA_ERP_BASE_IMAGE:-${IMAGES_DIR}/debian-13-genericcloud-amd64.qcow2}"
IMAGE_URL="${HA_ERP_IMAGE_URL:-https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2}"
SSH_KEY="${HA_ERP_SSH_KEY:-$HOME/.ssh/ha_erp_ed25519}"
SSH_OPTS=(-i "$SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5)

# name|ram_mb|vcpus|disk_gb|mac|ip
VM_SPECS=(
  "lb01|512|1|6|52:54:00:50:00:11|192.168.50.11"
  "lb02|512|1|6|52:54:00:50:00:12|192.168.50.12"
  "erp01|2048|2|12|52:54:00:50:00:21|192.168.50.21"
  "erp02|2048|2|12|52:54:00:50:00:22|192.168.50.22"
)
VM_ORDER=(erp01 erp02 lb01 lb02)

if [[ -t 1 ]]; then
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_OK=''; C_WARN=''; C_ERR=''; C_DIM=''; C_OFF=''
fi

ok()   { printf '  %s[ok]%s   %s\n'   "$C_OK"   "$C_OFF" "$*"; }
warn() { printf '  %s[warn]%s %s\n'   "$C_WARN" "$C_OFF" "$*"; }
fail() { printf '  %s[fail]%s %s\n'   "$C_ERR"  "$C_OFF" "$*" >&2; }
info() { printf '  %s[info]%s %s\n'   "$C_DIM"  "$C_OFF" "$*"; }
step() { printf '\n%s==>%s %s\n' "$C_OK" "$C_OFF" "$*"; }
die()  { fail "$*"; exit 1; }

require_cmd() {
  local missing=0 c
  for c in "$@"; do
    if command -v "$c" >/dev/null 2>&1; then ok "$c"; else fail "$c not found"; missing=1; fi
  done
  return "$missing"
}

vm_field() { # vm_field <name> <field index 1..6>
  local name="$1" idx="$2" spec
  for spec in "${VM_SPECS[@]}"; do
    [[ "${spec%%|*}" == "$name" ]] || continue
    awk -F'|' -v i="$idx" '{print $i}' <<<"$spec"
    return 0
  done
  die "unknown VM: $name"
}

vm_ram()  { vm_field "$1" 2; }
vm_cpu()  { vm_field "$1" 3; }
vm_disk() { vm_field "$1" 4; }
vm_mac()  { vm_field "$1" 5; }
vm_ip()   { vm_field "$1" 6; }

domain_exists() { virsh dominfo "$1" >/dev/null 2>&1; }
domain_state()  { virsh domstate "$1" 2>/dev/null || echo "undefined"; }

wait_for_ssh() { # wait_for_ssh <ip> <seconds>
  local ip="$1" deadline=$((SECONDS + ${2:-180}))
  until ssh "${SSH_OPTS[@]}" "debian@${ip}" true 2>/dev/null; do
    (( SECONDS < deadline )) || return 1
    sleep 3
  done
}

confirm() {
  local prompt="${1:-Continue?}"
  [[ "${ASSUME_YES:-0}" == "1" ]] && return 0
  read -r -p "$prompt [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}
