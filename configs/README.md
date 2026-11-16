# configs/

This directory intentionally contains **no copied configuration files**.

The canonical source for every rendered configuration is the Ansible role that owns it. Duplicating
`haproxy.cfg` or `keepalived.conf` here would create a second source of truth that silently drifts
from what is actually deployed — the classic way to make a report disagree with the lab.

| Deployed file | Template |
|---------------|----------|
| `/etc/haproxy/haproxy.cfg` | `ansible/roles/haproxy/templates/haproxy.cfg.j2` |
| `/etc/keepalived/keepalived.conf` (lb) | `ansible/roles/haproxy/templates/keepalived-lb.conf.j2` |
| `/etc/keepalived/keepalived.conf` (erp) | `ansible/roles/postgres/templates/keepalived-db.conf.j2` |
| `/etc/postgresql/16/main/conf.d/99-ha-erp.conf` | `ansible/roles/postgres/templates/99-ha-erp.conf.j2` |
| `/etc/postgresql/16/main/pg_hba.conf` | `ansible/roles/postgres/templates/pg_hba.conf.j2` |
| `/etc/exports` (hypervisor) | `ansible/roles/nfs_server/templates/exports.j2` |
| `/opt/ha-erp/odoo/odoo.conf` | `ansible/roles/odoo/templates/odoo.conf.j2` |
| `/opt/ha-erp/odoo/docker-compose.yml` | `ansible/roles/odoo/templates/docker-compose.yml.j2` |
| `/etc/systemd/system/ha-erp-odoo.service` | `ansible/roles/odoo/templates/ha-erp-odoo.service.j2` |

To inspect what is *actually* deployed on a node, read the file from the node:

```bash
ssh debian@192.168.50.11 'cat /etc/haproxy/haproxy.cfg'
ssh debian@192.168.50.21 'sudo cat /etc/postgresql/16/main/pg_hba.conf'
```

If a rendered snapshot is needed for the report, capture it with timestamps under `evidence/`:

```bash
mkdir -p evidence/config-snapshot
for ip in 192.168.50.11 192.168.50.12 192.168.50.21 192.168.50.22; do
  ssh debian@"$ip" "sudo tar czf - /etc/haproxy /etc/keepalived /etc/postgresql" \
    > "evidence/config-snapshot/${ip}.tar.gz"
done
```
