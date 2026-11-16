# HA ERP — High-Availability Odoo Platform

Design, deployment, and failure validation of a high-availability **Odoo Community** platform on a
single KVM/libvirt host, with redundant application nodes, redundant load balancers, PostgreSQL
streaming replication, and a shared NFS filestore.

> **Project state: scaffold ready, infrastructure not yet provisioned.**
> The repository contains the complete deployment code, configuration templates, runbooks, and
> failure-test harness. Provisioning needs a handful of interactive `sudo` commands (enable
> `libvirtd` once, then the preflight/VM scripts reuse the cached credential); everything after that
> is automated. See [Quick start](#quick-start).

---

## 1. Topology

| Node | Role | Services | vCPU / RAM / Disk | Address |
|------|------|----------|-------------------|---------|
| `lb01` | Load balancer (MASTER) | HAProxy, Keepalived | 1 / 512 MB / 6 GB | 192.168.50.11 |
| `lb02` | Load balancer (BACKUP) | HAProxy, Keepalived | 1 / 512 MB / 6 GB | 192.168.50.12 |
| `erp01` | Application + DB primary | Odoo 17 (Docker), PostgreSQL 16, Keepalived | 2 / 2 GB / 12 GB | 192.168.50.21 |
| `erp02` | Application + DB standby | Odoo 17 (Docker), PostgreSQL 16, Keepalived | 2 / 2 GB / 12 GB | 192.168.50.22 |
| host | Virtualization + NFS | libvirt, NFS server | — | 192.168.50.1 |

```
                    ┌─────────────────────────────┐
   browser ────────▶│  ERP VIP 192.168.50.10:80   │
                    └──────────────┬──────────────┘
                                   │  (Keepalived VRRP, unicast)
                    ┌──────────────┴──────────────┐
                    │                             │
                 ┌──▼───┐                     ┌───▼──┐
                 │ lb01 │  HAProxy            │ lb02 │  HAProxy
                 └──┬───┘  roundrobin+cookie  └──┬───┘
                    │                             │
            ┌───────┴─────────┬───────────────────┘
            │                 │
       ┌────▼─────┐      ┌────▼─────┐
       │  erp01   │◀────▶│  erp02   │   PostgreSQL streaming replication
       │ Odoo + PG│ WAL  │ Odoo + PG│   (primary ⇄ standby)
       └────┬─────┘      └────┬─────┘
            │   NFS 2049      │
       ┌────▼─────────────────▼────┐
       │  host: /srv/ha-erp/filestore  │
       └───────────────────────────────┘
            DB VIP 192.168.50.30:5432
```

Full diagrams and design rationale: [`docs/architecture.md`](docs/architecture.md),
[`docs/network-design.md`](docs/network-design.md).

---

## 2. Host reality check (measured, 16 Nov 2026)

| Resource | Measured | Impact |
|----------|----------|--------|
| CPU | 8 threads, i5-11300H, VT-x enabled | 6 vCPU allocated → safe overcommit |
| RAM | 15 GiB total, **6.1 GiB available** | Binding constraint. VM budget reduced from 8 GiB to **5 GiB** |
| Disk | 53 GiB free on `/`, 40 GiB on `/data` | 36 GiB thin-provisioned, ~20 GiB actual |
| KVM / libvirt | Installed, `libvirtd` **inactive**, user in `libvirt`+`kvm` groups | Requires one `sudo systemctl enable --now libvirtd` |
| Tooling | `virt-install`, `qemu-img`, `virsh`, Ansible 2.16, `psql` 16, `socat`, `jq` | Ready |
| Docker | Engine 29.1.3 on host (host-side only; guests install their own) | Ready |

The original 3 GB-per-ERP-node proposal does not fit in the currently available memory. The plan
therefore uses **2 GiB per ERP node** with Odoo `workers = 2` and PostgreSQL `shared_buffers = 192 MB`.
See [`docs/decisions.md`](docs/decisions.md) ADR-002. Close Firefox / heavy apps before running the
failure tests, or the OOM killer — not the architecture — will decide the test outcome.

---

## 3. Quick start

All commands run from the repository root on the Pop!_OS host.

```bash
# 0. One-time privilege step (the daemon is inactive on a fresh install)
sudo systemctl enable --now libvirtd

# 1. Preflight: checks tooling, RAM/disk, SSH key; downloads the Debian 13 image
#    (prompts for sudo once; credentials are cached for the next ~15 minutes)
./scripts/00-host-preflight.sh

# 2. Virtual network (192.168.50.0/24, NAT, DHCP reservations) — no sudo needed
./scripts/01-create-network.sh

# 3. Four VMs from the Debian 13 cloud image (cloud-init, SSH key, qemu-guest-agent)
./scripts/02-create-vms.sh

# 4. Configure everything with Ansible (vault password prompt)
export ANSIBLE_VAULT_PASSWORD_FILE=~/.config/ha-erp/vault-pass
make bootstrap      # base OS, firewall, SSH, NTP
make site           # NFS, PostgreSQL + replication, Odoo, HAProxy, Keepalived

# 5. Prove it works
make verify         # health report written to evidence/verify-<timestamp>.json
make test           # T01–T09 failure-injection suite
```

Prerequisites for step 4: generate the secrets file once.

```bash
mkdir -p ~/.config/ha-erp
cp ansible/vault.yml.example ansible/group_vars/all/vault.yml
ansible-vault encrypt ansible/group_vars/all/vault.yml
```

`make help` lists every target.

---

## 4. Repository map

```
├── docs/                      requirements, architecture, network, runbooks, tests, limitations
├── diagrams/                  Mermaid sources (logical, network, DB failover)
├── infra/libvirt/             libvirt network definition (ha-erp-net)
├── scripts/                   host provisioning, VM lifecycle, teardown
├── ansible/
│   ├── inventory/             static inventory of the four VMs
│   ├── group_vars/            topology, ports, paths (secrets in all/vault.yml)
│   ├── playbooks/             site, bootstrap, verify, db-failover, db-rejoin
│   └── roles/                 common, nfs_server, nfs_client, postgres, odoo, haproxy
├── configs/                   pointer to templates (single source of truth)
├── tests/                     T01–T09 failure-injection harness + evidence capture
├── evidence/                  timestamped test output (git-ignored except results index)
└── architecture.md            original design brief / scratch notes
```

---

## 5. Locked decisions

| # | Decision | Rationale |
|---|----------|-----------|
| ADR-001 | Odoo **17.0 Community**, official Docker image | Debian 13 ships Python 3.13; native Odoo 17 packages target Python 3.10/3.11 → container isolates the runtime |
| ADR-002 | 2 GiB per ERP node, 512 MB per LB | Measured host memory (6.1 GiB available) |
| ADR-003 | PostgreSQL **16** from PGDG, native on the guests | Streaming replication, `pg_basebackup`, VIP and fencing stay simple; DB never runs in a container |
| ADR-004 | **Unicast** VRRP | libvirt NAT bridges do not reliably forward VRRP multicast |
| ADR-005 | Deterministic addressing via libvirt DHCP reservations | Equivalent to static for this lab, no guest-side network config drift |
| ADR-006 | DB VIP follows role via a binary-mode `vrrp_script` (weight 0 ⇒ FAULT) | One static Keepalived config on both nodes; a standby releases the VIP instead of advertising it for a read-only DB |
| ADR-007 | Controlled failover; hard fence by `virsh destroy` (default) | Prevents split-brain; automatic promotion is explicitly out of scope |
| ADR-008 | Re-bootstrap standby with `pg_basebackup` instead of `pg_rewind` | Simpler, reproducible, acceptable data volume for the lab |
| ADR-009 | Health checks on `GET /web/login` | Odoo 17 has no dedicated health endpoint; `/web/login` exercises the DB |

Full text: [`docs/decisions.md`](docs/decisions.md).

---

## 6. What success looks like

* `http://192.168.50.10` serves Odoo continuously while either ERP node or either LB node is stopped.
* `X-LB` response header identifies the LB holding the VIP; HAProxy stats show backend states.
* `SELECT pg_is_in_recovery()` through the DB VIP flips from `t` to `f` after promotion.
* An attachment uploaded through `erp01` is readable from `erp02`'s filestore mount.
* Every test produces timestamped evidence and RTO/RPO numbers in `evidence/results.jsonl`.

---

## 7. Limitations (documented, not hidden)

Single physical host, NFS on the host, asynchronous replication, manual DB promotion, combined
application/database failure domains, and lab-grade security. See
[`docs/limitations.md`](docs/limitations.md).
