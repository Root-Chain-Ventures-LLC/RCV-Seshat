# High availability

Seshat runs as one box or as a cluster. This page is the operator's guide to **modes 1 and 2**
(built-in VRRP: active/standby and multi-VIP active/active) and **mode 3** (built-in BGP anycast,
[below](#mode-3-bgp-anycast)). **Mode 4** (external load balancer, Kubernetes) is [below](#mode-4); the
cluster-wide rules below apply to all four.

| Mode | Mechanism | What the network must provide | Covered here |
|---|---|---|---|
| 1. Active/standby | built-in VRRP, one floating address, health-driven | a shared L2 segment, multicast allowed | yes |
| 2. Multi-VIP active/active | the same VRRP engine, one address per node; every node masters one and backs up the rest | the same | yes |
| 3. Anycast active/active | built-in BGP speaker announcing a /32 (/128) from every healthy node | BGP and ECMP on the router | yes, [Mode 3](#mode-3-bgp-anycast) |
| 4. External load balancer | `/api/health`, `/api/ready` (503 while draining), Helm chart, DSR guides | an LB that preserves the source IP | yes, [Mode 4](#mode-4) |

## What you get

- **One floating address (or several) that follows the healthiest node.** Senders (switches,
  firewalls, exporters) are pointed at the virtual address once and never reconfigured.
- **Health-driven failover, not just liveness.** A node whose database, listener, output or disk
  queue is in trouble lowers the priority it advertises, so a healthier node takes the address while
  the sick one is still running.
- **Drain.** One click (or `POST /api/cluster/drain`) moves a node's addresses to the others and
  keeps the node processing until its queues are empty, so it can be stopped or upgraded without
  losing what it already accepted. A normal stop (SIGTERM) does the same first.
- **One SNMPv3 identity per cluster.** One engine ID and one set of USM users, so a sender that
  fails over from one node to the other keeps authenticating.
- **Shared state.** In PostgreSQL mode the database is shared. In SQLite mode a small authenticated
  peer protocol replicates settings, v3 users, flow templates and the device knowledge base.

## Cluster-wide invariants (every mode)

These are in the specification (section 10) and the design follows from them:

1. **Source IP is preserved.** Nothing between the sender and Seshat may rewrite it (no SNAT). VRRP
   satisfies this by construction: the address is simply on the node. Seshat's inputs bind the
   wildcard address (`:1162`, `:1514`, `:2055`...), so a virtual address that appears later is served
   the moment it is programmed; a test proves it with a listener created before the address exists.
2. **Sender-to-node stickiness.** All traffic of one sender must keep reaching the same node, because
   per-sender state is local: SNMPv3 engine boots/time and replay windows, the flow template cache
   and sequence tracking, TCP and TLS syslog connections, rate-limit buckets. In VRRP modes the
   virtual address *is* the stickiness: a sender talks to one address, held by one node at a time.
   With several virtual addresses (mode 2) give each sender exactly one address; never spread one
   sender over two. In the ECMP modes the router must hash on the source address (at least
   source IP) so one exporter stays on one node.
3. **Flow templates are shared.** A node that takes over an exporter mid-stream must be able to decode
   the data records that follow, so templates are replicated (SQLite mode) or read from the shared
   database (PostgreSQL mode). Until a template is known, records are counted as
   `no_template` and dropped, exactly as for a new exporter.
4. **One SNMPv3 engine ID and one USM key set per cluster.** Stored in the settings, see below.
5. **Device knowledge base replicated, per-field last-writer-wins by observation time.**
6. **Graceful drain before stop; rolling upgrade without loss.**

Known limit: a node's local disk queue is not reachable while the node is down. Events already
queued on a failed node are delivered when it comes back. (The optional shared message bus described in
`outputs.md` removes the limit.)

## Requirements

| Need | Why | How to check |
|---|---|---|
| Nodes on the same L2 segment (VLAN) | VRRP is link-local: multicast `224.0.0.18` (IPv4) / `ff02::12` (IPv6), IP protocol **112** | `tcpdump -ni eth0 ip proto 112` on a node shows the other node's advertisements |
| The segment forwards that multicast | IGMP/MLD snooping switches must not prune it (VRRP speakers join the group); some virtual switches filter protocol 112 by default | same capture; check vSwitch/port-security settings |
| A free address in the interface's subnet | the virtual address; it must not be used by anything else | `ping` it first; it must not answer |
| `CAP_NET_ADMIN` and `CAP_NET_RAW` in the process's effective set | add/remove the address; raw IP protocol 112 and gratuitous ARP | the Cluster page shows the exact missing capability and never crashes |
| Host networking (containers) | the address is programmed onto the real interface | `network_mode: host` |

Not on a Linux host with a real interface (Kubernetes pod networking, a container without host
networking)? Use mode 3 or 4 instead; VRRP cannot work there and Seshat says why on the Cluster page.

### Containers

The image's default user is non-root and holds no capabilities, so run the HA services as root with
the two capabilities added (the example file does):

```yaml
network_mode: host
user: "0:0"
cap_add: [NET_ADMIN, NET_RAW]
stop_grace_period: 40s
```

See [`deploy/compose/ha-pair.example.yaml`](../deploy/compose/ha-pair.example.yaml). It starts two
nodes with their own data directories; because two nodes on one machine cannot share ports, the
example gives node-b shifted ports (on separate machines both use the defaults).

### systemd

With the `seshat` package ([`packaging.md`](packaging.md)) the unit runs as the unprivileged user `seshat`
with only `CAP_NET_BIND_SERVICE`. Add the two VRRP capabilities with the packaged drop-in
[`deploy/systemd/drop-ins/vrrp.conf`](../deploy/systemd/drop-ins/vrrp.conf):

```
install -D -m 0644 /usr/share/seshat/systemd/drop-ins/vrrp.conf /etc/systemd/system/seshat.service.d/vrrp.conf
systemctl daemon-reload && systemctl restart seshat
```

It adds `CAP_NET_ADMIN CAP_NET_RAW` to the ambient and bounding sets and `AF_PACKET` to the allowed
address families (gratuitous ARP), and carries a commented `ExecStopPost=` line for removing a virtual
address after a crash. Without the package,
[`deploy/systemd/seshat-ha.service.example`](../deploy/systemd/seshat-ha.service.example) is the same unit and
drop-in merged into one file, with the same sandbox (`SystemCallFilter`, `MemoryDenyWriteExecute`,
`ProtectSystem=strict`, ...) and `AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW`. The sandbox was exercised with
real VRRP (raw protocol 112 socket, address programming over netlink, release on stop) and the TCP-MD5 socket
option the BGP speaker sets. In Docker the HA examples run as root on the host network with every capability
dropped except those named in the file ([`hardening.md`](hardening.md)).

## Configuring VRRP

Everything cluster-wide is one setting (`cluster.vrrp`) edited under **Cluster > Configure** or with
`PUT /api/cluster/vrrp`. It is shared with the other nodes automatically (PostgreSQL: the database;
SQLite: the peer protocol), so you configure once.

```json
{
  "enabled": true,
  "instances": [
    {
      "name": "main",
      "vrid": 51,
      "vips": ["192.0.2.100"],
      "priorities": { "node-a": 150, "node-b": 100 },
      "advert_interval_ms": 1000
    }
  ]
}
```

| Field | Meaning |
|---|---|
| `name` | label, lower-case letters, digits, `-` `_` |
| `vrid` | virtual router ID 1-255, **unique per instance and per VLAN**: another VRRP speaker (a router pair) using the same VRID on the segment would interfere |
| `interface` / `interfaces` | interface name; empty means "the interface whose subnet contains the first virtual address" (this is right for nearly everyone). `interfaces` overrides per node name when interface names differ (`eth0` here, `ens18` there) |
| `vips` | 1 to 20 addresses, one family per instance (use two instances for IPv4 and IPv6) |
| `priorities`, `default_priority` | base priority 1-254 per **node name**; a node not listed uses `default_priority` (100) |
| `preempt` (default true) | a higher priority node takes the address back; also lets a backup take it from a master whose priority has dropped. Health-driven failover needs it |
| `preempt_delay_ms` | wait this long before preempting a lower priority master (default 0: at once) |
| `advert_interval_ms` | 100 to 40950 in steps of 10; default 1000 |
| `auth` | sign advertisements, see below |

A node's **name** is `SESHAT_NODE_NAME` (default: the hostname). Priorities are keyed by it, so it
must be unique and stable. The node ID (kept in `<data dir>/node-id`) is what identifies the node
internally and never changes if you rename it.

### Mode 1: active/standby

One instance, the preferred node with the higher priority. When the preferred node comes back it
takes the address again (preemption, the default). With `preempt` off the address stays where it is
until you drain the node that holds it; note that without preemption a degraded master is *not*
replaced either (a backup defers to a live master whatever its priority), so keep preemption on if you
want health-driven failover.

### Mode 2: multi-VIP active/active

N instances, one virtual address each, and each node has the highest priority on one of them:

```json
"instances": [
  { "name": "vip-a", "vrid": 51, "vips": ["192.0.2.100"], "priorities": { "node-a": 150, "node-b": 100 } },
  { "name": "vip-b", "vrid": 52, "vips": ["192.0.2.101"], "priorities": { "node-a": 100, "node-b": 150 } }
]
```

Then **split your senders**: half the devices send to `192.0.2.100`, the other half to
`192.0.2.101`. Each sender uses exactly one address (stickiness). If a node dies, its address moves
to the other, which then serves both. The Cluster page shows every address, who holds it and the
state of every node on each instance, so you can see the split and the balance of senders you chose.

### Failover times

A backup takes over when it has heard nothing for `3 x advertisement interval + skew` (the skew is
`(256 - priority) / 256` of an interval). With the default 1 s that is 3.0 to 4.0 s for a crash or a
network cut; with 100 ms it is 0.3 to 0.4 s. A graceful stop or a drain sends a priority 0
advertisement and the backup takes over after the skew time alone (well under a second at the
defaults). The new master announces the address with gratuitous ARP (IPv4) or an unsolicited
neighbour advertisement (IPv6), three times, so switches and neighbours update at once.

Senders that keep state per connection (TCP, TLS syslog) reconnect; UDP senders do not notice
beyond the gap.

### What differs from RFC 5798 (and why)

- **No virtual MAC.** The address moves with the node's own MAC plus the announcements above (what
  keepalived does by default). It works with every switch; devices that cache the old MAC for a
  long time and ignore announcements are rare, and the mitigation is the announcement itself.
- **Priority 255 (address owner) is not used.** The address is always added by Seshat, so priorities
  are 1-254.
- **IPv6 needs no link-local virtual address.** The advertised addresses are the configured ones.
- **Optional trailer, node tag and authentication.** After the address list Seshat appends a small
  trailer: an 8-byte node tag, and (with `auth`) an HMAC-SHA256 keyed from `SESHAT_CLUSTER_SECRET`.
  RFC 5798 has no authentication (it was removed from the protocol in v3), so this is an extension
  **both ends must enable**: a node with `auth` and one without ignore each other (and both claim the
  address; see troubleshooting). The tag lets two processes that share one host and interface address
  tell each other apart; the HMAC is bound to the sender and group addresses. Enable `auth` when other
  hosts on the segment must not be able to steal the address: without it any host on the segment can
  forge an advertisement and take (or knock over) the virtual address, so **turn it on for every
  instance** (a first-time configuration saved through the API or the Configure dialog on a cluster that has
  a secret signs by default, an explicit `"auth": false` is kept, and an existing configuration is never
  switched by an edit that does not mention it; in the API an omitted `auth` means unsigned) whenever `SESHAT_CLUSTER_SECRET` is set (the Configure dialog does so for new instances,
  and Seshat logs a warning for every running instance that does not sign). The signature is not
  bound to a counter: an attacker on the same segment who captured an advertisement can replay it, which
  is why VRRP belongs on a segment you control. `"interop": true` (cluster-wide, API
  only) removes the trailer for the rare case of sharing a virtual router with a non-Seshat VRRPv3
  speaker; it disables `auth`.

## Health-driven failover

Every 2 s each node samples the same signals as `/api/ready`:

| Signal | Counts as failing when | Default penalty |
|---|---|---|
| database | the store does not answer | 100 |
| listeners | any input listener (HTTP, traps, syslog, flows) is not bound | 100 |
| outputs | a destination lags by more than 60 s | 40 |
| disk queue | a bounded queue has less than 10 % headroom | 40 |

A signal must fail **2 probes in a row** to count and pass **3 in a row** to clear (so a blip does not
move the address). Failing signals subtract their penalty from the node's base priority (never below
1) and the lower value is advertised at once. A healthier node with a higher advertised priority then
takes the address; when the sick node recovers it gets it back (with preemption).

**Tuning rule:** the penalty you want to trigger a failover must be larger than the gap between the
base priorities. With 150 and 100, an output lag (penalty 40) leaves the master at 110, still above
the backup: nothing moves, which is usually what you want for a slow destination. A dead database
(100) takes it to 50, below the backup: the address moves. Adjust under **Configure > Health-driven
failover**; a penalty of 0 turns a signal off. The node's health score (0 to 100) and the failing
components are shown per node on the Cluster page and exported as `seshat_cluster_health_score`.

## Drain, stop and rolling upgrade

**Drain** (Cluster page > Drain, or `POST /api/cluster/drain` with an optional `{"node": "<name or
id>"}`):

1. The node releases its virtual addresses (priority 0 advertisement) and stays out of the elections;
   the others take over.
2. It keeps listening and processing: what senders still address to it, and what is already queued,
   is handled and delivered.
3. The Cluster page shows `draining` with the queued event count, then `drained, queues empty`. Then
   it is safe to stop it.
4. `/api/ready` returns 503 (`cluster_drain: draining`) so a load balancer in front stops sending.

Undrain puts it back (it takes its addresses again if its priority is the highest). Drain is not
persisted: a restarted node starts active.

**Stopping** (SIGTERM, `docker stop`, `systemctl stop`) does the same first: release the addresses,
keep serving for `SESHAT_DRAIN_GRACE` (default 3 s; senders move to the other node), wait up to
`SESHAT_DRAIN_TIMEOUT` (default 20 s) for the output queues to empty, then shut the listeners down.
Give the service time for all of it (`stop_grace_period: 40s`, `TimeoutStopSec=40`). Whatever is still
queued stays on the disk queue and is delivered when the node returns.

**A killed or crashed process cannot release its address**, and with host networking the address then
stays on the interface of the dead node. While another node is master, a running Seshat node that
finds a leftover address on its own interface removes it; for a node that is down, add an
`ExecStopPost=-/usr/sbin/ip addr del <vip>/32 dev <if>` (the systemd example has it) or restart the
node. A machine that really died takes its addresses with it.

### Rolling upgrade, two nodes, no loss

1. On node-b (the one currently *not* holding the address, or either in mode 2): **Drain**, wait for
   `drained, queues empty`.
2. Stop it, upgrade the image or binary, start it. Migrations run once, under a lock, and they are
   additive within a release train; check the release notes before mixing versions for long.
3. Wait until its row shows `active` and, in SQLite mode, the Cluster page shows the peer `in sync`.
4. Repeat for node-a. (With preemption the address returns to the preferred node on its own.)

## What is shared, SQLite versus PostgreSQL

| Data | PostgreSQL mode (shared database) | SQLite mode (peer protocol) |
|---|---|---|
| Settings (branding, input settings, connectors, `cluster.vrrp`, ...) | one copy | replicated, last writer wins per setting by modification time |
| SNMP engine ID | one copy, generated once | each node generates one if alone; **the numerically lowest wins everywhere** so a node joining adopts the cluster's (the peer join runs before the inputs start) |
| SNMPv3 users, registered sender engine IDs | one copy | replicated; deletes are remembered (tombstones) and not undone; needs the same `SESHAT_SECRET_KEY` |
| Flow templates | one copy | replicated, newer template wins; loaded into the running decoder |
| Device knowledge base | one copy | replicated per field, last writer wins by observation time; deletes are remembered; bare "unknown sender" stubs stay local |
| Routes, destinations | one copy | **not replicated**: configure the same ones on each node (the output queues are local anyway) |
| Users, sessions, audit log | one copy | **per node**: create the same administrators on each node (or use SSO); sign in to the node you administer |
| Event data and queues | local disk queue per node, never in the database | the same |
| Cluster membership and health | heartbeat rows in the database | exchanged over the peer link |

### The peer protocol (SQLite mode)

Enable it by setting, on every node (the same values except the peer lists):

```
SESHAT_NODE_NAME=node-a
SESHAT_CLUSTER_SECRET=<16+ characters, identical on every node>
SESHAT_CLUSTER_PEERS=http://192.0.2.12:8080          # the other nodes' API addresses, comma separated
SESHAT_CLUSTER_ADVERTISE=http://192.0.2.11:8080      # this node's own address (shown to the peers)
SESHAT_SECRET_KEY=<identical on every node>
```

- It is served on the API port under `/cluster/v1/`, outside the session API. Requests carry a
  timestamp, a random nonce and an HMAC-SHA256 (cluster secret) over method, path, timestamp, caller
  and nonce; a node accepts each nonce once (for four and a half minutes, longer than the clock-skew
  window), so a captured request, including `POST /cluster/v1/drain`, cannot be replayed. A request that
  changes state must carry a nonce. Responses carry an HMAC over the body **and the request it answers**
  (method, path, timestamp, nonce), so a response captured for one request does not verify for another.
  A wrong secret is rejected with 401 and the page says so. Every node holds the same secret and can
  therefore speak as any node: the secret is a cluster credential, not a per-node one.
- **Run it on a private network.** There is no encryption: the payloads are configuration (secrets in
  them are sealed under `SESHAT_SECRET_KEY`), device facts and node status, readable by anyone who can
  see the link. Put the nodes on a private segment, or front the API with TLS and use `https://` peer
  URLs (a private CA must be in the system trust store). Seshat logs a warning at start for every peer
  configured as plain `http://` on a non-loopback address.
- **Upgrading from 0.1.0.** A node that has the nonce rejects state-changing calls (drain, undrain)
  from one that does not, and a node that signs with the nonce rejects an older node's unbound
  responses; sync between the two resumes by itself once both are upgraded. Upgrade the nodes one
  after the other, back to back. The replay cache is in memory: a captured request stays replayable for
  up to about two and a half minutes after the receiving node restarts (the signed timestamp window), the
  same bound as without the nonce.
- Each node pulls from every peer every `SESHAT_CLUSTER_SYNC_INTERVAL` (default 5 s) after comparing
  content digests, so a quiet cluster costs one small request per peer; a mismatching section is
  transferred and merged. The same exchange runs once, before the inputs start, when a node boots
  (**join sync**), so a new node starts with the cluster's engine ID, v3 users and templates.
- The page shows per peer: link state, how long ago the data last matched (`in sync` or `N s
  behind`), which sections are in step, and the last error (a different `SESHAT_SECRET_KEY` is called
  out because sealed values cannot move between such nodes).
- Conflicts: a setting, v3 user or template is taken from whichever node modified it last; a device
  field from whichever observed it last (ties broken by confidence, source, then value, so every node
  makes the same choice). Addresses and hostnames of a device are unioned. Devices are matched by
  scope and address, engine ID or serial, never by internal ID.

## Mode 3: BGP anycast

Every healthy node announces the **same** service address (a /32, and a /128 for IPv6) to your
routers with BGP. The routers install one equal-cost path per node and spread senders over them
(ECMP). A node that is unhealthy, drained, stopping or has lost a listener or the database
**withdraws** the route, so the routers stop sending to it. There is no shared L2 segment, no
multicast and no virtual address to fail over: the nodes can be in different racks, subnets or
sites. The speaker is [GoBGP](https://github.com/osrg/gobgp) (Apache-2.0) embedded in the Seshat
process as a library; there is no second daemon to run.

### Requirements

| Need | Why | How to check |
|---|---|---|
| A router (or several) that speaks BGP and does ECMP | it holds the paths and spreads senders over them | `show ip route <service address>` lists one next hop per Seshat node |
| An AS number for the nodes (a private one, 64512-65534 or 4200000000-4294967294) and one for the router | eBGP between the router and the nodes; all nodes share one AS, each has its own router ID | router config: [`deploy/network/bgp/`](../deploy/network/bgp/) |
| IP reachability from each node to the router address(es) it peers with | the TCP session; Seshat connects out to the neighbour (port 179) | `ip route get <router address>` on the node |
| `CAP_NET_ADMIN` in the process's effective set | adds the service addresses to the loopback, and sets the TCP-MD5 key on the session | the BGP panel on the Cluster page shows the exact missing capability and never crashes |
| Host networking (containers) | the service address goes on the host's loopback so the wildcard listeners answer on it | `network_mode: host` |
| The same `SESHAT_SECRET_KEY` on every node | the neighbour passwords are sealed with it in the shared configuration | same as for SNMPv3 users |

With the `seshat` package, the drop-in
[`deploy/systemd/drop-ins/anycast-bgp.conf`](../deploy/systemd/drop-ins/anycast-bgp.conf) adds
`CAP_NET_ADMIN` (install it as `/etc/systemd/system/seshat.service.d/anycast-bgp.conf`, like the VRRP one).
`CAP_NET_RAW` and multicast are **not** needed (that is VRRP). If the process cannot add an address
to the loopback and the address is not already there, that prefix is **not announced** (announcing an
address the node does not answer on would attract traffic into a black hole) and the panel says why.
You may provision the addresses yourself (`ip addr add 198.51.100.10/32 dev lo`, or a systemd
network unit) and turn programming off (`program_addresses: false`); Seshat then only checks that
they are present.

The `deploy/compose/ha-anycast.example.yaml` file runs two nodes on one host for a trial;
[`deploy/network/bgp/`](../deploy/network/bgp/) has the router side for FRR, Cisco IOS-XE, Juniper
Junos, Arista EOS, MikroTik RouterOS and VyOS.

### Configuring it

Cluster page > BGP anycast > Configure (or `PUT /api/cluster/bgp`). The configuration is
cluster-wide: it is stored in the `cluster.bgp` setting, shared in PostgreSQL mode and replicated
in SQLite mode, so every node gets it within seconds. Only the router ID differs per node.

| Field | Meaning |
|---|---|
| `enabled`, `local_as` | the speaker and Seshat's AS (eBGP: it must differ from the router's) |
| `router_id`, `router_ids` | the BGP identifier (an IPv4 address) and per-node overrides by node name. Must be unique among the nodes; use each node's own address |
| `neighbors[]` | `address`, `remote_as`, optional `password` (TCP-MD5, RFC 2385: stored sealed with AES-256-GCM keyed from `SESHAT_SECRET_KEY`, **never returned** by the API; omit to keep it, `clear_password` to drop it), `multihop_ttl` (0 or 1: directly connected; 2-255: multihop eBGP), `hold_time_seconds` (default **9**) and `keepalive_seconds` (default a third of the hold time), `port` (179), `local_address`, `description`. A neighbour's address family decides what is announced to it: an IPv4 neighbour carries the /32s, an IPv6 neighbour the /128s. For both families configure two sessions |
| `prefixes[]` | the anycast service addresses: `prefix` (`/32` or `/128`), `communities` (`64512:100`, `no-export`...), `med`, `local_pref` (iBGP only) |
| `withdraw.on` | which conditions withdraw: `score`, `listeners`, `store` (default all) and `drain` (always; it cannot be removed) |
| `withdraw.min_health_score` | withdraw while the node's health score is below this (default **70**; the score is the one on the Cluster page and `seshat_cluster_health_score`) |
| `withdraw.min_up_seconds` | hysteresis: after process start and after every withdrawal the node must be continuously healthy this long (default **15**) before it announces again; 0 disables it |
| `program_addresses`, `address_interface` | add the prefixes to this interface (default `lo`) while the speaker runs, and remove them when it stops |
| `listen_port`, `listen_addresses` | also accept sessions the routers initiate (default off: Seshat connects out; port 179 needs `CAP_NET_BIND_SERVICE`) |

Set the router to **not** be passive towards Seshat, and import only the service prefixes from it
(prefix-list examples in the router configs). Seshat accepts and ignores whatever the router sends.

### When a node announces and withdraws

The speaker is driven by the same health report as VRRP priorities (probes every 2 s, a component
must fail 2 probes in a row to count and pass 3 in a row to clear). A node announces only while
**none** of the enabled conditions holds, in this order of precedence:

| Reason (metric label) | Condition |
|---|---|
| `drain` | an administrator drained the node, or the process is stopping (SIGTERM) |
| `store` | the database does not answer |
| `listeners` | an input listener (HTTP, traps, syslog, flows) is not bound |
| `unhealthy` | the health score is below `min_health_score` |
| `manual` | an operator withdrew it (see below) |
| `address` | a prefix whose address is not on the host and could not be added |
| `holddown` (state, not a withdrawal) | healthy, but not yet for `min_up_seconds` |

Withdrawals are sent at once (a BGP UPDATE with the prefixes withdrawn); a drain or SIGTERM
withdraws before anything else, then the node keeps serving for `SESHAT_DRAIN_GRACE` (3 s) while the
router converges and senders move, then flushes its queues. Re-announcing waits for the hold-down,
so a node that flaps between healthy and unhealthy never flaps the routes: the minimum up time
restarts every time it goes unhealthy.

**Manual override** (admin; Cluster page buttons with a confirmation and a required reason, or
`POST /api/cluster/bgp/withdraw` `{"reason": "..."}` and `POST /api/cluster/bgp/announce`):

- *Withdraw* keeps this node's prefixes withdrawn, whatever its health, until you resume.
- *Resume automatic* (`announce` without `force`) hands control back to the rules; if the node has
  been healthy for the minimum up time it announces immediately.
- *Force announce* (`{"force": true, "reason": "..."}`) announces regardless of health and the
  hold-down, for example to bring traffic back to the only node left. A drain still withdraws.

Overrides act on the node that serves the request and are not persisted: a restarted node follows
the rules again. (The reason is shown on the page and recorded in the audit log.)

### Failover timing (default timers)

| Event | What the routers see | Traffic moves after |
|---|---|---|
| Graceful stop (SIGTERM), drain, manual withdraw | a BGP UPDATE withdrawing the prefixes, immediately | the router's convergence time, normally well under a second to a few seconds; the node keeps serving `SESHAT_DRAIN_GRACE` (3 s) in the meantime |
| Node unhealthy (database, listener, score) | a withdrawal after 2 failed probes | 2 to 4 s of detection plus the router's convergence |
| Process killed | the TCP session is reset by the host: routes are removed at once | the router's convergence |
| Host powered off or cable pulled | nothing until the hold timer expires (**9 s**, negotiated down from the router's value) | up to 9 s; BFD would make it sub-second but is **not part of Seshat** (see below) |
| Node recovers | an announcement after the health probes clear (3 probes, about 6 s) plus the minimum up time (15 s) | about 20 s after the fault is gone |
| Process start | an announcement 15 s after start (the hold-down), once the listeners are bound | |

UDP senders lose the datagrams sent to a dead node during the detection time; there is no
retransmission. TCP and TLS syslog senders reconnect. **BFD** is out of scope: Seshat does not
speak it. If you need sub-second detection of a dead host, run BFD between the router and the
node's host with the operating system's own BFD (for example FRR's `bfdd` on the host) and keep the
hold timer as the backstop; the router examples show where the BFD line goes.

### ECMP, stickiness and locality

Invariant 2 above (sender-to-node stickiness) is now the router's job. Configure the router so that
**one sender always hashes to the same node**:

- Hash on at least the **source address** (an L3 hash of source and destination address does this;
  adding transport ports is fine for UDP senders that keep their source port but spreads one
  exporter's flows over several nodes if it uses several source ports, so prefer source and
  destination address only). The default of most routers is per-flow hashing on the L3/L4 tuple:
  check yours. On a Linux router use `net.ipv4.fib_multipath_hash_policy=0` (and the `net.ipv6`
  twin), which hashes source and destination address.
- Use **resilient (consistent) hashing** where the platform has it. With plain modulo hashing, adding
  or removing one of N next hops re-assigns most senders (about (N-1)/N of them); with resilient
  hashing only the senders of the removed path move, and a returning node takes back only its share.
- Multipath for eBGP with the same neighbouring AS needs no relaxation; with different AS numbers per
  node you need the platform's `multipath-relax` equivalent. The examples use one AS for all nodes.

What happens when a sender moves (a node was added, removed, withdrew or came back):

- **Flows (NetFlow/IPFIX/sFlow).** Templates are shared between the nodes (replicated every few
  seconds in SQLite mode, read from the database in PostgreSQL mode), so the new node can decode the
  moved exporter's data records at once. A template learned in the last replication interval may not
  have arrived: records using it are counted as `no_template` and dropped until it has, or until the
  exporter re-sends it. The loss is therefore **at most one template refresh interval** of that
  exporter's flows (typically 20 s to 10 min depending on the exporter), usually much less.
  Sequence-number gap tracking restarts on the new node.
- **SNMPv3.** One engine ID and one USM key set per cluster are shared (see Cluster-wide
  invariants). A sender that moves keeps authenticating and an inform's response matches the engine
  ID it cached. This is why **`SESHAT_SECRET_KEY` and the SNMP engine ID must be cluster-wide**.
- **Syslog.** UDP continues on the new node; TCP and TLS connections are reset by the move and the
  sender reconnects (standard behaviour).
- **Per-sender rate limits and counters** restart on the new node.

*Locality.* Anycast gives the nearest replica for free when the routers see paths of different cost:
each site's router peers with its local nodes and carries the remote ones over the WAN (or iBGP) at
a worse cost, so senders go to the replica in their site and only cross the WAN when no local one is
announcing. Steer with the attributes Seshat can set per prefix: `med` (lower wins between paths from
the same neighbouring AS), `communities` (match them in the routers' import policy to set a higher
local preference for the site-local group, or to keep a prefix inside a site with `no-export`), and
for different node groups use different prefixes. Keep the number of nodes per site at two or more
so a withdrawal does not push a site's senders over the WAN.

### Rolling upgrade with withdraw-first

1. On the node to upgrade: **Drain** (Cluster page, or `POST /api/cluster/drain`). The prefixes are
   withdrawn at once; the node keeps processing until the page shows `drained, queues empty`. (A
   manual *Withdraw* would also move the senders but does not wait for the queues.)
2. Check on the router that the node's next hop is gone from the ECMP set.
3. Stop it, upgrade, start it. It comes up withdrawn, announces 15 s after its listeners are bound,
   and the Cluster page shows `announcing` and the session `established`.
4. Check that the router lists the node again, then repeat with the next node. With at least two
   other healthy nodes the senders never see a gap; with one other node, plan for its capacity.

Stopping a node (SIGTERM, `docker stop`, `systemctl stop`) does the first step by itself: withdraw,
serve for the grace period, flush, exit. A drain first just lets you see it happen.

### Metrics, API and the page

| Metric | Meaning |
|---|---|
| `seshat_bgp_session_state{neighbor}` | 0 not running, 1 idle, 2 connect, 3 active, 4 opensent, 5 openconfirm, **6 established** |
| `seshat_bgp_prefix_announced{prefix}` | 1 while the prefix is announced, 0 while withdrawn |
| `seshat_bgp_withdrawals_total{reason}` | `unhealthy`, `listeners`, `store`, `drain`, `manual`, `address`, `disabled`, `shutdown` |

Alert on `seshat_bgp_session_state != 6` for more than a minute, on
`sum(seshat_bgp_prefix_announced{prefix="198.51.100.10/32"}) < 2` (fewer than two replicas
announcing) and on `increase(seshat_bgp_withdrawals_total[10m]) > 3` (flapping).

API: `GET /api/cluster/bgp` (admin, operator: speaker state, neighbours with session state, uptime,
prefixes sent and received, flaps and the last error, prefixes with the reason for any withdrawal,
the configuration without passwords, the other nodes' states), `PUT /api/cluster/bgp`,
`POST /api/cluster/bgp/withdraw`, `POST /api/cluster/bgp/announce` (admin). The Cluster page shows
the same in the BGP anycast panel.


### Troubleshooting (mode 3)

| Symptom | Likely cause |
|---|---|
| Session stays `active` or `connect` | the router is not reachable, or filters TCP 179; check `ip route get`, the router's neighbour config and ACLs; with a password, both sides must have the same key and the process needs `CAP_NET_ADMIN` |
| Session flaps with a `hold timer expired` event | the keepalive is lost: raise the hold time, check the path MTU and CPU starvation of the node |
| Session `established` but the router has no route | the router's inbound prefix-list does not permit the /32 (/128), or the prefix is withdrawn on this node (the panel says why) |
| Prefix shown `withdrawn: address` | the process can not add the address to the loopback (capability) and it is not there; grant `NET_ADMIN`, or add the address yourself and set `program_addresses` to false |
| Only one path in the router's table | `maximum-paths` is 1 (the default on several platforms), or the paths differ in AS path length or origin; see the router examples |
| One exporter's flows land on two nodes | the router hashes on ports as well, or a different hash for IPv6; fix the hash (see above) |
| Neighbour shows `error: the stored password can not be opened` | `SESHAT_SECRET_KEY` on this node differs from the node that saved the configuration |
| Nothing is announced after start | the 15 s hold-down, a listener that is not bound yet, or the node is drained |

## Mode 4

Mode 4 hands the spreading and the failover to a load balancer you already have. Seshat's part is
to be a good back end: honest health signals, a graceful drain, no dependence on which replica gets
a packet, and a loud failure when the balancer rewrites source addresses.

### Contract with the load balancer

| Endpoint | Meaning |
|---|---|
| `GET /api/health` | liveness: `200 {"ok":true}`, unauthenticated, plain HTTP. Never fails while draining. |
| `GET /api/ready` | readiness: 200 when the store and every listener are up, 503 otherwise **and while draining**. Anonymous callers get only `{"ready":true|false}` and the status code; the body of an administrator, an operator or the `SESHAT_METRICS_TOKEN` bearer also names each check (`store`, `snmp_trap`, `syslog-udp`, ..., `drain`, `source_ip`). Point the balancer's health check here. |
| `POST /api/drain?timeout_seconds=N` | become not ready, then wait (at most N seconds, default 25, maximum 600) for the destination queues to flush. Admin session, or the `X-Seshat-Drain-Token` header (an HMAC of `SESHAT_SECRET_KEY`, what `seshat --drain` sends). Intake is **not** paused: packets already in flight are accepted, not lost. `DELETE /api/drain` (admin) cancels. |
| `seshat --drain [--drain-timeout 25s] [--drain-hold 10s]` | the same call from the CLI, for `preStop` hooks, systemd `ExecStop` and keepalived notify scripts; `--drain-hold` keeps it from returning early so a health check can notice. Exit 0 when the instance is already gone. |

There is one drain switch per process. `POST /api/drain`, `POST /api/cluster/drain` (this node),
`POST /api/cluster/undrain`, `DELETE /api/drain` and a drain forwarded by a peer all set or clear the
same state: `/api/ready` answers 503 with `drain: draining` while it is set, and the VRRP/BGP manager
leaves the elections and withdraws its prefixes, so the Cluster page and the load balancer agree.
Intake is never paused. (A SIGTERM drains the cluster manager the same way.)

Stop sequence for any balancer: drain (not ready) -> the balancer stops sending (one to three health
intervals) -> SIGTERM -> the process stops its listeners, flushes queues, exits.

### Source address preservation

`SESHAT_EXPECT_SOURCE_IP_PRESERVED=true` with `SESHAT_LB_SNAT_CIDRS=<ranges>` turns on a check in the
listeners (SNMP, syslog UDP/TCP, flows). When a datagram or connection arrives from one of the
ranges you listed (the balancer's SNAT pool, the cluster's node addresses), `/api/ready` reports (to an administrator, an operator or the metrics token)
`"source_ip": "snat_detected"`, the log carries `SOURCE ADDRESS REWRITING DETECTED` once a minute
while it continues, and the Dashboard shows a red "Source addresses" tile. The pod stays ready: the
check informs, because pulling every pod out of rotation would also take the UI away. The compare
is a few prefix tests and an atomic add; there is no I/O on the hot path. Alert on the check value.

### Kubernetes

The Helm chart (`docs/kubernetes.md`) implements mode 4 with a `LoadBalancer` Service that has
`externalTrafficPolicy: Local`. With `Cluster`, kube-proxy SNATs to a node address whenever it
forwards to a pod on another node, which is exactly the failure above. `Local` sends traffic only to
pods on the receiving node, so the balancer must health-check nodes (`healthCheckNodePort`) and
pods must be spread over the nodes that receive traffic.

**MetalLB.** `deploy/k8s/examples/metallb/`:

- *BGP* (`bgp.yaml`): every node with a ready pod announces the address; the router's ECMP spreads
  senders and keeps a sender on one node; a node without a ready pod withdraws the route. This is
  the mode-3-like behaviour on a cluster and the one to use for more than one receiving node.
- *L2* (`l2.yaml`): one node answers ARP/NDP at a time, so all intake lands on that node (no load
  spreading) and failover is an ARP move. Simple, source-preserving with `Local`, one receiving node.

**IPVS in direct-return (DSR) mode** (a keepalived/IPVS pair in front of VM or bare-metal nodes, or
nodes of a cluster that run the pods on `hostNetwork`). The balancer forwards the packet unchanged
to the real server, which answers directly, so nothing rewrites the source:

```
# on each real server (Seshat host): own the virtual address on loopback, do not answer ARP for it
ip addr add 192.0.2.10/32 dev lo
sysctl -w net.ipv4.conf.all.arp_ignore=1 net.ipv4.conf.all.arp_announce=2

# keepalived.conf on the balancer (one virtual_server per port; UDP traps shown)
virtual_server 192.0.2.10 162 {
    delay_loop 5
    lb_algo sh            # source hash: a sender sticks to one real server
    lb_kind DR
    protocol UDP
    real_server 198.51.100.11 162 {
        weight 1
        HTTP_GET { connect_port 8080  url { path /api/ready  status_code 200 } connect_timeout 3 }
    }
    real_server 198.51.100.12 162 { weight 1  HTTP_GET { connect_port 8080  url { path /api/ready  status_code 200 } connect_timeout 3 } }
}
```

The health check hits `/api/ready` on the UI port, so a draining or unhealthy node leaves the
rotation. The real servers must listen on the virtual address (Seshat listens on all addresses by
default). Two real servers in the same L2 domain as the balancer, no reverse-path filtering that
drops the loopback-addressed replies. (The `lb_algo sh` and DR settings are standard IPVS; they are
a starting point and have not been exercised by the maintainers.)

**Cloud network load balancers.** Use the passthrough/network type, keep `Local`, and check the
provider's client-address setting: the balancer must not proxy or SNAT. As the providers document it
(not verified by the maintainers): an AWS Network Load Balancer preserves the client address
for instance targets and offers `preserve_client_ip.enabled` on IP targets; GKE's passthrough
network load balancer preserves it with `externalTrafficPolicy: Local`; an Azure Standard Load
Balancer passes the client address through with `Local`. Application load balancers (HTTP) never fit
telemetry. After install, look at the Dashboard tile and `GET /api/ready` (with the metrics token) from a real device.

### Not covered by mode 4

A replica's local disk queue is unavailable while its pod is down (the optional shared message bus in
`outputs.md` removes that). Mode 4 does not make the balancer itself highly available; that is the
balancer's job (two MetalLB speakers, a keepalived pair, the cloud provider).

## Metrics, API and the page

| Metric | Meaning |
|---|---|
| `seshat_vrrp_state{instance,vrid}` | 0 init (or drained), 1 backup, 2 master |
| `seshat_vrrp_priority{instance,vrid}` | priority this node advertises now (after health penalties) |
| `seshat_vrrp_transitions_total{instance,vrid}` | state changes |
| `seshat_vrrp_advertisements_total{...,direction}` | sent and accepted |
| `seshat_vrrp_dropped_total{...,reason}` | `auth`, `checksum`, `ttl`, `malformed`, `trailer`, `vip_mismatch` |
| `seshat_cluster_health_score` | 0-100 |
| `seshat_cluster_drained` | 1 while drained |
| `seshat_cluster_peers{state="up"\|"down"}` | other members by liveness |

Alert on `seshat_vrrp_state == 2` summing to other than one per instance across the cluster (none:
nobody holds the address; two: split brain), and on `rate(seshat_vrrp_transitions_total[10m]) > 4`
(flapping).

API (all under `/api`, role-gated; see `/api/openapi.json`): `GET /cluster` (admin, operator),
`PUT /cluster/vrrp`, `POST /cluster/drain`, `POST /cluster/undrain` (admin). BGP (mode 3): see
[Mode 3](#mode-3-bgp-anycast).

## Trying it on one machine

Two containers with host networking on one machine share the interface and its address, which is
fine for VRRP (the node tag tells the two apart) but has consequences:

- Give each its own listen ports (the compose example does) and its own data directory.
- Both processes see the same network namespace, so "the other node's" address is the same one:
  when the master releases the address, the other process may add it before the first removes it;
  the master re-adds a vanished address within one advertisement interval. On separate machines this
  does not occur.
- Pick a **free** address in the machine's subnet for the virtual address and check with `ping`
  that nothing answers before you start. `ip -br addr show dev eth0` shows which process holds it.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Cluster page: "VRRP needs CAP_NET_ADMIN and CAP_NET_RAW..." | the process lacks the capabilities in its effective set; run as root with `cap_add`, or systemd ambient capabilities. The rest of Seshat keeps running |
| Instance state `fault`: "interface ... no subnet contains" | the virtual address is not in a subnet of any interface; set `interface` or choose an address in the segment |
| Two nodes both `master` (the page flags "more than one master") | they cannot hear each other: multicast/protocol 112 filtered, different VRID or addresses (counted as `vip_mismatch`), mismatched `auth` (`dropped_total{reason="auth"}`), different VLANs |
| Nobody holds the address | both nodes drained, a node not running VRRP (`SESHAT_VRRP_DISABLE=1`, role without listeners), or a fault shown on the instance |
| Address flaps between nodes | priorities too close together with health penalties, or advertisements being lost (raise the interval and check the switch); `preempt_delay_ms` smooths it |
| Senders do not follow after failover | the switch/router caches the old MAC and ignores gratuitous ARP; shorten its ARP timeout or enable gratuitous ARP handling |
| Peer shows `down` | wrong URL, port, or firewall; `SESHAT_CLUSTER_SECRET` mismatch shows as a 401/bad signature in the error |
| A setting changed on one node does not appear on the other (SQLite) | check the peer row: sections not "in step", a secret key mismatch, or a node name/URL error |
