#!/usr/bin/env bash
# T08 — Upload an attachment through the ERP VIP and prove it exists on both nodes.
source "$(dirname "$0")/lib/common.sh"
init_test T08 "Shared attachment through the filestore"

if [[ -z "${ODOO_ADMIN_PASSWORD:-}" ]]; then
  bad "ODOO_ADMIN_PASSWORD is required for T08 (see tests/.env.example)"
  exit 1
fi

out="$(ODOO_URL="http://${ERP_VIP}" python3 "$TESTS_DIR/lib/attachment_roundtrip.py")" || {
  bad "XML-RPC attachment round-trip failed"; say "$out"; exit 1
}
id="$(jq -r '.id' <<<"$out")"
checksum="$(jq -r '.checksum' <<<"$out")"
store_fname="$(jq -r '.store_fname' <<<"$out")"
size="$(jq -r '.size' <<<"$out")"
note "attachment id=$id size=$size checksum=$checksum store_fname=$store_fname"

fail=0
if jq -e '.verified == true' <<<"$out" >/dev/null; then
  good "payload read back through the ERP VIP is identical"
else
  bad "payload read-back mismatch"
  fail=1
fi

rel="filestore/ha_erp/${store_fname}"
# The filestore is 0770 uid/gid 101 so only the Odoo uid can traverse it; use sudo here.
for host in "$ERP01" "$ERP02"; do
  if ssh_vm "$host" "sudo test -f /srv/ha-erp/filestore/${rel}"; then
    good "$host sees ${rel}"
  else
    bad "$host does not see ${rel}"
    fail=1
  fi
done

# Same inode on both nodes proves a single shared file, not two copies.
ino1="$(ssh_vm "$ERP01" "sudo stat -c %i /srv/ha-erp/filestore/${rel}" 2>/dev/null | tr -d ' \n')"
ino2="$(ssh_vm "$ERP02" "sudo stat -c %i /srv/ha-erp/filestore/${rel}" 2>/dev/null | tr -d ' \n')"
if [[ -n "$ino1" && "$ino1" == "$ino2" ]]; then
  good "same inode on both ERP nodes (${ino1})"
else
  bad "inodes differ (erp01=${ino1:-?} erp02=${ino2:-?})"
  fail=1
fi

sha="$(ssh_vm "$ERP02" "sudo sha1sum /srv/ha-erp/filestore/${rel}" 2>/dev/null | awk '{print $1}')"
if [[ "$sha" == "$checksum" ]]; then
  good "stored blob checksum matches the Odoo checksum field"
else
  bad "checksum mismatch (file=$sha odoo=$checksum)"
  fail=1
fi

[[ $fail -eq 0 ]] && { record_result pass "" "" "attachment ${id} shared erp01/erp02"; exit 0; }
record_result fail "" "" "attachment ${id} not consistently visible"
exit 1
