# Limitations and Threats to Validity

Listed explicitly because an HA project that hides its single points of failure is a diagram, not an
engineering result.

## 1. Structural limitations

| # | Limitation | Consequence | Mitigation / what the report says |
|---|------------|-------------|-----------------------------------|
| L1 | **Single physical host** | Host crash, kernel panic, or power loss stops all four VMs. Availability is bounded by the host's uptime. | Documented as the primary SPOF; VM-level redundancy is demonstrated, host-level is out of scope. |
| L2 | **NFS server on the host** | Loss of the export breaks attachments and sessions on both ERP nodes; the host disk is a single copy. The fence guard also refuses to start PG/Keepalived without the mount. | Export restricted to the ERP nodes, `sync` writes, monitoring, backup task. Production would need replicated storage. |
| L3 | **Combined app + DB failure domain** per ERP node | Losing erp01 removes an Odoo instance *and* the write master, turning an application failure into a database outage. | Accepted trade-off for 5 GiB of RAM (ADR-002). The failure matrix in `architecture.md` states the coupling. |
| L4 | **Asynchronous replication** | Transactions committed but not replayed at failure are lost. RPO > 0 by construction. | RPO measured in T06 from `sent_lsn − replay_lsn`; synchronous replication listed as future work. |
| L5 | **Manual database failover** | RTO includes operator assessment and fencing: tens of seconds to minutes, not seconds. | Runbook rehearsed; `db-failover.yml` automates the mechanical steps but requires `confirm_fence=yes`. |
| L6 | **No quorum / watchdog** | Fencing is procedural. The shared-filestore marker blocks a rebooted fenced node, but it is a witness, not a quorum: an operator who deletes the marker can still create two primaries. | Hard fence (`virsh destroy`) is the default, the marker + boot guard is automatic, and rejoin re-clones so divergence is discarded rather than merged. |
| L7 | **Resource contention** | 6 vCPU and 5 GiB of guests on 8 threads / ~6 GiB available means noisy neighbours, swap, and variable timings. | Allocations tuned (ADR-002); timings reported with host load; tests run with browsers closed. |
| L8 | **Thin-provisioned disks** | 36 GiB virtual on 53 GiB free; image pulls and logs can fill the host filesystem. | Sparse images, Docker log rotation, disk check in preflight. |
| L9 | **Lab-grade security** | Self-signed TLS (optional), VRRP `auth_type PASS`, shared lab network, secrets rendered on disk. | Requirements SR-01…SR-09 implemented; production gaps listed below. |
| L10 | **No dedicated monitoring stack** | Prometheus/Grafana optional and deferred; detection evidence comes from HAProxy stats and test probes. | `verify.yml` health report + stats CSV are sufficient for the report; alerting is future work. |
| L11 | **DHCP-reserved addressing** | Addresses come from libvirt leases, not from static guest configuration. Network partition/renewal edge cases exist. | Deterministic by MAC; documented as equivalent-to-static (ADR-005). |
| L12 | **Session model** | Shared filestore makes sessions portable, but Odoo's in-memory caches and asset bundles are per-instance. | Sticky cookies keep users on one instance; `option redispatch` handles failover at the cost of a cold cache. |

## 2. Threats to validity of the measurements

* **Probe resolution 0.5 s** bounds detection-time accuracy. RTO shorter than 0.5 s cannot be
  distinguished from 0.
* **Cache effects**: the first request after a failover includes Odoo registry load; later requests
  are faster. Reported RTO uses the first successful 200, not steady-state latency.
* **Warm vs cold**: Odoo containers are warm (registry loaded). A cold start would add 20–60 s and
  is reported separately if measured.
* **Clock**: all timestamps come from the host (`date -u +%s.%N`), not from the guests, to avoid skew.
* **Single run**: each test is executed once for the report; repeated runs would strengthen the
  numbers. Variance is expected to be dominated by host load (L7).

## 3. Production gaps (future improvements)

1. Independent hypervisor hosts with live migration and anti-affinity.
2. Dedicated database nodes; Patroni/etcd or repmgr for quorum-based automatic failover with fencing.
3. Synchronous replication (`synchronous_commit = remote_write`) where RPO = 0 is required.
4. Replicated/HA storage (Ceph, DRBD, or a NAS with multipath) for the filestore.
5. External load balancer or anycast/BGP instead of VRRP; health checks that include NFS.
6. Centralized logging, metrics, and alerting (Prometheus, Alertmanager, Grafana, Loki).
7. TLS everywhere with an internal CA, HSTS, and automated certificate rotation.
8. Centralized secrets (Vault/SOPS) and short-lived credentials instead of Vault-encrypted files.
9. Backup/restore automation with PITR (WAL archiving) and restore drills.
10. Capacity planning and performance testing (Locust/k6) against the Odoo workload.

## 4. Scope reminders

Odoo is used as a workload, not modified. No Kubernetes, no multi-datacenter, no automatic database
failover, no guarantee of zero data loss, and no claim of production readiness. The contribution is
the architecture, the reproducible automation, and the measured behaviour under failure.
