# Architecture Decision Records

Decisions are recorded before implementation so the report can justify each choice instead of
reconstructing it after the fact. Status values: **locked**, **provisional**, **superseded**.

---

## ADR-001 — Odoo 17 Community, deployed as a container

**Status:** locked · 16 Nov 2026

**Context.** Odoo 17 Community is the project baseline. Debian 13 (trixie) ships Python 3.13, while
Odoo 17's upstream packaging and many of its dependencies target Python 3.10–3.11. Native `.deb`
installation on trixie is therefore fragile, and the one-week schedule cannot absorb dependency
archaeology.

**Decision.** Run the official `odoo:17.0` image with Docker Engine + Compose v2. The container runs
with `network_mode: host` so that ports, source addresses, Keepalived, and HAProxy behave exactly as
in a native deployment. PostgreSQL stays native on the guest (ADR-003).

**Consequences.**
- Python/runtime compatibility is isolated from the host distribution.
- Odoo upgrades become image-tag changes.
- Docker adds ~600 MB RAM overhead per node; accounted for in ADR-002.
- The filestore must be bind-mounted from the NFS mount and owned by UID/GID 101.

**Alternatives rejected.** Native source install (dependency risk, time), Odoo 18/19 (not the
requested version), Kubernetes (explicitly out of scope).

---

## ADR-002 — Resource budget: 2 GiB per ERP node, 512 MB per LB node

**Status:** locked · 16 Nov 2026

**Context.** The host is a laptop with 15 GiB RAM, of which **6.1 GiB was available** at measurement
time, 8 threads, and 53 GiB free on `/`. The original 3 GiB × 2 + 512 MB × 2 = 8 GiB plan cannot be
started without heavy swap and OOM risk.

**Decision.** `erp01/erp02`: 2 vCPU, 2048 MB, 12 GB thin disk. `lb01/lb02`: 1 vCPU, 512 MB, 6 GB.
Odoo runs `workers = 2`, `max_cron_threads = 1`; PostgreSQL uses `shared_buffers = 192 MB`,
`effective_cache_size = 512 MB`, `max_connections = 100`. Total allocation: 5 GiB RAM, 6 vCPU,
36 GiB thin.

**Consequences.** No headroom for a fifth VM. Test runs require closing memory-hungry host
applications. If more RAM becomes available, raising ERP nodes to 3 GiB is a one-line change in
`scripts/02-create-vms.sh` plus `odoo_workers` / `postgres_shared_buffers`.

---

## ADR-003 — PostgreSQL 16 native on the guests, not containerized

**Status:** locked · 16 Nov 2026

**Context.** Streaming replication, `pg_basebackup`, `pg_ctlcluster promote`, and a role-tracking
VIP are all simpler and better documented on a host installation. A database container would add a
second orchestration layer inside the failure domain being tested.

**Decision.** Install `postgresql-16` from the PGDG apt repository (Debian 13 ships 17) on both ERP
nodes. Data directory `/var/lib/postgresql/16/main`. Debian cluster tooling (`pg_ctlcluster`,
`pg_lsclusters`) is kept.

**Consequences.** PostgreSQL is a host service with its own systemd unit, which is exactly what the
failure tests need to stop and start. PGDG remains an external dependency; packages are pinned by
major version.

---

## ADR-004 — Unicast VRRP

**Status:** locked · 16 Nov 2026

**Context.** Keepalived defaults to VRRP multicast (224.0.0.18, protocol 112). libvirt's NAT
networks (`virbr*`) are Linux bridges and normally forward multicast, but behaviour varies with
firewall and bridge settings and silently breaks VIP failover.

**Decision.** Configure `unicast_src_ip` / `unicast_peer` on every VRRP instance, and allow
protocol 112 between peers in the host firewall.

**Consequences.** Deterministic failover on this platform, trivially portable to environments where
multicast is filtered. Peers are listed statically — adding a third LB requires editing both configs.

---

## ADR-005 — Deterministic addressing through libvirt DHCP reservations

**Status:** locked · 16 Nov 2026

**Context.** The design calls for static addressing. Configuring static IPs inside cloud-init's
`network-config` works but depends on the guest renderer (`systemd-networkd` vs `ifupdown`) and
introduces a class of boot-time failures unrelated to the project's subject.

**Decision.** The `ha-erp-net` libvirt network fixes every MAC address and maps it to a fixed lease
(`192.168.50.11/.12/.21/.22`). VIPs `.10` and `.30` are outside the DHCP range.

**Consequences.** Addresses are stable across reboots and rebuilds while guests use plain DHCP.
Recreating a VM with the same MAC preserves its address. Documented as "deterministic" rather than
"statically configured" in the report.

---

## ADR-006 — Database VIP ownership driven by a role file and binary-mode VRRP script

**Status:** locked · 16 Nov 2026 (revised: weight 0, `init_fail`)

**Context.** The DB VIP must follow the *current primary*, which changes during a controlled
failover. Keepalived priorities are normally static per node, and a plain "is PostgreSQL running?"
check is true on the standby as well.

**Decision.** Both ERP nodes run the same Keepalived configuration: base priority 100 and a
`vrrp_script` that exits 0 only when `/etc/ha-erp/db-role` contains `primary`. The script keeps the
**default weight 0**, which is binary mode: failure moves the instance to FAULT and releases the VIP.
`init_fail` makes the script "failed" until its first success, so a booting standby cannot grab the
VIP before the role is read. Promotion writes `primary` on the new node (and `standby` on the old one
if alive); the node whose script succeeds holds `192.168.50.30`.

**Why not a positive weight.** An earlier draft used `weight 80`. That only adjusts priority: with
the primary gone, the surviving standby (80 vs nothing) would still be elected and would advertise a
VIP for a read-only database — the exact split-brain outcome this design forbids. Binary/FAULT mode
means "not primary ⇒ no VIP", independent of whether the peer is reachable.

**Consequences.** One config, no per-node priority edits, and VIP movement is an explicit,
auditable action (`notify_master` logs every transition). A stale role file is the main failure mode
and is reset by the deploy playbook and by the failover/rejoin runbooks.

**Alternatives rejected.** Static priorities with config rewriting per failover (error-prone);
moving the VIP with `ip addr add` in the promotion script (duplicates Keepalived's job).

---

## ADR-007 — Controlled database failover with hard fencing

**Status:** locked · 16 Nov 2026

**Context.** Automatic promotion without fencing risks split-brain. The project scope explicitly
excludes automatic database failover.

**Decision.** `playbooks/db-failover.yml` requires `-e confirm_fence=yes`. Default fence mode is
`virsh` (power off `erp01` from the hypervisor). An alternative `service` mode stops the cluster and
installs a `DROP` rule on 5432, for demonstrations where the VM must stay inspectable. Only after
fencing does the playbook promote `erp02`, flip the role files, and restart Keepalived.

**Consequences.** Failover takes tens of seconds and requires an operator — this is the documented
RTO for T06/T07, not a defect. Data loss is bounded by replication lag (RPO measured in T06).

---

## ADR-008 — Rebuild the old primary with `pg_basebackup`

**Status:** locked · 16 Nov 2026

**Context.** Rejoining a diverged primary can be done with `pg_rewind` (fast, requires
`wal_log_hints = on` and a clean timeline divergence) or by re-cloning the standby.

**Decision.** Re-clone with `pg_basebackup -R` in `playbooks/db-rejoin.yml`. `wal_log_hints` is still
enabled so `pg_rewind` remains a documented optimisation.

**Consequences.** Rejoin time grows with database size (seconds for the lab's ~100 MB database), but
the procedure is deterministic, scriptable, and idempotent. The report notes the trade-off.

---

## ADR-009 — Health checks on `GET /web/login`

**Status:** locked · 16 Nov 2026

**Context.** Odoo 17 exposes no dedicated liveness endpoint; `/web/health` was introduced later.
A TCP-only check would keep a broken instance in the pool.

**Decision.** HAProxy uses `option httpchk GET /web/login` with `http-check expect status 200`,
`inter 2s`, `fall 2`, `rise 2`. The same URL is the container healthcheck.

**Consequences.** Detection of a dead Odoo process in ~4 s, and a hung Odoo (DB unreachable) within
the check timeout. `/web/login` touches the database, so it fails when the DB endpoint is down,
which is the desired behaviour for pool membership.

---

## ADR-010 — NFS server on the hypervisor, exported to the ERP nodes only

**Status:** locked · 16 Nov 2026

**Context.** Both Odoo instances must read and write the same filestore. A third storage VM would
consume RAM that does not exist; a DRBD pair would add scope.

**Decision.** Export `/srv/ha-erp/filestore` from the host to `192.168.50.21` and `.22` with
`rw,sync,no_subtree_check`, owned by UID/GID 101 (the Odoo container user). The directory is
bind-mounted at `/var/lib/odoo` in the container.

**Consequences.** The host becomes a storage SPOF — documented. `sync` costs throughput but keeps
attachment durability honest in a failure test. `root_squash` stays at its default.
