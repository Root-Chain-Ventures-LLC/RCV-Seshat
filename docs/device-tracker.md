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

Limits per device: `SESHAT_TRACKER_RATE` requests per second (default 50), a PDU budget per
collector, a 5 minute timeout per collector, `SESHAT_TRACKER_WORKERS` device polls at a time
(default 4). `SESHAT_TRACKER_POLL=0` turns the pollers off on an instance. To spread polling over
replicas, give each one `SESHAT_TRACKER_SHARD=i/n`: a device is polled by the instance whose index
equals the hash of the device id modulo n.

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

## Roles and the API

| Endpoint | user | operator, admin |
|---|---|---|
| `GET /api/tracker/lookup?q=` | yes | yes |
| `GET /api/tracker/export.csv?q=` | yes (its own query) | yes |
| everything else under `/api/tracker/` | 403 | yes |

A `user` gets `403 forbidden`, never an empty list. Every lookup, export and port history is written
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
- CLI collectors are not implemented: where SNMP is not enough (for example some NX-OS tables), the
  binding says so and that data is simply not collected.


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
  setting; there is no automatic rebalancing.
- The Device Tracker portal ([`device-tracker-portal.md`](device-tracker-portal.md)) reads the tracker's
  tables and views in every data mode and receives pushed data into the same interval tables, so
  there is one set of tables and one set of `tracker_public` views. Its change feed
  (`tracker.Service.Stored`) wakes the push-sync publishers; with no portal configured it costs nothing.

## Scope on the lookup

`GET /api/tracker/lookup` and the CSV export answer only what the caller's scope allows. API tokens
and every account with the `user` role, local or SSO, are limited to their own site/tenant scope, and
an account with no scope sees nothing (a local `user` has no scope, so it sees nothing: use SSO groups
or a scoped token); administrators and operators see everything. The portal in `api` mode adds the signed-in user's scope
as repeated `site=` and `tenant=` parameters, and both scopes must allow a fact (a fact is visible when
its site or its tenant is listed). A device none of whose facts is visible is left out of the answer.
The response carries sites but not tenants, so a client cannot re-check a tenant scope itself; it
relies on this filtering.
