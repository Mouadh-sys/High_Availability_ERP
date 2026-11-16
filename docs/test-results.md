# Test Results

> **Status: not yet executed.** This file is the reporting template; the numbers below must be
> replaced by values from `evidence/results.jsonl` after `make test` runs on the provisioned lab.
> Anything not measured is written as `n/m` (not measured), never estimated.

## 1. Environment

| Item | Value |
|------|-------|
| Date of test run | _pending_ |
| Host | Pop!_OS 24.04, i5-11300H, 8 threads, 15 GiB RAM (available at start: __ GiB) |
| Guests | Debian 13, Odoo 17.0, PostgreSQL 16.x, HAProxy 2.8.x, Keepalived 2.2.x |
| Git commit | _pending_ (`git rev-parse --short HEAD`) |
| Database size | _pending_ (`pg_database_size('ha_erp')`) |
| Replication mode | asynchronous, slot `erp02_slot` |

## 2. Summary

| Test | Scenario | Detection | Failover | RTO | Availability | Result |
|------|----------|-----------|----------|-----|--------------|--------|
| T01 | Normal operation | — | — | — | n/m | pending |
| T02 | Odoo stopped on erp01 | n/m | n/m | n/m | n/m | pending |
| T03 | Odoo stopped on erp02 | n/m | n/m | n/m | n/m | pending |
| T04 | lb01 powered off | n/m | n/m | n/m | n/m | pending |
| T05 | lb01 restored, VIP returns | n/m | n/m | n/m | n/m | pending |
| T06 | PG primary stopped + fenced | n/m | n/m | n/m | n/m | pending |
| T07 | Standby promoted, Odoo reconnected | n/m | n/m | n/m | n/m | pending |
| T08 | Attachment shared erp01 → erp02 | — | — | — | — | pending |
| T09 | erp01 rejoined as standby | n/m | n/m | n/m | n/m | pending |

## 3. Detailed observations

### T01 — Baseline

* HAProxy stats: _backend states, sample CSV excerpt_
* VIP owner (`X-LB`): _
* Replication: `pg_is_in_recovery()` erp01=_ erp02=_; lag=_ ms
* NFS: both mounts present, `df` output _
* 20 parallel requests: _/20 succeeded, median latency _ ms
* Idle resource use: erp01 _ MiB, erp02 _ MiB, lb01/02 _ MiB; host `free` _

### T02 / T03 — Application failover

* Probe timeline (first non-200, first 200 after): _
* HAProxy log lines showing `DOWN`/`UP` transitions: _
* Sessions preserved across failover? _yes/no — evidence: same `session_id` served by other backend_

### T04 / T05 — Load-balancer failover

* VRRP transition log excerpt (both nodes): _
* Observed `X-LB` before/after: _
* Gratuitous ARP / neighbour table evidence: _
* Preemption on lb01 return: time from `virsh start` to VIP regained: _

### T06 / T07 — Database failover

* Lag at fence: `replay_lag`=_ ms, `sent_lsn − replay_lsn`=_ bytes → **RPO = _**
* Promotion command output: _
* VIP `.30` owner before/after: _
* Odoo reconnect: container restart to first 200 = _
* Integrity: `res_users` before/after, `ir_attachment` before/after, checksum match: _
* Anomalies: _

### T08 — Shared filestore

* Attachment ID / size / SHA-256: _
* File path on erp01 / erp02 filestore: _
* Downloaded through VIP: _ok/fail_

### T09 — Rejoin

* `pg_basebackup` duration and size: _
* `pg_is_in_recovery()` after rejoin: _
* Streaming state and lag: _
* HAProxy backend state: _

## 4. Analysis

* Which layer produced the largest RTO, and why: _
* Observed RPO versus design intent (asynchronous replication): _
* Did any single failure create a second, unexpected failure (coupling)? _
* Resource pressure during tests (swap, OOM, CPU steal): _
* Deviations from the test plan and their justification: _

## 5. Acceptance against objectives

| Objective / requirement | Evidence | Met? |
|-------------------------|----------|------|
| FR-01 single VIP access | T01 | pending |
| FR-02 load distribution | T01 stats | pending |
| FR-04 app failover | T02/T03 | pending |
| FR-05 LB failover | T04/T05 | pending |
| FR-06 replication | T01/T06 | pending |
| FR-07 controlled promotion | T06/T07 | pending |
| FR-09 shared filestore | T08 | pending |
| FR-10 automation | clean rebuild in _ min | pending |
| NFR-01 availability ≥ 99 % | T01 (60 s steady state) | pending |
| NFR-04 DB RTO ≤ 120 s | T06/T07 | pending |

## 6. Raw evidence index

| File | Content |
|------|---------|
| `evidence/results.jsonl` | one JSON record per test |
| `evidence/*-probe-*.csv` | per-request probe samples |
| `evidence/verify-*.json` | `make verify` health reports |
| `evidence/screenshots/` | HAProxy stats, Odoo UI, VRRP log, replication SQL |
