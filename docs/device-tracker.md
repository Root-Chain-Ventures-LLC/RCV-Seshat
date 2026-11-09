# Device Tracker

The Device Tracker answers one question: **where is this device, right now, and where has it been?**
You give it a MAC address, an IP address, a hostname or a user; it answers with the device's
identity, its current attachment point (switch port or access point), its IP addresses and a
history, and every fact says how old it is and how Seshat learned it.

It is **read-only toward the network**. Nothing in the Device Tracker writes to a device (see
[the read-only guarantee](#the-read-only-guarantee)).

The wire contract with the Device Tracker portal is [`schema/tracker.md`](schema/tracker.md); the
collector and sighting file format is part of the vendor pack format.

## How location is determined

Two kinds of source feed the same store.

**Polling** (`source` = `poll-fdb`, `poll-arp`, `poll-wireless`, `poll-subscriber`). For every device you enable,
Seshat reads the tables below with SNMP GET and GETBULK, using the collectors of the vendor pack
that matches the device:

| Table | Learns | Collector |
|---|---|---|
| `dot1dTpFdbTable`, `dot1dBasePortTable` (BRIDGE-MIB) | MAC to bridge port to ifIndex | `bridge-fdb` |
| `dot1qTpFdbTable`, `dot1qVlanCurrentTable` (Q-BRIDGE-MIB) | MAC to port, with the VLAN | `qbridge-fdb` |
| `vtpVlanTable` plus BRIDGE-MIB per VLAN (Cisco) | the same, one bridge instance per VLAN | `cisco-bridge-fdb-per-vlan` |
| `ipNetToPhysicalTable`, `ipNetToMediaTable` (IP-MIB) | IP to MAC, per VRF | `arp-ip-net-to-physical`, `arp-ip-net-to-media` |
| `ifTable`, `ifXTable` (IF-MIB) | port names, descriptions (`ifAlias` becomes the inventory trace), status | `interfaces` |
| LLDP-MIB, CISCO-CDP-MIB | neighbours, for uplink exclusion | `lldp-neighbors`, `cisco-cdp-neighbors` |
| controller client tables | client to AP, SSID, band, channel, signal, user | `cisco-aireos-clients`, `cisco-c9800-clients`, `aruba-wlan-stations`, `ruckus-zd-stations` |
| `docsIfCmtsCmStatusTable` (DOCS-IF-MIB), HUAWEI-XPON-MIB ONT tables | cable modem or ONT to circuit, IP | `docsis-cmts-modems`, `huawei-gpon-onts` |

A **binding** in the pack chooses which collectors run for which device (by vendor, product, model,
OS, role or pack, highest priority wins), with a fallback collector when the first fails or is
empty. The Tracked devices page shows the binding that applies.

**Events** (`source` = `trap`, `dhcp`, `radius`, `ad`, `flow`). The same patterns that classify
syslog and traps also extract tracker facts as the events go by, so a location can be seconds old
instead of minutes. See [event-driven sightings](#event-driven-sightings).

The current location of a MAC is the open location or wireless interval that was confirmed most
recently. A port that has a switch or router behind it is never a location (next section).

### Why uplinks are excluded

A MAC learned on a trunk or inter-switch port is not "on" that port. It is somewhere further away
and merely reachable through it. If every switch's FDB counted, an endpoint would appear on every
switch between it and the core, and the answer would flap between them.

So after each poll Seshat decides which ports are **uplinks** and never reports a MAC learned on
one as an endpoint's location:

- a port whose LLDP or CDP neighbour is itself a switch, router, firewall, controller or AP that the
  device knowledge base already knows (matched by management address, name or chassis MAC), or
- a port whose neighbour advertises a capability of `bridge`, `router` or `wlan-access-point`,
  unless it also advertises `telephone`, `station-only` or `docsis-cable-device` (an IP phone
  bridges, but the PC behind it is an endpoint). The lists are `uplink_detection` in the packs and
  are merged across packs.

Entries skipped for these reasons are counted in the poll report (Tracked devices, Poll now) so you
can see them. A port with no neighbour information at all is treated as an access port, so a
switch that does not run LLDP or CDP toward an unmanaged downstream switch will report the
downstream MACs on that port. That is the best available answer, and it is correct for the unmanaged
switch case.

A MAC that appears on several non-uplink ports in one poll is placed on the lowest ifIndex, so the
choice is stable between polls and never flaps.

## Poll intervals

| Class | Default | Used by |
|---|---|---|
| `access-switch` | 10 min | switches |
| `core` | 10 min | routers, firewalls, L3 |
| `arp` | 10 min | ARP-only collectors |
| `wireless` | 5 min | controllers |

The class comes from the binding; each device can override the class or set an interval of 30 s to
24 h. Polls are **spread**: a device's first poll is at a stable offset inside its interval (a hash
of its id), later polls are jittered by plus or minus 10 %, so pollers do not fire together.

After **3 consecutive failures** the device is marked `paused` and polled with exponential
backoff (the interval doubles per further failure, capped at 6 h) until a poll succeeds. The status
and the last error are on the Tracked devices page.

Limits per device: `SESHAT_TRACKER_RATE` requests per second (default 50) **shared by the tracker poll and
the metrics poll of that device** (one budget per device, whichever class asks), a PDU budget per
collector, a 5 minute timeout per collector, `SESHAT_TRACKER_WORKERS` device polls at a time
(default 4; the metrics class has a pool of its own, `SESHAT_TRACKER_METRIC_WORKERS`, default 4). `SESHAT_TRACKER_POLL=0` turns the pollers off on an instance. To spread polling over
replicas, give each one `SESHAT_TRACKER_SHARD=i/n`: a device is polled by the instance whose index
equals the hash of the device id modulo n.

### Polled by the server or by an edge

A device is polled by **one** poller: this server (the default), an [edge](edge.md#polling-on-the-edge) on the
device's network, or an [edge group](edge.md#edge-groups) of such edges, which assigns the device to one of its members. The setting is per site, with a per-device override (Tracked devices, *Who polls the devices*, which also lists the edge groups of the site; the
`polled-by` routes in the API), and the Tracked devices page and `GET /api/tracker/devices` show the owner of each device
(`owner`). Whoever owns a device polls it with these same packs, intervals, spreading and backoff, and the result is stored
the same way; the status columns (last poll, error, failures, next poll) are written by whoever polled. A server that does
not own a device does not poll it, whatever `SESHAT_TRACKER_SHARD` says, and poll-now for an edge-owned device is done by
the edge. If the edge is offline the server does not take the device over: its status stays as the edge last reported it and
poll-now answers `503 edge_offline` ([when the edge is offline](edge.md#when-the-edge-is-offline)).

A **link-up trap** (or its syslog twin) triggers an immediate, single-port poll: only the
forwarding, bridge-port, neighbour and interface collectors run, and only entries on that port are
stored. Bursts for one device are coalesced for 2 s and spaced at least 20 s apart.

### Per-VLAN contexts on Cisco

A Catalyst-style switch keeps one bridge instance, and so one FDB, per VLAN, and exposes it
through BRIDGE-MIB only when the request names the VLAN: on SNMPv1/v2c as the community suffix
`<community>@<vlan>`, on SNMPv3 as a context. Walking only the default context therefore finds only
VLAN 1.

The `cisco-bridge-fdb-per-vlan` collector walks `vtpVlanTable` once in the default context, takes the
operational Ethernet VLANs (excluding 1002 to 1005, the FDDI and Token Ring defaults), and then reads
the bridge tables once per VLAN in that VLAN's context. SNMPv3 uses the context name
`vlan-<id>` (`v3_context_template`). The number of contexts is capped at 1024 per poll; a larger
VLAN list is truncated and the poll report says so.

Cost to expect: the walk is repeated for every VLAN, so a switch with 200 VLANs costs roughly 200
times the requests of a single-FDB switch. The per-device rate limit bounds the load on the
switch, at the price of a longer poll, so give such a device a longer interval. Configuring the
switch so that these contexts exist (the SNMP community or the v3 context to VLAN mapping) is a
platform setting: follow your platform's documentation. A context the device refuses is reported
as a poll warning and the other VLANs still load.

For VRF-aware ARP (`per-vrf-context`), list the VRF names on the device; SNMPv3 uses the VRF name as
the context name, SNMPv1/v2c needs a community per VRF (`name=community`).

## SNMP metric polling

Besides the MAC tables, the poller can read **metrics** from the same devices: interface traffic, errors and status, CPU,
memory, temperature, power supplies, fans and optics. They are the way to get counters from devices that cannot stream
telemetry or export flows, and they leave as `seshat.metric` events in the shape streaming telemetry produces
(`seshat.metric.source` is `snmp`), so every metric destination (Prometheus remote write, InfluxDB, OTLP) and every
route that matches `event.dataset == "seshat.metric"` takes them unchanged. Counters are sent raw (64 bits where the
device has them, `seshat.metric.kind: counter`); take the rate in your backend.

**One form for interface metrics.** An interface series has the same form whichever input made it (SNMP polling, sFlow
counter samples ([`inputs/flows.md`](inputs/flows.md)), gNMI): the keyed path
`/interfaces/interface[name=<if>]/state/counters/in-octets`, the single label `interface`, a `kind`, and the name
`ifName`, else `ifDescr`, else the ifIndex. The pack writes the keyless path (`interfaces/interface/state/...`); the
event carries it with the interface as the key. `host` comes from `host.name` (the inventory name of the device) and
`site` from the device's scope, so an interface counter read by SNMP and by sFlow from the same device is the same
Prometheus series (same name, same `host`, `interface` and `site` labels); only `seshat.metric.source` differs.

**Turn it on per device** (Tracked devices, *Settings*, *Metrics*, or `PUT /api/tracker/devices/{id}` with
`metrics_enabled`). The device must be tracked (enabled) and a metric binding must apply to it. It is off by default, so an
upgrade adds no polling.

| Setting | Meaning |
|---|---|
| `metrics_interval_seconds` | 0 is the class default of 60 s; 30 s to 24 h. Spread and jittered like the other classes. |
| `metrics.include`, `metrics.exclude` | Glob patterns (`*`, `?`, case-insensitive) on the interface name: with `include` only matching interfaces are polled, `exclude` removes matches. They apply to every per-interface series, state included. |
| `metrics.up_only` | Leaves out the counters and gauges of interfaces that are not oper-up; their oper-status series is still sent, so a down port stays visible. |
| `metrics.max_series` | The cap on series per poll (default 10000, 10 to 100000). State and health series (oper and admin status, CPU, memory, sensors) are kept first, then interface counters, cut by whole interface in ifIndex order, so an interface never has half its counters. A poll over the cap reports `partial` with the number left out (`last_metrics_dropped`, `seshat_tracker_metric_series_dropped_total{reason="capped"}`). |

**Site defaults and bulk changes.** For a fleet, set the metrics once per site: `PUT /api/tracker/metrics/defaults`
(`{"sites": {"<site>": {"enabled", "interval_seconds", "metrics": {...}}, "*": {...}}}`; the key `*` covers every site without
an entry; the Tracked devices page has the editor under *Metrics defaults*; audited as `tracker.metrics.defaults.update`).
A tracked device that has no metrics settings of its own follows its site's entry and shows `metrics_inherited`; the first
setting saved on the device makes its settings its own (`metrics_override`), and `metrics_inherit: true` gives it back to the
site. Edges are served the effective settings with the device assignment, so a change reaches them in their configuration.
`PUT /api/tracker/metrics/bulk` changes many devices at once: name `device_ids`, or a `selector` with a `site` (and optionally
`role` and `class`), plus the settings to apply or `metrics_inherit`; with `"dry_run": true` it only counts (`matched`,
`changed`, and the `skipped` devices with the reason: not tracked, no metric binding).

**What runs.** The *metrics class* is a second scheduler beside the tracker class. It runs only the metric collectors
(the `metric` emit of the pack format), not the 10-minute tracker collectors, and has its own cadence, failures, backoff and pause
(three failures in a row, then doubling, capped at **5 minutes** for this class; the tracker class still caps at 6 hours): a
device whose metric tables time out is not paused for tracking and the other way round.

**Time limits of a metrics poll** (not the tracker's 5 minutes per collector): the whole poll has a deadline of 45 s, never
more than the interval, and a poll that runs into it fails with that message. If the first request of the first collector
gets no answer the device is marked unreachable for this cycle and the other collectors are skipped (one timeout, not one per
table). A poll that takes longer than its interval is reported `partial` with "overrun" and counted
(`seshat_tracker_metric_overruns_total`). The workers of the metrics class are a pool of their own
(`SESHAT_TRACKER_METRIC_WORKERS`, default 4), so slow metric polls cannot starve the tracker polls.

**Counter width.** The 64-bit interface counters are read first. Only when the device answers the high-capacity table with
nothing (no such object, end of view, empty) and no error are the 32-bit counters used, and the device stays on them (a series
never changes width because of a lost packet) until the 64-bit table answers again; it is asked again every 20th poll. A walk
that fails makes the poll `partial` with the error, never `ok`, and the 32-bit collector is not run. A vendor collector that
replaces a standard one (the Cisco processor view for `hr-cpu`) does so only when it returned series in that poll, so a model
without the vendor MIB keeps the standard collector. Interfaces are labelled by ifName, else ifDescr, else the ifIndex; two
interfaces with the same label are reported (`seshat_tracker_metric_label_collisions_total`, and the poll is `partial`). The standard pack reads IF-MIB (64-bit counters, with a 32-bit fallback for devices without
them; errors and discards; oper and admin status; `ifHighSpeed`), HOST-RESOURCES-MIB (processor load, memory and disk),
ENTITY-SENSOR-MIB (temperature, voltage, current, power, fan speed and optical power, with scale and precision applied,
labelled by `entPhysicalName`) and UCD-SNMP-MIB (load, memory, CPU, for Linux-based devices such as EdgeOS and OS10).
Vendor packs add Cisco, Juniper, Dell OS9, Fortinet, Palo Alto and Ubiquiti EdgeSwitch; see their READMEs for what is
untested on real hardware. A request budget applies as it does for the tracker: the same rate limit, PDU budget and
read-only session.

**Status.** Each device shows the last metrics poll, its status, its error and the number of series on the Tracked
devices page and in `GET /api/tracker/devices` (`last_metrics_at`, `last_metrics_status`, `last_metrics_error`,
`last_metrics_series`, `metrics_failures`, `next_metrics_at`, and the effective `metrics_interval_seconds` and
`metric_collectors` of the entry). Prometheus: `seshat_tracker_metric_polls_total{result}` (ok, partial, error) and
`seshat_tracker_metric_series` on the server; an edge exports `seshat_edge_poll_metric_polls_total{result}`,
`seshat_edge_poll_metric_series` and `seshat_edge_poll_metric_samples_total`.

**Who polls.** The same poller that owns the device for tracking: the server, an edge, or a member of an edge group
(docs/edge.md, "Polling on the edge"). There is one metrics poller per device at any time; a metrics poll on a group
member stops, and sends nothing, when the group lease ends.

**A hand-over stops the old poller.** The server cancels a metrics (or tracker) poll it is running when the device is handed to
an edge, and the stream receiver drops SNMP metric samples from an edge that is not the device's poller (counting
`seshat_edge_metric_samples_not_owner_total`), allowing the hand-over grace for a poll that ran across it.

Not covered: a device that is not tracked (metrics ride on tracking), SNMP traps for the same events, and rates
(counters are raw; OTLP carries every value as a gauge, so take the rate downstream).

## Reachability

Seshat also tells whether a tracked device is **up**. Every enabled tracked device is probed at a short interval by
the poller that owns it, with two checks:

- **ICMP echo**: `SESHAT_TRACKER_REACH_COUNT` echo requests (default 3), one every 100 ms, and a wait of
  `SESHAT_TRACKER_REACH_TIMEOUT` (default 2 s) for the last reply. The result is up (any reply), the average
  round-trip time and the loss in percent. A reply counts when its identifier, sequence and random payload are ours,
  from whatever address it comes (a device with several addresses, or a router, may answer from another one).
- **SNMP up**: one `sysUpTime.0` GET with the device's own credential profile (the profile polling uses, through
  the same read-only session, target rules and per-device rate limit). It answers whether the device talks SNMP
  and gives its uptime, so an **uptime that goes backwards is a restart**.

**On by default**, with an interval of **60 s** and **3** failed probes in a row before a device is called down. The
settings are in the tracker settings (Tracked devices, *Settings and data*, *Reachability probes*; `GET`/`PUT
/api/tracker/settings`, section `reach`, audited as `tracker.settings.update`): on or off, the interval (10 s to
1 h), the failures before down (1 to 10), and an **override per site** of the three (the site is the device's
knowledge-base scope site, as for *Polled by*). The first start of a deployment seeds them from
`SESHAT_TRACKER_REACH_INTERVAL` and `SESHAT_TRACKER_REACH_DOWN_AFTER` (on, never off), and only when the stored
tracker settings were read successfully and hold no reach section: a failing read changes nothing and is tried again at
the next start. After that the stored settings are the truth. `SESHAT_TRACKER_REACH=0` is not a setting and is never
stored: it only turns the probes off on that instance whatever the settings say (the instance stops probing and stops
serving them to edges), and the other instances go on. `SESHAT_TRACKER_REACH_COUNT`, `_TIMEOUT` and `SESHAT_TRACKER_REACH_CHECKS` (`icmp`, `snmp` or `icmp,snmp`, the
default) stay the instance's. The settings reach the edges with the rest of their configuration, and a change is
applied at the edge's next sync. Probes are **spread** like the poll classes, by a stable offset per device inside the
interval, and are checked for being due every 5 s, so the effective interval is a multiple of 5 s.

A device is probed by one poller only, the one that owns it ([above](#polled-by-the-server-or-by-an-edge)): the
server, an edge, or the member of an edge group that holds it. A probe follows exactly the rules of a scheduled
poll: it is not made while another poller may still own the device (a hand-over settling), it is not made without a
valid lease, and a probe that is running when an edge group's lease ends is cancelled and reports nothing: nothing is
sent to the device once the right to probe it has ended, not an echo and not an SNMP request, even one that was
waiting for its slot in the device's rate limit ([edge.md](edge.md#reachability-probes)).

**State.** A device is `up` when any check answered and `down` when at least one check was made and none answered. A
check that could not be made (refused by a safety rule, ICMP unavailable, no SNMP credential, a local error) is no
evidence either way and changes nothing. An SNMP answer that carries no usable uptime (an error response,
noSuchObject, a rejected SNMPv3 user, a value of the wrong shape) means the device answered: it is alive, the
`snmp/up` sample is 0 and the state is not down. Only **silence** counts as a failure of the SNMP check. A refused connection (ICMP port unreachable: a host is there and nothing listens on the SNMP port) is an answer, so the device is alive; "no route to host" and "network unreachable" are silence. A wrong SNMPv2c
community is silence too, and cannot be told from a device that is down. A device is called down after
`down_after` probes in a row failed, up again at the first probe that is answered. A first probe that finds the device up
is a baseline and makes no event; one that finds it down makes `device-down` once the failures needed have been seen.

When **ICMP is unavailable** (or switched off) the verdict rests on SNMP alone: the device is down only after `down_after`
probes in a row met silence, and the event says `basis: snmp-only`, with the words "seen by SNMP only" in its message. A
wrong community, a firewall that drops SNMP from the poller, or an agent that is down all look the same then. A device that
answers ICMP while SNMP fails is up: its samples show `snmp/up` 0, and there is no event for that.

The state lives on the server, in the database, whichever poller probes: a restart, a failover of the server, and a
hand-over of the device from one poller to another all continue the same state, and do not make events of their own. A
state change is announced once: the node that sees it writes it to the row of the device with a compare-and-set on a
sequence number and emits the event only if that write wins, so two replicas that see the same change, or a restart that
sees it again, do not both announce it; when the write fails nothing is announced and the change is found again by the
next probe. A result that is not newer than the last from the same poller (or is older than the last from any) is dropped.
Seshat does not evaluate thresholds or run alerts: what to do about a state change is for the routes and the systems they feed.

**Samples**, one `seshat.metric` event per measurement of every probe, in the shape the
[metric destinations](outputs.md) read, so Prometheus remote write, InfluxDB and OTLP take them unchanged
(`seshat.metric.source` is `reach`; the destinations label a sample with the device's `host` and `site`):

| Path | Type | Meaning |
|---|---|---|
| `/reachability/icmp/up` | bool | any echo answered |
| `/reachability/icmp/rtt-ms` | double | average round trip of the answered echoes, only when up |
| `/reachability/icmp/loss-pct` | double | share of unanswered echoes |
| `/reachability/snmp/up` | bool | the sysUpTime read was answered with a value |
| `/reachability/snmp/uptime-s` | uint64 | the device's uptime in seconds, only when up |

A check that was not made produces no sample. At the default interval a device with both checks makes five samples
every 60 s; size the metric destinations for that times the number of tracked devices.

**Events**: one `seshat.reachability` event per change ([schema](schema/fields.md), example
[`reachability.json`](schema/examples/reachability.json)), on its own data stream, so a route can send them to
alerting and nothing else:

| `event.action` | When | Notable fields |
|---|---|---|
| `device-down` | the device went down | `basis`, `seshat.reachability.error` (which checks failed), `previous_state`, `since` (when it was last up), `loss_pct` |
| `device-up` | back up after an outage | `down_for_s`, `rtt_ms`, `uptime_s` |
| `device-restarted` | sysUpTime went backwards | `cause: uptime_went_backwards`, `uptime_s`, `previous_uptime_s` |

`device-restarted` means what the device said: its uptime went backwards, because the device **or its SNMP agent**
restarted; sysUpTime does not tell which. A device that comes back after a restart gives `device-up` and
`device-restarted`. sysUpTime is a 32-bit counter of hundredths of a second and wraps after 497 days; a drop from just
below the wrap to a small value is read as the counter wrapping, not as a restart. A route that sends the events
somewhere matches `dataset == "seshat.reachability"` (or `event.action`, `seshat.reachability.state`), for example
`dataset == "seshat.reachability" && event.action == "device-down" && role == "core"`.

**Probes off.** When the probes are switched off for a site, the state of its devices becomes `disabled` instead of keeping its last up or down on show; switching them on again starts from a new baseline.

**Capacity.** The two checks of a probe run at the same time, each in a pool of its own (ICMP 256 slots, SNMP at least 64,
more with more tracker workers), and a probe holds a slot only while its check is on the wire, so devices that do not answer
cost slots for their timeout and do not hold the healthy ones back. A pool of n slots serves devices of an interval i
whose checks take t at most about n·i/t at once; with 64 SNMP slots, 60 s and a 3 s timeout that is over a thousand
silent devices. A probe that starts more than a couple of ticks after it was due is an **overrun**: it is counted
(`seshat_tracker_reach_overruns_total`), the largest lateness of the last minutes is a gauge
(`seshat_tracker_reach_max_lag_seconds`), and the Tracked devices page says "probes are starting late" while it lasts.

**ICMP needs a socket the process may open.** Seshat tries an unprivileged ICMP datagram socket first (the kernel's
`net.ipv4.ping_group_range`, which must include the group the process runs as) and a raw socket second (`CAP_NET_RAW`),
for IPv4 and IPv6 separately (a host can have one family and not the other; the status shows both). If neither opens,
ICMP is **unavailable**, and says so plainly: the reachability lines of `GET /api/tracker/status` and the Tracked devices
page show `icmp unavailable: <reason>` **for each poller** (the server and every edge that has the problem, with the range the
host has), the SNMP check carries on, and a device is judged by SNMP alone, as above. The default container and systemd
settings of Seshat grant neither, and they are not changed; to turn ICMP on, choose one:

| Where | Setting |
|---|---|
| Docker Compose | add `sysctls: {net.ipv4.ping_group_range: "65532 65532"}` to the service ([`deploy/compose/reach-icmp.example.yaml`](../deploy/compose/reach-icmp.example.yaml)), or `cap_add: [NET_RAW]` |
| Kubernetes (Helm) | the chart value `tracker.pingGroupRange: "65532 65532"` (a pod sysctl, a safe one on current Kubernetes), or the `NET_RAW` capability |
| systemd (`seshat`, `seshat-edge`) | the host sysctl `net.ipv4.ping_group_range = <gid> <gid>` with the gid of the unit's group (`id -g seshat`), or the drop-in that grants `CAP_NET_RAW` ([packaging](packaging.md#capabilities)) |

The range names the service's own group only. A wide range such as `0 2147483647` is refused with `EINVAL` where the container
runs in a user namespace (rootless Docker, `userns-remap`), because the range may only name gids mapped there, and it grants the
socket to groups that have no use for it.

An echo goes only where an SNMP request may: never to loopback, link-local, multicast or unspecified addresses
(`never_poll`), and on an edge never outside the edge's own [ceiling](edge.md#the-edge-local-ceiling-for-snmp-reads) or
allow-list. A refused target is counted under its rule and its result says which.

**Where to see it.** The Tracked devices page shows each device's state, how long it has been in it, the last round-trip
time and loss, what each check said and the device's uptime; `GET /api/tracker/devices` carries the same as
`reachability` on each device and a `reachability` section (settings, devices per state, the ICMP problem of each
poller, the probers' counters), and `GET /api/tracker/status` the same section. On `/metrics`:
`seshat_tracker_reach_devices{state}`, `_events_total{action}`, `_results_total`, `_samples_total`,
`_stale_results_total`, `_transitions_lost_total`, `_save_errors_total`, and for the server's own prober `_probes_total{check,result}`,
`_refused_total{rule}`, `_probes_cancelled_total`, `_send_failures_total`, `_icmp_available`, `_running`,
`_overruns_total` and `_max_lag_seconds`.

## Event-driven sightings

A tap behind the enrichment stage sees every trap, syslog message and flow record after the device
knowledge base stamped it. It does a dataset check and puts the event on a bounded queue: it never
blocks the hot path, never modifies or copies the event, and drops (and counts, in
`seshat_tracker_sighting_dropped_total`) when the queue is full. A worker applies the pack
patterns.

| Source (`seshat.tracker.source`) | What it means | Typical confidence |
|---|---|---|
| `poll-fdb` | read from a switch's forwarding table | 0.8 |
| `poll-arp` | read from a router or L3 switch's ARP/ND table | 0.9 |
| `poll-wireless` | read from a wireless controller's client table | 0.9 |
| `poll-subscriber` | read from a CMTS or OLT subscriber table | 0.9 |
| `api` | read from a controller or cloud API (UniFi, Meraki, Mist) | 0.9 |
| `trap` | reported by the device itself, as a trap or its syslog twin: MAC notification, port security, 802.1X success, link up/down, association | 0.6 to 0.9 by rule |
| `dhcp` | a DHCP server handed out the lease (MAC, IP, hostname, option 82 circuit and remote id, fingerprint) | 0.9 |
| `radius` | RADIUS or 802.1X accounting named the user, the MAC, the port or the AP | 0.85 to 0.95 |
| `ad` | a domain controller logged the user on from an IP (4624 interactive, unlock, RDP, cached; 4768) | 0.6 to 0.7 |
| `flow` | a flow record shows the IP active; with a MAC, an L3 binding | 0.5 |
| `oui`, `fingerprint` | the vendor from the IEEE registry; the device type from a DHCP fingerprint | 1.0, 0.4 to 0.7 |

Rules that ship: ISC dhcpd, Kea, Windows DHCP audit lines, a site `log()` line for DHCP
fingerprints and option 82, FreeRADIUS-style attribute text for wired and wireless accounting,
Windows Security 4624 and 4768 text, flow records, IF-MIB link traps, and for Cisco the
CISCO-MAC-NOTIFICATION-MIB trap, the CISCO-PORT-SECURITY-MIB trap and the matching syslog messages,
`LINK-3-UPDOWN`, 802.1X and MAB success, Catalyst 9800 client run state and `DOT11-6-ASSOC`.
Every sample message in the tests and in `seshat-gen sightings` is synthetic.

Two things are worth knowing about the Cisco MAC-notification trap. Its history varbind packs
11-byte records (operation, VLAN, MAC, port); the port field is read as a BRIDGE-MIB bridge port
number and mapped to an ifIndex through the device's last poll, falling back to the field as an
ifIndex when the device has no such bridge port. That reading is covered by synthetic fixtures; check it
against a real device of yours before relying on it. And a trap from a device the knowledge base does
not know cannot be attributed to a port, so it is ignored.

Option 82: the DHCP circuit and remote id are kept on the L3 interval (`circuit_id`, `remote_id`)
and shown in the lookup. They are not turned into a switch port because their format is
site-specific; they become a **circuit location** instead (see [CPE and access networks](#cpe-and-access-networks)). To make ISC dhcpd log them, add a statement such as
`log(info, concat("circuit-id=", binary-to-ascii(16, 8, ":", option agent.circuit-id), " remote-id=", binary-to-ascii(16, 8, ":", option agent.remote-id)));`
to the log line, and for fingerprints
`log(info, concat("dhcp-fingerprint mac=", binary-to-ascii(16, 8, ":", substring(hardware, 1, 6)), " opt55=", binary-to-ascii(10, 8, ",", option dhcp-parameter-request-list), " vendor-class=\"", option vendor-class-identifier, "\""));`.
Those two lines are examples for the patterns that ship; adapt them to your server and check the
output before relying on it.

## Wireless sources

Wireless clients come from four places, all stored as `tracker_wireless` intervals (AP, SSID, band,
channel, signal, VLAN, from/to) plus an L3 binding for the client address and identity hints (the user
name, and a host name when the controller knows one):

| Source | How | Pack |
|---|---|---|
| Cisco AireOS controller | SNMP, `bsnMobileStationTable` (user, VLAN, protocol), `bsnMobileStationStatsTable` (signal), `bsnAPTable` and `bsnAPIfTable` (AP name, channel) | `cisco/cisco-aireos-clients` |
| Cisco Catalyst 9800 | SNMP, `cldcClientTable` (CISCO-LWAPP-DOT11-CLIENT-MIB) with AP names from `cLApTable`; the table has no per-client signal | `cisco/cisco-c9800-clients` |
| Aruba controller | SNMP, `wlsxWlanStationTable` (BSSID, channel, VLAN, signal), mapped to the AP through `wlsxWlanAPBssidTable` and `wlsxWlanAPTable` | `hpe-aruba/aruba-wlan-stations` |
| Ruckus ZoneDirector / Unleashed | SNMP, `ruckusZDWLANStaTable` | `ruckus/ruckus-zd-stations` |
| UniFi, Meraki, Juniper Mist | controller or cloud HTTP API ([below](#cloud-and-controller-apis)) | `ubiquiti`, `cisco`, `juniper` |
| RADIUS accounting, controller syslog | [event-driven sightings](#event-driven-sightings) | `standard`, `cisco` |

All SNMP collectors are marked `experimental` in the pack and in the poll report: the table and column
numbers were read from the public MIB modules (see each pack's `mibs/SOURCES.md`) and the collectors are
tested against synthetic agents (`seshat-gen snmp-agent --profile wlc`), not against production
controllers. **Ruckus SmartZone** has no station table in its SNMP MIB (only an AP table), so it cannot be
followed by SNMP; use a controller API source for it when a profile exists. Controllers are bound by
classification: `os aireos`; `os ios-xe` with role `wireless-controller` (Catalyst 9800); vendor Aruba with
`os arubaos`; vendor Ruckus with product ZoneDirector. Set these on the device when the banner rule misses.

Access points are located by the switch port they are plugged into, like any device. The LLDP/CDP uplink
rule excludes the MACs learned behind an inter-switch port, and a port whose neighbour advertises
`wlan-access-point` is one of those ports (the stations bridged behind the AP are wireless, not wired, and
must not be located there). The AP's own address is the exception: when the neighbour's LLDP chassis id is
a MAC and that MAC is learned on the port, it is located on the port like any endpoint.

### Cloud and controller APIs

An **API source** reads the client list of a controller or cloud account over HTTPS and stores it with
`source` = `api`. The mapping from the JSON response to the wireless fields is pack data
(`api_collectors:` in the pack): path to the array, query, paging, rate limit,
authentication header, and a field map. Three profiles ship, all `experimental`, written from public API
descriptions and tested only against synthetic responses:

| Profile | Endpoint | Authentication | Paging |
|---|---|---|---|
| `ubiquiti/unifi-network-clients` | `<base>/proxy/network/api/s/<site>/stat/sta` (empty prefix on a standalone Network application) | API key in `X-API-KEY` | none |
| `cisco/meraki-network-clients` | `https://api.meraki.com/api/v1/networks/<network_id>/clients` | `Authorization: Bearer <key>` | `Link: rel=next` (same host only) |
| `juniper/mist-site-clients` | `https://api.mist.com/api/v1/sites/<site_id>/stats/clients` | `Authorization: Token <token>` | `page` and `limit` until a short page |

Configure a source with the API (admin or operator; there is no UI page yet):

```sh
curl -X PUT .../api/tracker/api-sources/branch-unifi -d '{
  "profile": "ubiquiti/unifi-network-clients", "base_url": "https://unifi.example.com",
  "params": {"site": "default"}, "secret": "<api key>", "site": "example-site-a",
  "interval_seconds": 300, "enabled": true }'
curl -X POST .../api/tracker/api-sources/branch-unifi/poll     # read now; returns the status
curl .../api/tracker/api-profiles                             # shipped profiles and their parameters
```

The credential is sealed with the secret key and never returned (`secret_set` says whether one is stored). Leaving `secret`
out of an update keeps it, with these exceptions: `"clear_secret": true` removes it, and an update that **re-points the source**
(another `profile`, another base URL scheme, host or port, or another `username`) drops it unless the same request supplies a new
`secret`, so a credential can never be sent to a destination chosen by someone who cannot read it. A source without a credential
saves (`secret_set` is false) but does not poll and sends nothing. Requests are GET only, to the base URL
you configured; a redirect or a paging link to another host is not followed, so the credential cannot leave
for another host.

The base URL is checked when it is saved and again when the connection is made (so a name that later resolves elsewhere is
refused too): loopback, link-local (169.254.0.0/16, fe80::/10), the unspecified address and cloud metadata addresses are
refused with an error that names `SESHAT_ALLOW_LOCAL_TARGETS`. Private (RFC 1918) addresses stay allowed. An administrator who
really polls a controller on the same host sets `SESHAT_ALLOW_LOCAL_TARGETS=1`. A self-signed controller certificate needs `"insecure_skip_verify": true`, which logs
nothing and is for evaluation only. Failures (rejected credential, HTTP 429, a response that is not the
expected array) are shown in the source's status and never stop the other sources.

## CPE and access networks

Subscribers behind a cable plant, a PON or a BNG have no switch port. Their location is a **circuit**:
`location.kind` = `circuit`, shown as **"Circuit <id> on <relay>"** with the usual age and source. A circuit
is stored in `tracker_location` (`kind` = `circuit`, with `circuit_id`, `remote_id`, `circuit_kind`) and the
modem or session address in `tracker_l3`. A MAC can have a wired and a circuit location at once (a host
behind an option 82 relay switch): the lookup leads with the switch port and still shows the circuit, with
its own age and source, in `location.circuit`.

| Source | What becomes a circuit | Pack / rule |
|---|---|---|
| DOCSIS CMTS | each registered cable modem (`docsIfCmtsCmStatusTable`): circuit `cm<index>`, the upstream channel interface as the port, the modem's management IP | `cablelabs/docsis-cmts-modems`, bound to role `cmts` |
| Huawei GPON OLT | each ONT with a management MAC (`HUAWEI-XPON-MIB`): circuit `ont<pon ifindex>-<ont id>`, serial number, PON port | `huawei-pon/huawei-gpon-onts`, bound to vendor Huawei with role `olt` |
| PPPoE through RADIUS accounting | the session: circuit = `Agent-Circuit-Id` (also `ADSL-Agent-Circuit-Id`), else `NAS-Port-Id`; the `Acct-Session-Id` is kept in the trace; `Framed-IP-Address` becomes the L3 binding and `User-Name` the user | sighting `radius-acct-pppoe` (standard) |
| DHCP option 82 | `circuit-id` / `remote-id` behind the relay (`via <address>`): circuit on the relay device, or on `relay:<address>` when the relay is not in the knowledge base | sighting `isc-dhcpd-ack` (standard) |

ONTs that report no management MAC cannot be keyed (the tracker is keyed on MACs) and are only counted in
the poll report (`skipped.unkeyed_subscribers`). **ZTE ZXAN** ONU tables are not implemented: no public
module text was available to check the numbers against, and the loader will not take an OID on faith. The
`subscriber` fact is the extension point if you have the module. CMTS and OLT devices are classified by
banner rules that are weak evidence; set the role (`cmts`, `olt`) on the device.

## Inventory trace

When a location resolves to a switch port, the lookup asks the inventory for the **cable trace** of that
interface and adds the far side to `location.trace[]`: interface to front port to rear port to patch panel
and so on, to the far-end interface or circuit, each hop with the device it is on and that device's room
and rack. The UI draws the chain as breadcrumbs. Details:

- NetBox only (the enabled `netbox` connector): the interface is found by device name and interface name
  (`/api/dcim/interfaces/?device=<name>&name=<ifName>`), then `/api/dcim/interfaces/{id}/trace/`; the
  device of each far-end termination is read once per trace for its role (a role containing "patch"
  turns `front_port` / `rear_port` hops into `patch_panel`), location and rack. The device names in the
  knowledge base must match NetBox's.
- **Nautobot: not implemented** (it has no equivalent trace endpoint); the lookup behaves as if the
  inventory had no trace.
- The result is cached per device and interface for `trace_ttl_minutes` (default 30, a tracker
  setting). An uncabled interface, an unknown interface and an inventory failure are cached for a minute,
  so a slow or broken NetBox costs at most one 4-second attempt a minute per port and the lookup still
  answers with the port description. It is read-only: only GETs are sent.
- Hops are hidden from the `user` role with the rest of the trace (`location.trace` redaction). The trace
  is looked up on Seshat; the portal's push and database modes carry only the stored port description.

## The interval model, freshness and history

Facts are stored as **intervals**: "this MAC was on this switch port in this VLAN from A to B".

- **Extend**: seeing the same fact again extends it (`last_confirmed`), whatever the source.
  Repeating an observation changes nothing else, so a replayed poll or a duplicate trap is harmless.
- **Close**: a different fact for the same entity closes the old interval at the new observation's
  time and opens another (a move). An observation older than what is already known elsewhere is
  stale evidence and is ignored. A `linkDown` closes every interval on that port. An IP seen on
  another MAC closes the first holder's interval; a DHCP acknowledgement for a new address ends the
  MAC's other addresses of that family.
- **Tolerance**: an entity that reappears at the place its interval closed within the tolerance
  window (default 10 minutes, a setting) continues that interval instead of opening a new one. A
  link flap or one poll that missed an FDB entry therefore leaves no hole in the history.
- **Expiry**: an interval nothing has confirmed for 7 days (a setting) is closed at its last
  confirmation. A DHCP lease that ended with no later confirmation closes at the lease end.
  Nothing is closed just because a poll did not see the entry: a laptop asleep for an hour still
  has its last known location, marked stale.

Every fact in a lookup carries the **provenance set**: `observed_at` (the last confirmation, not
when it was stored), `age_seconds` (computed by the server, so a client needs no synchronised
clock), `source`, `confidence` and `stale`. A fact is `stale` when its age exceeds
`stale_after_seconds` (default 30 minutes, a setting; the response states the value it used). The UI
shows "40 s ago via trap" and marks stale facts in words and with an icon. A client must never present
a stale fact as current. `data_as_of` is the newest observation in the store.

An IP or a user can match several devices, so a lookup returns one result per MAC, newest first.
No match is `200` with an empty list.

## Identity

- **Vendor**: the IEEE registry (MA-L, MA-M and MA-S, about 54,000 prefixes) is embedded. Refresh
  it with `make oui` at build time (offline: download `oui.csv`, `mam.csv`, `oui36.csv` from the
  IEEE and run `make oui OUI_DIR=<dir>`), or at run time with **Refresh OUI registry** or
  `POST /api/tracker/oui/refresh` (the only outbound request of the tracker), or upload a file with
  `POST /api/tracker/oui` (an IEEE CSV or the compact form). Settings can enable an automatic refresh
  every 30 days; it is off by default. A refreshed or uploaded registry is kept in the data
  directory and survives a restart.
- **Randomised MAC**: the locally-administered bit (`0x02` of the first octet) marks a privacy
  address. Those have no registered vendor and are shown as "Randomized MAC".
- **Device type**: from a DHCP fingerprint (option 55 request list, option 60 vendor class) through
  a built-in table. The table is small and coarse on purpose, built from widely
  published request-list patterns, with confidence capped at 0.7: it names an OS family, not a model.
  Extend it by adding rows and rebuilding.
- **Hostname** from DHCP, **user** from RADIUS or AD, as the sightings report them; the newest wins.

## Watch lists and approved devices

A **watch list** entry (MAC, IP or prefix such as `198.51.100.0/24`, user, hostname, vendor prefix or
vendor name) fires when a matching device appears or moves. It publishes a `seshat.tracker` event
with `event.action` `watch.hit` and `seshat.tracker.watch.{id,kind,value,label,reason}`, reason
`appeared` (a MAC never seen before), `moved` (a new location) or `seen`. The same entry stays quiet
for the same MAC and reason for 10 minutes. Route those events to a destination to be told; see
[`outputs.md`](outputs.md).

The **approved list** (MACs and vendor prefixes) is the set of devices you expect. Once it has an
entry, every other MAC that appears for the first time publishes `unknown.appeared`. An empty list
raises nothing unless "enforce approved" is set in the settings.

Other events: `interval-opened` and `interval-closed` always; `interval-extended` only if the
setting is on (high volume). The fields are in [`schema/fields.md`](schema/fields.md).

## Infrastructure roles

A device's **role** in the device record decides two things: which tracker binding (which collectors) it
gets, and whether it counts as infrastructure (a switch, router, firewall, controller or access point the
tracker already knows), so that a port whose neighbour is infrastructure is flagged as an uplink and
its MACs are not reported as end devices. Both use the same matching.

**Matching is by word.** The role is lower-cased, runs of white space are collapsed and the ends trimmed
(so "Backbone  Switch" is "backbone switch" when compared whole), and it is split into words on space,
`-`, `_`, `/`, `,`, `(`, `)`, `.` and `:`. It stands for a **role class** for each of these words:
`switch`, `router`, `firewall`, `ap`, `core`, `distribution`, and the two-word names `wireless controller`
(class `wireless-controller`) and `access point` (class `access-point`). "Backbone Switch" is `switch`;
"core-router" is `core` and `router`; "Edge_Firewall" is `firewall`; "Switch (Core), Stack" is `switch` and `core`;
"Switchboard" and "Storage Controller" are nothing (a word is matched whole).

**Bindings.** A pack binding with `applies_to: { role: X }` (packs.md)
applies to a device whose role equals `X` (as before) **or** has `X` among its classes. So the shipped
`role: switch` bindings cover "Backbone Switch". When more than one binding matches, the choice is always
the same for the same packs, in this order:

1. the higher binding `priority`;
2. at equal priority, the stronger class, in this fixed **class precedence**:
   a value equal to the whole role, then `switch`, `wireless-controller`, `firewall`, `router`, `access-point`, `ap`, `core`,
   `distribution`, then a class an include entry took from a pack (`olt`, `cmts`, ...), then a binding that names no role;
3. the lower binding id.

So an L3 "Switch/Router" gets the switch binding (and its bridge-table collectors), a "Firewall Router" the firewall
binding, a "Core Router" the router binding. The order of the words in the role never matters.

**Settings** (Tracked devices, *Settings and data*, *Infrastructure roles*; `GET/PUT /api/tracker/settings`,
fields `infra_roles_include` and `infra_roles_exclude`, both empty by default; operators and administrators change
them, every change is in the audit log as `tracker.settings.update` with the lists):

- `infra_roles_include`: entries `{"pattern": "Spine*", "as": "switch"}`. A device whose role matches the pattern also has
  the class `as`, so "Spine" takes the bindings of a switch and counts as infrastructure. `as` must be a class the
  system knows: one of the classes above, or a role value that a loaded pack binding uses (`olt`, `cmts`, ...); anything
  else is refused with `400` and the list of valid classes. Several entries may name one role: it then has all their classes.
- `infra_roles_exclude`: roles that are never infrastructure, such as `lab`. **Exclude wins over everything, and it
  also blocks exact equality**: an excluded role has no class and matches no binding's `role` value at all, not even a
  binding that names exactly that role. It does **not** affect bindings that name no role (a binding with only
  `vendor`, `os` or `model` still applies to the device).

A pattern matches the whole role or any one word of it; `*` stands for any run of characters (`wlc*`, `*gateway*`).
Blank lines and repeats are dropped; a pattern may be at most 64 characters (counted as characters, not bytes), a list
holds at most 100 entries, a pattern that is only `*` is refused, and control characters and invisible formatting
characters (zero-width, right-to-left overrides) are refused (400). The lists take effect at once, without a restart.

> **Warning: the generic words also catch roles that are not network devices.** `core`, `distribution`, `ap` and
> `firewall` (and `switch`, `router`) are matched anywhere in a role, so "Core Banking Server", "Distribution Warehouse"
> or "Ap Payments Database" count as infrastructure and bind a pack. Add such roles to `infra_roles_exclude`
> (`*banking*`, `distribution warehouse`, ...); it is the fix. Look at *Role* on the Tracked devices page and in the
> device detail to see how a role is read.

**Changing the lists can unbind devices.** A device that is enabled and loses its binding (an exclude entry, or a
removed mapping) stops being polled. `PUT /api/tracker/settings` answers with `unbound_enabled_devices`, the number of
enabled devices that had a binding before the change and have none after it, and the page shows a warning with the count.
The device's poll report then says why: `role "Lab Switch" is excluded by the tracker setting infra_roles_exclude`,
and switching such a device on is refused with the same words.

The server sends both lists to every edge that polls devices, with the devices (the edge's configuration etag covers
them), so an edge picks the same binding as the server; an older edge ignores them and keeps the default word matching.

**Seeing why.** `GET /api/tracker/devices` and the Tracked devices page show, for each device, `role_match`: `word` (the role
holds one of the words above), `setting` (only an include entry names it) or `none` (nothing matches, or the exclude list
names it), and `role_class`, the class it matched as (the class of the binding the device got, else its strongest class).
A device with no binding and no tracker settings is not on that page; `GET /api/devices/{id}` (and the device detail
sheet under Devices) carries `role_match`, `role_class` and `tracker_binding` for every device, so you can see why "Spine"
was not picked up.

## Roles and the API

| Endpoint | user | viewer | operator, admin |
|---|---|---|---|
| `GET /api/tracker/lookup?q=` | yes | yes | yes |
| `GET /api/tracker/export.csv?q=` | yes (its own query) | yes | yes |
| `POST /api/tracker/lookup/batch`, `GET /api/tracker/bindings` ([bulk reads](#bulk-reads-for-integrations)) | 403 | yes | yes |
| every other `GET` under `/api/tracker/` (status, settings, devices, ports, port history, sources, lists, OUI) | 403 | yes | yes |
| every `PUT`, `POST`, `PATCH` and `DELETE` under `/api/tracker/` (including poll-now and the polled-by settings) | 403 | 403 | yes |

`PUT /api/tracker/settings` (including the [infrastructure role lists](#infrastructure-roles)) is in the last row: operator and admin only, audited.

A `user` or `viewer` gets `403 forbidden` where the table says so, never an empty list. Every lookup, export and port history is written
to the audit log (who, what, when). Settings can hide facts from the `user` role (user name,
hostname, inventory trace, user history, IP history); the hidden paths are listed in the response's
`redactions` so the UI can say "hidden by policy". CSV cells that start with `=`, `+`, `-` or `@` are
prefixed with a quote so a spreadsheet does not run them.

The endpoints are in `GET /api/openapi.json`. Operator and admin pages: **Device Tracker** in the
navigation (Lookup, Tracked devices, Port history, Watch lists, Approved devices).

## Reading the data from PostgreSQL

On PostgreSQL the schema `tracker_public` holds only views over the tracker tables
(`devices`, `sightings_current`, `intervals_location`, `intervals_l3`, `intervals_wireless`,
`intervals_user`; comment `seshat-tracker-contract 1`), created at start. Where the database user may
create roles, `tracker_portal_ro` (NOLOGIN, `USAGE` and `SELECT` on that schema only) is created
too; otherwise create it yourself with the statements in [`schema/tracker.md`](schema/tracker.md). On
SQLite, which has no schemas, the same views exist as `tracker_public_<view>`.

## The read-only guarantee

- A collector can only express SNMP GET, GETNEXT and GETBULK on the OIDs it names; the pack loader
  rejects any key it does not know, so a pack cannot carry a command, a SET or a port action.
- The poller's `Session` interface has Get, GetNext and GetBulk and nothing else. A test scans the
  poll package, and the credential helper it uses, for any SNMP write call and fails the build if one
  appears. The synthetic agent answers read PDUs only.
- Credentials are the read-only SNMP polling profiles of Settings (`/api/connectors/snmp`): a v2c
  community or a v3 user. Use read-only credentials. Polling is enabled per KB device by an
  operator; Seshat never polls an unknown device. Each profile only ever polls its allowed networks
  (when none are listed, any device an operator enabled for tracking; never an address known only from
  traffic) and never loopback, link-local or multicast addresses ([details](device-kb.md#where-polling-is-allowed-to-go)).
- The [reachability probe](#reachability) is one SNMP GET of `sysUpTime.0` through the same `Session` and an ICMP echo
  request; it sends nothing else to a device.
- The [pollers on an edge](edge.md#polling-on-the-edge) are these same pollers: the same `Session`, the same source
  scan, and the same never-poll, allowed-networks, allow-list and ceiling checks, made on the edge before a datagram leaves.
- The on-demand [SNMP reads through an edge](edge.md#snmp-reads) run on the same read-only `Session` and the same
  credential helper, take the same never-poll and allowed-networks checks on the edge, and are covered by the same
  source scan (it reads their package too).
- CLI collectors are not implemented: where SNMP is not enough (for example some NX-OS tables), the
  binding says so and that data is simply not collected.
- **What the guarantee covers.** It is about what Seshat itself sends to network devices: its collectors, its
  poller and its API. It does not cover a session a client runs through an edge's
  [TCP relay](edge.md#relay). That is a separate capability, off on every edge until an administrator turns
  it on and lists the hosts it may reach. Seshat carries the client's bytes and originates no protocol
  traffic through it, so it cannot see or restrict what such a session does; a `read` intent that the client
  declares is recorded and checked against the edge's mode, not enforced inside the stream. An edge whose
  relay is off or in mode `read` refuses sessions that declare write intent.


## Limits

- Sightings taken from syslog, trap and flow events are bounded per sending address, because any host
  that can reach a listener can send a "DHCPACK"-style line: `SESHAT_TRACKER_SIGHTING_RATE`
  observations per second (default 1000, burst `SESHAT_TRACKER_SIGHTING_BURST`, default 5000) and
  `SESHAT_TRACKER_SIGHTING_MACS_PER_HOUR` distinct new MAC addresses per hour (default 50 000). Over a
  bound the observation is dropped and counted (`seshat_tracker_sightings_limited_total{reason}`,
  `rate` or `new_macs`); a renewal of a MAC the sender already introduced is never counted as new.
  Free-text fields (hostname, user, SSID, circuit ids) are clipped to 253 bytes. Identity rows with no
  remaining intervals and not seen for `tracker_interval_days` are removed by the retention job.
- The inventory trace is the port's `ifAlias` plus, with a NetBox connector, the cable trace
  ([above](#inventory-trace)); Nautobot has no trace.
- Wireless location comes from controller client tables (Cisco AireOS and 9800, Aruba, Ruckus
  ZoneDirector), the UniFi, Meraki and Mist APIs and association logs. Ruckus SmartZone has neither a
  station table nor an API profile. All of these collectors and profiles are experimental.
- There is no UI page for API sources yet (use the API), and the portal in push or database mode
  does not receive the NetBox cable trace or the circuit shown beside a wired location.
- Flow sightings are implemented and tested against synthetic flow events, and stay inert until a
  flow input produces `seshat.flow` events; enable them in the settings.
- In a multi-replica deployment pollers are spread only by the static `SESHAT_TRACKER_SHARD`
  setting; there is no automatic rebalancing. Devices an edge owns are left out of every shard.
- The Device Tracker portal ([`device-tracker-portal.md`](device-tracker-portal.md)) reads the tracker's
  tables and views in every data mode and receives pushed data into the same interval tables, so
  there is one set of tables and one set of `tracker_public` views. Its change feed
  (`tracker.Service.Stored`) wakes the push-sync publishers; with no portal configured it costs nothing.

## Scope on the lookup and the device routes

`GET /api/tracker/lookup`, the batch lookup, the prefix bindings, the CSV export, the device list, a device's ports, a port's history and poll-now all
answer only what the caller's scope allows, by the same test (a device is in scope when its site or its tenant is
listed). A device outside the scope answers `404 not_found`, the same as an id that does not exist, so a scoped
token cannot tell other sites' devices from missing ones; the device list leaves them out, and for a scoped caller
it does not list the SNMP credential profile names either. `PUT /api/tracker/devices/{id}` follows the same rule.
Routes that are not about one device (status, settings, watch and approved lists, API sources, OUI registry) and
the device inventory (`/api/devices*`) are not filtered: they stay operator-only (see
[`security.md`](security.md#api-tokens) for what a scoped operator token can still read and do). API tokens
and every account with the `user` role, local or SSO, are limited to their own site/tenant scope, and
an account with no scope sees nothing (a local `user` has no scope, so it sees nothing: use SSO groups
or a scoped token); administrators, operators and viewers see everything. The portal in `api` mode adds the signed-in user's scope
as repeated `site=` and `tenant=` parameters, and both scopes must allow a fact (a fact is visible when
its site or its tenant is listed). A device none of whose facts is visible is left out of the answer.
The response carries sites but not tenants, so a client cannot re-check a tenant scope itself; it
relies on this filtering.

A scope that admits every site and tenant (`*`) restricts nothing: such a token behaves like an operator session
(it also reads the ports and history of a device that has left the inventory, and gets the profile names).

Because the scope is the lookup's, **an API token with no scope sees nothing** on the device routes too, whatever
its role (the token list marks an unscoped `tracker:read` token with a warning). Give a token the sites and tenants
it needs, or `*` for all.

### Bulk reads for integrations

An integration that checks many devices at once (a DHCP manager comparing leases with what the network sees, a change tool
verifying a cutover) should not loop over the single lookup. Two calls serve it, both inside the caller's site/tenant scope and
both in the contract of [`schema/tracker.md`](schema/tracker.md) (field-level detail and examples there):

- `POST /api/tracker/lookup/batch` with `{"queries": [...]}` (up to 500 MACs, IPs, hostnames or users) returns one
  single-lookup answer per query, unchanged, in request order. A query with nothing visible to the caller is counted in
  `warnings`. One audit event (`tracker.lookup.batch`) records the count and a SHA-256 of the sorted queries, not the queries.
- `GET /api/tracker/bindings?site=<site>&prefix=<cidr>` returns the current ARP / ND / DHCP bindings of one site inside an
  IPv4 or IPv6 prefix, paged with an opaque cursor (default 500 rows, at most 5000; a short page with a cursor means "continue", only a null
  cursor is the end). The site must be inside the caller's scope (`403 out_of_scope`, also audited, as `denied`). One audit
  event (`tracker.bindings`) per page. A batch is bounded too: history per item is the `history_limit` setting, at most
  2000 devices in all, body up to 256 KiB.

Both are open to admin, operator, viewer, `tracker:read` tokens and integration clients holding `tracker.bulk` (rate limited per call: a batch is one admit), and closed to the `user` role: they return many devices
per call, which the lookup page never needs. The DHCP sighting fields (`lease_expires`, `circuit_id`, `remote_id`,
`relay_agent`, `location.circuit`) are part of the answer. The audit action filter on the Audit page is exact, so enter
`tracker.lookup.batch` or `tracker.bindings` to see these events.

### Read-only integration tokens (`tracker:read`)

> New integrations should be registered as an **integration client** holding the capabilities `tracker.read` (and
> `tracker.poll` for poll-now, `tracker.bulk` for the batch lookup and prefix bindings): see [`integrations/README.md`](integrations/README.md). A `tracker:read` token is
> exactly a client with `tracker.read`, `tracker.poll` and `tracker.bulk` and keeps working unchanged; what follows describes it.

An integration that only needs to read the tracker (for example a change-planning tool that checks switches before a
cutover) should not hold an operator token, which can also change device settings, watch lists and approved lists.
Create a token with the role **`tracker:read`** (Settings, API tokens, or `POST /api/tokens` as an administrator):

```json
{"name": "cutover-check", "role": "tracker:read", "scope": {"sites": ["site-a"]}, "expires_in_days": 90}
```

It opens exactly these routes, within its site/tenant scope:

| Route | |
|---|---|
| `GET /api/tracker/lookup`, `GET /api/tracker/export.csv` | lookup and CSV export |
| `POST /api/tracker/lookup/batch`, `GET /api/tracker/bindings` | batch lookup and prefix bindings ([bulk reads](#bulk-reads-for-integrations)) |
| `GET /api/tracker/devices` | the device list |
| `GET /api/tracker/devices/{id}/ports` | a device's ports from the last full poll |
| `GET /api/tracker/ports/{device}/{ifindex}/history` | who has been on a port |
| `POST /api/tracker/devices/{id}/poll` | poll now: a read-only SNMP poll (no SET, no change on the device); for a device an edge owns, done by the edge, with the same answer plus `owner` and `results_stored` |

Every other route answers **403 `forbidden`** (never an empty list), including `PUT /api/tracker/devices/{id}`,
settings, watch and approved lists, the account routes, `/metrics` and the OpenAPI document.
Poll-now goes through the scheduler the UI's "Poll now" button uses: one poll of a device at a time (a second
request while one runs gets a report saying so), the shared limit on concurrent polls, and the polling target
policy and credential profiles of the site. For API tokens (this role and any other) it is limited further: a
device an operator switched off is refused with `409 device_disabled`, and one device is polled at most once every
60 seconds per Seshat instance, otherwise `429 rate_limited` with a `Retry-After` header. A signed-in session (the
UI button) is not subject to either rule. Every call is audited as `token:<name>`. `tracker:read` is a token role
only; an account cannot hold it. Data is not redacted for it (the `user` role's redactions do not apply), so scope
it as you would an operator token.

