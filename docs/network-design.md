# Network Design

## 1. Virtual network

Definition: [`infra/libvirt/ha-erp-net.xml`](../infra/libvirt/ha-erp-net.xml)

| Property | Value |
|----------|-------|
| libvirt network | `ha-erp-net` (persistent, autostart) |
| Mode | NAT (`<forward mode='nat'/>`) — guests reach the internet for packages |
| Bridge | `virbr50` on the host |
| Subnet | `192.168.50.0/24` |
| Host address | `192.168.50.1` (gateway, DNS forwarder, NFS server) |
| DHCP range | `192.168.50.100 – 192.168.50.199` (nothing in use) |
| Isolation | Separate bridge from the existing `lab-isolated`/default networks; no route from the LAN except NAT egress |

Addressing is deterministic through MAC-to-IP reservations (ADR-005). VIPs are outside the DHCP
range so a guest can never be handed an address that collides with one.

## 2. Address plan

| Component | Address | MAC | Notes |
|-----------|---------|-----|-------|
| Host / gateway | 192.168.50.1 | — | virbr50, NFS export |
| **ERP VIP** | **192.168.50.10** | VRRP 00:00:5e:00:01:33 | Owned by lb01 (priority 150) |
| lb01 | 192.168.50.11 | 52:54:00:50:00:11 | HAProxy :80, stats :8404 |
| lb02 | 192.168.50.12 | 52:54:00:50:00:12 | HAProxy :80, stats :8404 |
| erp01 | 192.168.50.21 | 52:54:00:50:00:21 | Odoo :8069, PG :5432, PG primary |
| erp02 | 192.168.50.22 | 52:54:00:50:00:22 | Odoo :8069, PG :5432, PG standby |
| **DB VIP** | **192.168.50.30** | VRRP 00:00:5e:00:01:34 | Owned by the node whose `db-role` is `primary` |

MAC convention: `52:54:00:50:00:<last octet>`. `52:54:00` is the QEMU/KVM prefix; `50` is the lab
number; the last byte mirrors the IP's last byte.

## 3. Names

Static `/etc/hosts` on the host and guests (no DNS dependency in the lab):

```
192.168.50.1   host.ha-erp.lab   host
192.168.50.10  erp.ha-erp.lab    erp
192.168.50.11  lb01.ha-erp.lab   lb01
192.168.50.12  lb02.ha-erp.lab   lb02
192.168.50.21  erp01.ha-erp.lab  erp01
192.168.50.22  erp02.ha-erp.lab  erp02
```

`erp.ha-erp.lab` resolves to the VIP, which is the only name users need. `*.ha-erp.lab` entries are
for administration and for TLS certificate subject alternative names.

## 4. VRRP

| Instance | VRID | Peers | Base priority | Track script |
|----------|------|-------|---------------|--------------|
| `ERP_VIP` | 51 | lb01 ⇄ lb02 | 150 / 100 | `chk_haproxy` (weight 0 = FAULT on failure, interval 2 s) |
| `DB_VIP` | 52 | erp01 ⇄ erp02 | 100 / 100 | `chk_db_role` (weight 0 = FAULT, `init_fail`, interval 2 s) |

Both instances use **unicast** VRRP (`unicast_src_ip` / `unicast_peer`) with `advert_int 1`,
`auth_type PASS`. Authentication is a lab control, not a security boundary; the password comes from
Vault. `notify_master/backup/fault` append to `/var/log/ha-erp/vip-transitions.log`, which is the
primary evidence for T04/T05/T06.

Firewall must allow IP protocol 112 between the peers; it is opened in `group_vars` and verified by
`verify.yml`.

## 5. Port and firewall matrix

`ufw` default: deny incoming, allow outgoing. Rules below are installed by the `common` role.

| Source | Destination | Port/Proto | Purpose | Allowed on |
|--------|-------------|------------|---------|------------|
| 192.168.50.0/24 | ERP VIP (.10) | 80/tcp, 443/tcp | ERP access | lb01, lb02 |
| 192.168.50.0/24 | ERP VIP (.10) | 8404/tcp | HAProxy stats (admin view) | lb01, lb02 |
| lb01, lb02 | erp01, erp02 | 8069/tcp | Odoo HTTP backend | erp01, erp02 |
| erp01, erp02 | DB VIP (.30) | 5432/tcp | Odoo → PostgreSQL | erp01, erp02 |
| erp01 ⇄ erp02 | peer | 5432/tcp | Streaming replication | erp01, erp02 |
| host (.1) | erp01, erp02 | 5432/tcp | Verification queries | erp01, erp02 |
| lb01 ⇄ lb02 | peer | 112/vrrp | Keepalived | lb01, lb02 |
| erp01 ⇄ erp02 | peer | 112/vrrp | Keepalived | erp01, erp02 |
| erp01, erp02 | host (.1) | 2049/tcp | NFS filestore | egress (default allow) |
| 192.168.50.0/24 | any guest | 22/tcp | SSH administration | all guests |

Explicitly **not** exposed: 5432 from the LAN, 8069 from the LAN, 2049 from guests other than the
ERP pair, Docker API, libvirt.

## 6. NAT and routing notes

* Guests use `192.168.50.1` as gateway, DNS, and NTP source (host `systemd-timesyncd`/`chrony`).
* Outbound NAT is required only for package installation, the Odoo image, and PGDG repositories.
* The host reaches guests directly over `virbr50`; no port forwarding is configured. To reach Odoo
  from the host browser, use `http://192.168.50.10`.
* libvirt's DHCP reservations require the VMs to keep their MAC addresses; `scripts/02-create-vms.sh`
  passes them explicitly and warns if an existing domain has a different MAC.

## 7. Verification commands

```bash
virsh net-dumpxml ha-erp-net                     # network + reservations
virsh net-dhcp-leases ha-erp-net                 # obtained leases
ip -4 addr show virbr50                          # host side of the bridge
ip neigh show dev virbr50                        # who is where
for h in 11 12 21 22; do ping -c1 -W1 192.168.50.$h; done
for h in .11 .12 .21 .22; do ssh debian@192.168.50$h 'ip -4 addr show'; done
curl -sI http://192.168.50.10/web/login | grep -i x-lb
```

## 8. Failure-relevant behaviour

* **VIP failover**: gratuitous ARP is sent by the new master; the host's neighbour cache updates
  within one advertisement. TCP sessions are not preserved — the probe measures the gap.
* **Split-brain risk**: if `virbr50` partitions (not possible in this single-bridge lab), both LBs
  could claim the VIP. Keepalived's `auth_type PASS` and `advert_int 1` mitigate accidental
  conflicts; the report notes that production would add `unicast` + firewall + `check_unicast_src`.
* **DB split-brain**: prevented procedurally by fencing, not by the network. The DB VIP is a
  convenience endpoint, not a fence.
