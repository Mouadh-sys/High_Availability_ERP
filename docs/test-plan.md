# Test Plan — Failure Injection and Measurement

A healthy-looking dashboard is not evidence. Every test below injects a real failure, probes the
user-facing endpoint continuously, and records timestamps that become RTO/availability numbers.

## 1. Test environment

| Item | Value |
|------|-------|
| Probe target | `http://192.168.50.10/web/login` |
| Probe rate | 2 requests/s (500 ms interval, 3 s timeout) |
| Baseline duration | 30 s per test |
| Observation window | until `T_restored + 15 s` or 180 s timeout |
| Evidence | `evidence/<test>-<timestamp>.csv` (probe samples), `evidence/results.jsonl` (summary) |
| Failure injection | `virsh` (VM), `systemctl` (service), `docker` (container), `playbooks/db-failover.yml` |
| Runner | `tests/run-all.sh` (continues on failure, prints a summary table) |

## 2. Metric definitions

| Metric | Formula / method |
|--------|------------------|
| Detection time | `T_last_200_before_failure → T_first_non_200_after` (probe resolution 0.5 s) |
| Failover time | `T_first_non_200 → T_first_200_served_by_new_owner` (owner identified by `X-LB` / stats) |
| RTO | `T_first_200_after_restore − T_failure_injected` |
| Availability | `successful_probes / total_probes × 100` over the T01 60 s steady-state window. Failover windows (T02–T05) are reported for context: a deliberate 3–8 s outage in a 10 s window cannot mathematically reach 99 %. |
| RPO | PostgreSQL: `pg_current_wal_lsn() − replay_lsn` at the moment of fencing; filestore: last durable write on NFS (`sync`) |
| Replication lag | `pg_last_xact_replay_timestamp()` vs `now()` on standby, sampled every 2 s |
| Data integrity | Row counts before/after (`res_users`, `ir_attachment`, `res_partner`), attachment checksum |

RTO is always reported with its components (detection, switchover, application reconnect) so the
number is explainable rather than magical.

## 3. Scenarios

### T01 — Normal operation

*Preconditions:* all four VMs up, `make verify` green.

```bash
tests/t01-baseline.sh
```

Inject nothing for 60 s. Collect: both backends `UP`, VIP owner (`X-LB`), `pg_is_in_recovery()` on
both nodes, replication lag, NFS mount on both nodes, 20 parallel requests.

**Pass:** ≥ 99 % probe success over 60 s, two `UP` backends, lag < 1 s, 20/20 parallel requests 200.

---

### T02 — Stop Odoo on erp01

```bash
ssh debian@192.168.50.21 'sudo systemctl stop ha-erp-odoo'
```

**Expected:** backend erp01 DOWN ≤ 4 s; only in-flight requests lost;
`X-Odoo` traffic served by erp02. **Pass:** RTO ≤ 10 s (window availability is reported for context).

**Recovery:** `systemctl start ha-erp-odoo`, wait for `UP` (rise 2), then T03.

---

### T03 — Stop Odoo on erp02

Same as T02 with the roles swapped. **Pass:** RTO ≤ 10 s; erp01 serves 100 % of post-failure traffic.

---

### T04 — Power off lb01

```bash
virsh destroy lb01
```

**Expected:** VIP on lb02 ≤ 5 s, `X-LB: lb02`, no backend disruption.

**Pass:** RTO ≤ 8 s, `vip-transitions.log` on lb02 contains `MASTER ERP_VIP`.

---

### T05 — Restore lb01 (VIP returns)

```bash
virsh start lb01
# wait for ssh + haproxy, then for preemption
```

**Pass:** VIP back on lb01 ≤ 15 s after HAProxy is healthy (priority 150 > 100), and the VIP does not
flap (this tests the more difficult direction: a *planned* return must not interrupt service).

---

### T06 — Stop the PostgreSQL primary (and fence)

```bash
# measure lag first, then inject
ssh debian@192.168.50.22 'sudo -u postgres psql -tc "select now()-pg_last_xact_replay_timestamp()"'
ssh debian@192.168.50.21 'sudo systemctl stop postgresql@16-main'
# fence
virsh destroy erp01
# promote via playbook
make db-failover
```

**Pass:** `pg_is_in_recovery()=f` on erp02, VIP `.30` on erp02, no two primaries at any sampled
instant, RPO recorded (bytes of WAL not replayed at fence time).

**Note:** Odoo is unavailable during this test by design — `/web/login` needs the database. Availability
is expected to be low; the metric of interest is RTO/RPO, not uptime.

---

### T07 — Promote standby, reconnect Odoo

Executed as part of `db-failover.yml`; the harness restarts both Odoo units and probes.

**Pass:** first 200 within 120 s of injection, write through the DB VIP succeeds, `res_users` count
unchanged, attachment count unchanged.

---

### T08 — Attachment shared through the filestore

```bash
ODOO_ADMIN_PASSWORD=... tests/t08-attachment.sh
```

The script authenticates over XML-RPC, creates an `ir.attachment` with a random payload, then:
1. reads the attachment back through the ERP VIP,
2. locates the file under `/srv/ha-erp/filestore/ha_erp/filestore/` on **erp02**,
3. verifies the SHA-256 of the stored blob.

**Pass:** identical checksum on erp01 and erp02, attachment downloadable through the VIP.

---

### T09 — Restore a failed component

```bash
virsh start erp01 && make db-rejoin
ssh debian@192.168.50.21 'sudo systemctl start ha-erp-odoo'
```

**Pass:** erp01 rejoins as standby (`pg_is_in_recovery()=t`, streaming, lag < 1 s), backend returns
to `UP`, no duplicate primary, T01 smoke checks green again.

---

## 4. Ordering and dependencies

```
T01 → T02 → T03 → T04 → T05 → T06 → T07 → T08 → T09 → T01 (regression)
```

T06/T07 are destructive to erp01. T08 can run before T06 if the database state must be pristine;
T09 must run before any further DB test. `run-all.sh` executes the order above and refuses to start
T06 if `t05` did not restore lb01.

## 5. Safety

* Snapshot or `virsh destroy` only — never delete volumes during a test.
* `tests/.env` holds the Odoo admin password for T08; it is git-ignored.
* Abort conditions: two primaries detected, NFS mount lost on both nodes, host available memory
  below 500 MB. The harness prints the abort reason and leaves the lab in a fenced state for manual
  recovery rather than guessing.

## 6. Reporting

`evidence/results.jsonl` is the single source for the results chapter. Each line:

```json
{"test":"T02","started":"2026-11-17T09:12:03Z","failure_at":"...","detected_at":"...",
 "restored_at":"...","rto_s":4.8,"detection_s":2.1,"availability_pct":99.4,
 "owner_after":"lb01","backend_after":"erp02","notes":"erp01 odoo stopped"}
```

`docs/test-results.md` is generated by hand from these records plus screenshots.
