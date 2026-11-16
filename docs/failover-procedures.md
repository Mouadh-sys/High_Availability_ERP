# Failover and Recovery Procedures

Each procedure lists trigger, detection, action, verification, and the expected timing. Commands
assume the repository root as working directory and `SSH="ssh -i ~/.ssh/ha_erp_ed25519"`.

> **Rule zero.** Never promote a standby while the old primary can still accept writes. If in doubt,
> power the old primary off (`virsh destroy`). A five-minute outage is recoverable; a diverged
> database is a project.

---

## A. Application instance failure (automatic, T02/T03)

**Trigger.** Odoo container stops, crashes, or the node becomes unresponsive.

**Detection.** HAProxy `option httpchk GET /web/login`, `inter 2s`, `fall 2` → backend DOWN after
~4 s. `option redispatch` moves sticky sessions to the surviving server.

**Action.** None for availability; the surviving instance serves the platform.

```bash
# verify from the host
curl -s http://192.168.50.10:8404/stats\;csv | awk -F, '$1=="be_odoo"{print $2,$18,$19,$20}'
curl -sI http://192.168.50.10/web/login | grep -i x-lb
```

**Restore.**

```bash
$SSH debian@192.168.50.21 'sudo systemctl start ha-erp-odoo'
# wait for the check to mark it UP (rise 2 -> ~4 s), then confirm traffic returns
```

**Expected.** Availability loss per backend ≈ 4 s of in-flight requests, no login loss (sessions are
shared through the filestore). If the container restarts in a loop, inspect
`docker logs odoo` and `journalctl -u ha-erp-odoo`.

---

## B. Load-balancer failure (automatic, T04/T05)

**Trigger.** `lb01` powered off, HAProxy killed, or the VM hangs.

**Detection.** `chk_haproxy` (`pgrep -x haproxy`, weight 0 = binary mode) puts lb01 in FAULT; a full
VM loss stops its adverts. Either way lb02 (priority 100) takes over after ~3 × `advert_int` = 3 s,
or after 2 failed script checks (4 s) when only HAProxy died.

**Verification.**

```bash
curl -sI http://192.168.50.10/web/login | grep -i x-lb        # X-LB: lb02
$SSH debian@192.168.50.12 'ip -4 addr show | grep 192.168.50.10'
$SSH debian@192.168.50.12 'sudo tail -5 /var/log/ha-erp/vip-transitions.log'
```

**Restore.**

```bash
virsh start lb01
# lb01 regains priority 150 and, with preemption enabled, takes the VIP back (T05)
```

**Expected.** ≤ 5 s interruption; browsers may need one refresh if a request was in flight.

---

## C. Controlled database failover (manual, T06/T07)

**Preconditions.** Replication healthy on erp02; operator available; change window accepted.

### C.1 Assess

```bash
# On erp02: is it a standby, and how far behind?
$SSH debian@192.168.50.22 'sudo -u postgres psql -x -c "select pg_is_in_recovery(), \
  pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn(), \
  now()-pg_last_xact_replay_timestamp() as replay_lag"'
# On erp01 (if alive): what has not shipped yet?
$SSH debian@192.168.50.21 'sudo -u postgres psql -x -c "select client_addr, state, \
  sent_lsn, replay_lsn, sent_lsn-replay_lsn as bytes_behind from pg_stat_replication"'
```

Record `bytes_behind` and `replay_lag` — that is the **RPO**. Do not proceed if the standby is not
in `streaming` state.

### C.2 Fence the old primary

```bash
# Hard fence (default, recommended): the VM is powered off, so it cannot write
virsh destroy erp01

# Alternative when the VM must stay inspectable (postgres crashed by itself):
$SSH debian@192.168.50.21 'sudo systemctl stop postgresql@16-main && \
  sudo iptables -I INPUT -p tcp --dport 5432 -j DROP'
# and confirm: psql -h 192.168.50.21 -U odoo -d ha_erp must time out
```

### C.3 Promote

```bash
$SSH debian@192.168.50.22 'sudo pg_ctlcluster 16 main promote'
$SSH debian@192.168.50.22 'sudo -u postgres psql -tc "select pg_is_in_recovery()"'   # f
```

Or use the playbook, which performs C.1–C.3 and the VIP move with assertions:

```bash
make db-failover          # requires -e confirm_fence=yes (already in the target)
```

### C.4 Move the database VIP

```bash
$SSH debian@192.168.50.22 'echo primary | sudo tee /etc/ha-erp/db-role && \
  sudo systemctl restart keepalived'
$SSH debian@192.168.50.22 'ip -4 addr show | grep 192.168.50.30'
```

If `erp01` is alive (service-mode fence), also write `standby` to its role file and restart
Keepalived there, otherwise both nodes claim priority 180.

### C.5 Reconnect applications

```bash
# Both nodes: drop pooled connections to the dead primary
$SSH debian@192.168.50.21 'sudo systemctl restart ha-erp-odoo' 2>/dev/null || true
$SSH debian@192.168.50.22 'sudo systemctl restart ha-erp-odoo'
curl -sI http://192.168.50.10/web/login | head -2
```

### C.6 Verify integrity

```bash
PGPASSWORD=... psql -h 192.168.50.30 -U odoo -d ha_erp <<'SQL'
select count(*) from res_users;
select count(*) from ir_attachment;
select max(write_date) from res_partner;
SQL
# write test
psql -h 192.168.50.30 -U odoo -d ha_erp -c \
  "insert into res_currency_rate(name, rate, currency_id) select now()::date, 3.1, id from res_currency where name='TND' returning id;"
```

**Expected (measured, to be replaced by real numbers):** promotion < 5 s, VIP move < 5 s, Odoo
reconnect after container restart ~30 s, total RTO 60–120 s dominated by operator action.

---

## D. Rejoin the former primary (T09)

```bash
virsh start erp01
ssh -i ~/.ssh/ha_erp_ed25519 debian@192.168.50.21 'hostname'   # wait for boot
make db-rejoin                                                 # -e confirm_rebootstrap=yes
```

The playbook: stops the cluster and Keepalived on erp01 → wipes `/var/lib/postgresql/16/main` →
`pg_basebackup -h 192.168.50.22 -U replicator -R -X stream` → sets `db-role=standby` → starts
PostgreSQL and Keepalived → asserts `pg_is_in_recovery()=t` and lag < 1 s.

Alternative (faster, requires a clean divergence): `pg_rewind --target-pgdata=... --source-server=...`,
then recreate `standby.signal` and `primary_conninfo`. See ADR-008 for why it is not the default.

**Rollback / split-brain recovery.** If two nodes ever report `pg_is_in_recovery()=f`:
1. `virsh destroy` the node that is *not* supposed to be primary.
2. Confirm the survivor has the latest LSN you accepted.
3. Rejoin the other with section D (it will be re-cloned, so divergence is discarded).

---

## E. NFS / filestore failure

**Trigger.** Host NFS service stops, export disappears, or the mount goes stale.

**Impact.** Odoo requests that touch attachments or sessions fail; logins may break. The container
keeps running, so HAProxy still considers it healthy — this is a known detection gap.

```bash
# On host
sudo exportfs -v
sudo systemctl restart nfs-kernel-server
# On guests
mountpoint -q /srv/ha-erp/filestore && df -h /srv/ha-erp/filestore
sudo systemctl restart ha-erp-odoo    # only if the mount was remounted
```

**Improvement recorded in limitations:** add an HAProxy/NFS-aware check or move the export to a
third node.

---

## F. Full rebuild

```bash
./scripts/99-teardown.sh -y
./scripts/01-create-network.sh
./scripts/02-create-vms.sh
make bootstrap site verify
```

Time from zero: ~25 minutes including image pulls, excluding the Debian image download.

---

## G. Evidence capture for every procedure

```bash
# start a probe before injecting the failure, stop it afterwards
tests/lib/probe.sh 60 > evidence/probe-<test>-$(date +%s).csv &
sleep 2
# ... inject failure, wait for recovery, note timestamps ...
wait
```

Each test script already does this and appends a JSON record to `evidence/results.jsonl` with
`T_failure`, `T_detected`, `T_restored`, `rto_s`, `probe_success_pct`.
