# Requirements and Traceability

Every requirement carries an implementation artefact and a verification method. A requirement
without a test is a wish; the table below is the contract used in the report.

Legend — **Status**: `scaffolded` (code exists, not yet executed) · `verified` (test evidence in
`evidence/`) · `partial` · `deferred`.

## 1. Functional requirements

| ID | Requirement | Implementation | Verification | Status |
|----|-------------|----------------|--------------|--------|
| FR-01 | ERP access through a single virtual IP | Keepalived `ERP_VIP` = 192.168.50.10 on lb01/lb02 (`roles/haproxy/templates/keepalived-lb.conf.j2`) | `curl http://192.168.50.10/web/login` | scaffolded |
| FR-02 | Load distributed across healthy ERP instances | HAProxy `balance roundrobin` + cookie persistence (`haproxy.cfg.j2`) | `tests/t01-baseline.sh` samples backend assignment from stats CSV | scaffolded |
| FR-03 | Both ERP instances operational concurrently | Odoo container + `ha-erp-odoo.service` on both nodes | T01: two `UP` servers in HAProxy stats | scaffolded |
| FR-04 | ERP remains reachable when one app instance fails | HAProxy `option httpchk GET /web/login`, `fall 2` | T02 / T03 | scaffolded |
| FR-05 | Access VIP moves to the secondary LB | Keepalived priorities 150/100 + `chk_haproxy` | T04 / T05, `X-LB` header + VRRP log | scaffolded |
| FR-06 | Standby receives changes from primary | `wal_level=replica`, replication slot, `pg_basebackup -R` | `pg_stat_replication`, replay lag in `verify.yml` | scaffolded |
| FR-07 | Standby promotable through a controlled procedure | `playbooks/db-failover.yml` (fence → promote → VIP) | T06 / T07 | scaffolded |
| FR-08 | Both app instances reconnect via DB VIP | Odoo `db_host = 192.168.50.30`, containers restarted after promotion | T07 write/read check | scaffolded |
| FR-09 | Attachments accessible from both instances | NFS export from host, bind mount at `/var/lib/odoo` | T08 attachment round-trip | scaffolded |
| FR-10 | Ansible reproduces configuration | 6 roles, 5 playbooks, inventory + group_vars | `make site` from clean VMs; `make syntax` | scaffolded |
| FR-11 | Health and replication status inspectable | HAProxy stats CSV/UI, `verify.yml` report, replication SQL | `make verify` output | scaffolded |

## 2. Non-functional requirements

| ID | Requirement | Target (lab) | Verification |
|----|-------------|--------------|--------------|
| NFR-01 | Availability during app/LB failure | ≥ 99 % of probe requests succeed during T02–T05 | `tests/lib/probe.sh` counters |
| NFR-02 | Application failover (RTO) | ≤ 10 s from process stop to all requests served by the survivor | T02, T03 (probe-derived) |
| NFR-03 | LB failover (RTO) | ≤ 5 s (VRRP advert 1 s, 3 missed adverts) | T04 |
| NFR-04 | DB failover (RTO) | ≤ 120 s including operator action and Odoo restart | T06/T07 |
| NFR-05 | RPO | Reported as measured WAL lag at failure, not assumed zero | T06 (`pg_last_wal_receive_lsn` diff) |
| NFR-06 | Concurrency | 20 concurrent browser sessions without errors | T01 smoke loop |
| NFR-07 | Recoverability | Documented, rehearsed runbooks for app, LB, DB | `docs/failover-procedures.md` |
| NFR-08 | Maintainability | Idempotent playbooks; second `make site` reports 0 changed critical tasks | `--check`/rerun |
| NFR-09 | Resource footprint | ≤ 5 GiB guest RAM, ≤ 70 % host CPU at idle | `free -h`, `virsh domstats` |

## 3. Security requirements

| ID | Requirement | Implementation |
|----|-------------|----------------|
| SR-01 | Virtual infrastructure isolated | Dedicated `ha-erp-net` (192.168.50.0/24, NAT) |
| SR-02 | Admin access restricted | SSH keys only, `PermitRootLogin no`, firewall source `192.168.50.0/24` |
| SR-03 | PostgreSQL exposure limited | `pg_hba.conf`: `odoo` from ERP nodes only; `replicator` per-host |
| SR-04 | NFS export limited | `/etc/exports` lists ERP01 and ERP02 only |
| SR-05 | Only required ports exposed | ufw default deny inbound; 80/443 on LB, 8069 from LB only, 5432 from peers |
| SR-06 | No secrets in Git | `vault.yml` encrypted, `.gitignore` enforced; passwords injected via templates |
| SR-07 | Least privilege | Odoo container non-root (UID 101); `postgres`/`replicator` dedicated roles |
| SR-08 | Patching | `unattended-upgrades` on guests, PGDG + Debian security repositories |
| SR-09 | TLS | Optional self-signed HAProxy frontend (`haproxy_tls`), documented as lab-only |

## 4. Out of scope (explicit)

Multi-datacenter, multi-host hypervisor cluster, Kubernetes, automatic DB failover with quorum,
synchronous replication, distributed/enterprise storage, Odoo application development, zero data
loss guarantee, production hardening of TLS/PKI and secrets management.
