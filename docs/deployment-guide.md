# Deployment Guide

Everything below is executed from the repository root on the Pop!_OS host. Steps 1–2 need
interactive `sudo`; the rest runs through Ansible.

## 0. Prerequisites

```bash
# Host packages assumed present (verified 16 Nov 2026):
# qemu-system-x86_64, virt-install, virsh, qemu-img, ansible-core 2.16, psql 16, socat, jq, openssl
sudo systemctl enable --now libvirtd          # currently inactive on this host
sudo usermod -aG libvirt,kvm "$USER"          # already the case; re-login if changed
virsh -c qemu:///system list                  # must work without sudo
```

Secrets (once):

```bash
mkdir -p ~/.config/ha-erp
cp ansible/vault.yml.example ansible/group_vars/all/vault.yml
# edit values, then:
ansible-vault encrypt ansible/group_vars/all/vault.yml
echo "$HOME/.config/ha-erp/vault-pass" >/dev/null   # or create the file with your password
export ANSIBLE_VAULT_PASSWORD_FILE=~/.config/ha-erp/vault-pass
```

Create the SSH key the VMs will trust (the preflight script does this if missing):

```bash
ssh-keygen -t ed25519 -f ~/.ssh/ha_erp_ed25519 -N '' -C ha-erp
```

The vault keys and where they are used:

| Vault key | Used for |
|-----------|----------|
| `vault_become_password` | `sudo` on the hypervisor (Ansible `become` for the NFS role) |
| `vault_odoo_master_password` | Odoo `admin_passwd` (database manager), never used as a login |
| `vault_odoo_admin_password` | `admin` **login** password, enforced after `-i base`; also copied into `tests/.env` as `ODOO_ADMIN_PASSWORD` |
| `vault_odoo_db_password` | PostgreSQL role `odoo`, read by Odoo over the DB VIP |
| `vault_replication_password` | PostgreSQL role `replicator` (streaming replication, `pg_basebackup`) |
| `vault_keepalived_auth_pass` | VRRP authentication for both Keepalived instances |

## 1. Preflight

```bash
./scripts/00-host-preflight.sh
```

Checks: KVM access, libvirt connectivity, free RAM/disk, required binaries, SSH key, Debian 13 cloud
image (downloads it once into `/var/lib/libvirt/images/ha-erp/`). It prints the exact `sudo` commands
for anything it cannot change itself. Expected: `[ok]` for every line, memory warning if available RAM < 6 GiB.

## 2. Network and VMs

```bash
./scripts/01-create-network.sh     # defines + starts ha-erp-net, waits for virbr50
./scripts/02-create-vms.sh         # debian-13 base -> 4 overlays, cloud-init, virt-install
```

The VM script starts `lb02`, `erp02`, and `lb01` after `erp01` (database first), waits for SSH on
each address, and prints a table of addresses. Typical cold creation: 2–4 minutes.

Verify:

```bash
virsh list --all
virsh net-dhcp-leases ha-erp-net
ssh -i ~/.ssh/ha_erp_ed25519 debian@192.168.50.21 'hostname -f; free -m'
```

## 3. Base configuration (bootstrap)

```bash
cd ansible
ansible all -m ping                       # 4 VMs + hypervisor
ansible-playbook playbooks/bootstrap.yml
ansible-playbook playbooks/bootstrap.yml  # second run must report changed=0
```

`bootstrap.yml` applies: apt update/upgrade policy, base packages, timezone/NTP, `/etc/hosts`,
SSH hardening (keys only, no root), ufw with the port matrix from `docs/network-design.md`, and
`unattended-upgrades`.

## 4. Full deployment

```bash
cd ansible
ansible-playbook playbooks/site.yml
```

Order enforced by the playbook:

1. **hypervisor** — NFS server (`nfs_server`), export `/srv/ha-erp/filestore` to `.21/.22`.
2. **erp** — PGDG repo, PostgreSQL 16, `99-ha-erp.conf`, `pg_hba.conf`; primary creates roles/db;
   standby clones with `pg_basebackup -R`; then `nfs_client`, then `odoo` (image pull, config,
   compose unit), then the DB VIP Keepalived instance.
3. **lb** — HAProxy config, stats socket, Keepalived `ERP_VIP`, VIP transition log.

First run pulls `odoo:17.0` (~600 MB compressed) on both ERP nodes; allow 10–15 minutes on a slow
link. The database is initialised on `erp01` only (`odoo_init_db: true`): `-i base --stop-after-init`.

Expected final state:

```bash
curl -sI http://192.168.50.10/web/login | head -3      # HTTP/1.1 200 OK, X-LB: lb01
sql="select pg_is_in_recovery();"
PGPASSWORD="$ODOO_DB_PASSWORD" psql -h 192.168.50.30 -U odoo -d ha_erp -c "$sql"   # f
virsh net-dhcp-leases ha-erp-net
```

## 5. Smoke test before failure testing

```bash
cp tests/.env.example tests/.env     # fill in ODOO_DB_PASSWORD and ODOO_ADMIN_PASSWORD
make verify                          # writes evidence/verify-<ts>.json
make test-fast                       # T01–T03
```

Snapshots (recommended before destructive tests):

```bash
for d in erp01 erp02 lb01 lb02; do
  virsh snapshot-create-as "$d" "pre-test-$(date +%Y%m%d)" --description "before failure tests"
done
```

Note: internal snapshots of qcow2 disks are fine for this lab; remove them with
`virsh snapshot-delete <vm> <name>` once the tests are recorded.

## 6. Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `virsh` asks for authentication | user not in `libvirt` group or daemon down | `sudo systemctl enable --now libvirtd`, re-login |
| VM has 169.254.x.x address | DHCP reservation MAC mismatch | `virsh dumpxml <vm> | grep mac`, compare with `ha-erp-net.xml` |
| `ansible all -m ping` unreachable | cloud-init still running, or key not trusted | wait 60 s, `virsh console <vm>`, check `/var/log/cloud-init-output.log` |
| HAProxy returns 503 | both backends marked DOWN | check `/web/login` on `.21/.22`; `curl -s http://192.168.50.10:8404/stats;csv` |
| HAProxy 502 but Odoo answers locally | Odoo bound to 127.0.0.1 | `http_interface = 0.0.0.0` in `odoo.conf` |
| Odoo login loops / CSRF errors | `proxy_mode` off, or session dir not shared | `proxy_mode = True`; check NFS mount on both nodes |
| Odoo `database not found` | `dbfilter`/`db_name` mismatch | DB must be `ha_erp`, `dbfilter = ^ha_erp$` |
| `pg_basebackup` auth failure | wrong replication password or `pg_hba` | `psql "host=192.168.50.21 user=replicator replication=database"`, compare vault value |
| Standby not streaming | `primary_conninfo` wrong / slot missing | `pg_stat_replication` on primary, `pg_wal` on standby, `journalctl -u postgresql@16-main` |
| VIP does not move on LB failure | VRRP blocked | `tcpdump -ni virbr50 proto 112` on host; ufw rule for 112; check `unicast_peer` |
| Odoo cannot write attachments | NFS export uid mismatch | export owned `101:101`, mount `rw`, `sudo -u '#101' touch /srv/ha-erp/filestore/x` |
| Both ERP instances claim DB primary | role files not flipped during failover | `cat /etc/ha-erp/db-role` on both; only one may say `primary`; use `db-rejoin.yml` to fix |
| PG/Keepalived will not start on a rebooted ERP node | fence marker from a previous failover (ADR-007) | `ls /srv/ha-erp/filestore/.fence/`; run `make db-rejoin` (it clears the marker after re-cloning) — never delete the marker by hand unless the node is known rebuilt |

## 7. Teardown / rebuild

```bash
./scripts/99-teardown.sh -y        # destroys VMs + network, keeps the Debian image
make net vms site                  # rebuild from code
```
