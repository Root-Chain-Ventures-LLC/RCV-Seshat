# Device knowledge base

Seshat keeps one record per device in memory and uses it to stamp every event with who sent it:
name, vendor, model, site, role, tenant, tags and, for traps, the interface name behind an
`ifIndex`. This page is the operator's view. The
fields it fills are in `docs/schema/fields.md` (`seshat.device.*`, `seshat.enrichment.*`).

The one rule: **events never wait for the knowledge base to learn**. A sender Seshat has never
seen is forwarded at once as `unknown`; the lookup, DNS query or inventory call that might make
it known happens in the background, and the next event benefits.

## How a device becomes known

A record is **known** when at least one fact came from an inventory connector or from an operator
(adopt, CSV import). Everything else is **unknown**, however much Seshat has worked out about it.

| Way in | Source recorded | Confidence | Makes it known? |
|---|---|---|---|
| Operator adopts it, or imports a CSV in the UI | `manual` | 1.00 | yes |
| NetBox, Nautobot, CSV file, HTTP connector (lookup, seed, webhook) | `inventory` | 0.95 | yes |
| Opt-in SNMP poll (sysDescr, sysObjectID, sysName, ifTable) | `snmp` | 0.80 | no |
| Vendor pack signature (vendor and pack hints from the input) | `pack` | 0.70 | no |
| Seen in traffic (sysName from a trap, SNMPv3 engine ID, syslog hostname) | `learned` | 0.60 | no |
| Reverse DNS | `dns` | 0.50 | no |

Per field, a source only replaces a value if it is at least as confident as the one recorded, so
an operator's entry beats the inventory, which beats a guess. Every field remembers its source,
when it was observed and its confidence; the device drawer in the UI shows them, and the
`seshat.device` index carries them as `seshat.device.provenance`.

`seshat.enrichment.level` says how much the knowledge base contributed: `full` (known),
`partial` (unknown, but some facts learned) or `none`.

## Unknown, stale, and what the hot path does

* **Unknown.** The first event from an unseen (site, VRF, address) creates a small *stub* record
  and queues a learning job. Stubs are capped (`SESHAT_KB_UNKNOWN_CAP`, default 50,000; the least
  recently seen is evicted first) and expire if the sender is not heard from again
  (`SESHAT_KB_UNKNOWN_TTL`, default 24 h). Creating stubs is rate limited per site and VRF
  (`SESHAT_KB_CREATE_RATE`, default 200 per second, burst 1000), so a flood of spoofed UDP from
  random addresses cannot churn the table; while the limit is hit the events still flow, as
  `unknown` with no stub behind them. Known and ignored devices never count against the cap or
  expire.
* **Stale.** Known facts carry a refresh time (`SESHAT_KB_REFRESH`, default 24 h). Past it the
  record is *stale*: it is still used for enrichment (`seshat.device.status: stale`, level
  unchanged) while a refresh runs in the background. Nothing stops working because an inventory
  is slow.
* **Unknown senders are retried** about hourly, so a device added to the inventory later turns
  known without anyone touching Seshat. An inventory webhook (below) makes it immediate.
* **Scope.** A device is identified by *(site, VRF, address)*, so `192.0.2.1` at two sites is two
  devices. The site and VRF come from the listener: set them under Inputs, SNMP, Site and VRF
  (`seshat.source.site`, `seshat.source.vrf`). Untagged listeners use the site `default`.
  Behind NAT, a trap's SNMPv3 engine ID, once learned or inventoried, identifies the device even
  when the address does not.

The per-lookup cost is a few hundred nanoseconds with no locks and no allocation: the index is
sharded copy-on-write, readers do one atomic load. Measured with 10,000 devices: 166 ns per lookup on one thread, 63 ns
aggregate across 16 threads, 0 allocations.

## Connectors

Settings, Connectors (admin). Every form has **Test** (checks the unsaved values) and, where the
source can list its devices, **Seed now**. Secrets (tokens, webhook secrets, auth header values)
are sealed with `SESHAT_SECRET_KEY`, never shown again, and a blank field on save keeps the stored
one. To remove one, press **Clear** next to the field (API: `clear_token`, `clear_webhook_secret`,
`clear_auth_value` set to `true`, or the secret itself as `null`); the *set* flags in the view
always reflect what is stored. Order of asking: NetBox, Nautobot, CSV, HTTP, reverse DNS.

A credential inside a URL (`url`, `url_template`, `seed_url`: the `user:password@` part or a
`token`, `api_key`, `secret`, `signature` ... query value) is a secret as well: sealed at rest,
shown as `***` (send the `***` back to keep it), and masked in test messages and logs. Prefer the
auth header over a token in the URL.

Connector URLs go through the same outbound guard as destinations: a loopback, link-local or
cloud-metadata address is refused when you save and again when connecting (RFC 1918 is fine;
`SESHAT_ALLOW_LOCAL_TARGETS=1` lifts it). Redirects are only followed within the same scheme, host
and port, so the token or auth header never goes to another host. The connector view carries a
`warnings` array (shown as a badge) when a credential is configured on an `http://` URL.

Seeded devices are filed under the connector's *site to file seeded devices under* (default
`default`), which must equal the site tag of the listener the device sends to; or, with *Use each
device's inventory site*, under the site (and VRF) the inventory reports. Pick whichever matches
how your listeners are tagged.

### NetBox

Token authentication (`Authorization: Token ...`; a read-only token is enough).

* **Lookup** by address: `GET /api/ipam/ip-addresses/?address=<ip>` finds the interface the
  address is assigned to and its device (or virtual machine), then
  `GET /api/dcim/devices/<id>/` (or `/api/virtualization/virtual-machines/<id>/`) supplies name,
  manufacturer (vendor), device type (model), platform (OS), serial, role, tenant, site, location,
  tags and custom fields, and `GET /api/dcim/interfaces/?device_id=<id>` the interfaces.
* **ifIndex.** NetBox does not model SNMP ifIndex. Create an interface custom field (default name
  `ifindex`, configurable) and fill it; interfaces without it are skipped, and interface names
  then come from the opt-in SNMP poll instead.
* **Pagination.** A `next` link is followed only if it has the configured URL's scheme, host and
  port. A link that leads anywhere else (a compromised server, a proxy rewriting links) stops the
  seed or lookup with an error, is logged and is counted in
  `seshat_connector_refused_links_total`; the token is never sent to that host. If your NetBox sits
  behind a proxy that advertises a different public host name, set the connector URL to that name.
* **Seed** pages through `/api/dcim/devices/` and `/api/virtualization/virtual-machines/`
  (devices without a primary IP are skipped). Interfaces are fetched while seeding only if
  *Fetch interfaces while seeding* is on, as that is one request per device; otherwise they are
  fetched on the first lookup or refresh. Measured against the synthetic test server, 10,000
  devices seed in under 2 s (about 4.5 s with the race detector).
* **Webhook.** Create a NetBox webhook for device and IP address changes, URL
  `https://<seshat>/api/connectors/netbox/webhook`, a secret, and put the same secret in the
  connector. Seshat checks the `X-Hook-Signature` HMAC-SHA512 of the body in constant time;
  anything else is rejected (401 for a wrong signature, 404 when the connector is off or has no
  secret) before any work is queued. A good one marks the matching devices stale and refreshes
  them immediately.

### Nautobot

Same connector with `flavor: nautobot` (a separate card). Differences handled: requests carry
`depth=1`; an address's owner is read from the reverse relations (`primary_ip4_for`,
`primary_ip6_for`, `interfaces`) when there is no `assigned_object`; `role`, `location` and nested
names are read the same tolerant way. Webhook at `/api/connectors/nautobot/webhook`, same
signature scheme. **Not verified against a live Nautobot** in this build (only against a test
server shaped from the Nautobot 2 REST documentation): run Test and a one-address lookup first and
file an issue with the response if a field is missing.

### CSV file

A path on the server (for example a file in the data volume). Header row required, any column
order, names case-insensitive, unknown columns ignored:

`ip` (required; several separated by `;` or spaces), `name`, `hostname`, `vendor`, `model`, `os`,
`os_version`, `serial`, `site`, `vrf`, `role`, `tenant`, `location`, `tags` (`;` separated), `mac`
(`;` separated), `engine_id`, `custom.<key>` (any number).

The file is re-read within a second of its modification time or size changing; a broken edit keeps
serving the last good copy and shows the error under Test. The same format can be uploaded once
with **Import CSV** on the Devices page (or `POST /api/devices/import`); those rows are recorded
as `manual`.

### HTTP / JSON

`GET` a URL template with `{ip}` filled in; map fields out of the JSON by dotted path
(`data.0.hostname`, `hw.vendor`, array indexes are numbers). 404 means "no such device"; any other
non-200 is an error, not "unknown". Optional auth header (value sealed), optional seed URL that
returns the whole inventory (then `ip` must be mapped).

### Reverse DNS

PTR query with a hard timeout (default 2 s), against the system resolver or one you name
(`host:port`). Skipped for devices that already have an inventory name.

## Opt-in SNMP polling

**Off by default, per site.** Under Settings, Connectors, Active SNMP polling, add a profile for a
site (or `*` for all sites without their own) and switch it on. For an unknown or stale device at
that site Seshat then reads sysDescr, sysObjectID, sysName and the IF-MIB columns (ifName,
ifAlias, ifHighSpeed, ifType) with a read-only v2c community or an SNMPv3 user from Inputs, SNMP,
v3 users, and records the answers as source `snmp`. It only ever GETs and walks; the poller has no
SET and a test fails the build if one appears.

The v2c community is sealed at rest and never returned (`community_set` per site says whether one is
stored). A blank community on save keeps the stored one; **Clear** (API: `clear_community: true`, or
`"community": null`) removes it. A profile switched to SNMPv3 never keeps a community: the stored
one is dropped on save.

Why it is off: it makes Seshat *originate* traffic toward devices on the strength of something
merely seen on the wire, which is something you should choose per site, and it needs credentials
you may not want on a collector. Leave it off where an inventory connector already supplies names,
and turn it on where it is the only source of interface names.

### Where polling is allowed to go

A packet can come from anyone, and a spoofed source address must never be able to make Seshat send
a credential to it. Every poll, from the knowledge base and from the Device Tracker pollers alike,
passes these checks before a single datagram leaves:

1. **Never-poll addresses**, refused whatever the profile says: loopback (`127.0.0.0/8`, `::1`),
   link-local (`169.254.0.0/16`, which includes the cloud metadata address, and `fe80::/10`),
   multicast, the unspecified address, `0.0.0.0/8`, `240.0.0.0/4` (reserved, includes the limited
   broadcast), and the other cloud metadata endpoints (`168.63.129.16`, `100.100.100.200`,
   `192.0.0.192`, `fd00:ec2::/32`, `fd20:ce::/32`). Every IPv6 form that embeds an IPv4 address is
   judged by the address it carries (IPv4-mapped `::ffff:127.0.0.1`, NAT64 `64:ff9b::/96`, 6to4
   `2002::/16`, ISATAP); the forms that cannot be judged cleanly are refused outright (the NAT64
   local-use prefix `64:ff9b:1::/48`, Teredo `2001::/32`, the deprecated IPv4-compatible `::a.b.c.d`).
2. **Allowed networks, per profile, and who may be polled.** Each profile has an *Allowed networks
   (CIDR)* list (Settings, Connectors, Active SNMP polling; `allowed_cidrs` in `PUT
   /api/connectors/snmp`, one CIDR or single address per entry, validated on save).
   **An address seen only in traffic (a syslog, trap or flow packet) is polled only when it falls
   inside that list. With an empty list nothing is polled on the strength of a packet**, not even
   from private address space: any host that can send one packet from its own address could
   otherwise have the site community sent to itself. A device that an operator adopted or manually
   added, or that an inventory connector (NetBox and the like) listed, is polled with an empty list
   too (the never-poll addresses still apply). When the list has entries, **only those** addresses
   are polled, adopted or not. To poll public addresses (or ranges such as `100.64.0.0/10`) list them
   explicitly, for example `198.51.100.0/24`. An address outside the list is not polled and no
   credential is sent. A damaged list (an entry that does not parse) matches nothing, so it fails
   closed. The Device Tracker pollers poll devices an operator enabled, so they count as adopted.
3. **Rate limits**, in addition to the stub-creation limit (`SESHAT_KB_CREATE_RATE`), the unknown-device
   cap and the bounded learn queue: a global token bucket for polls started (default 20 per second,
   burst 40), and a per-address interval (default one poll per address per 5 minutes) that doubles
   after each consecutive failure up to a cap (default 6 hours) and resets on success. A refused poll
   leaves the device unknown and is retried later. Tune with `SESHAT_KB_POLL_RATE`,
   `SESHAT_KB_POLL_BURST`, `SESHAT_KB_POLL_INTERVAL` and `SESHAT_KB_POLL_MAX_BACKOFF`.
   `SESHAT_KB_POLL_ALLOW_LOOPBACK=1` (off by default) lets 127.0.0.0/8 be polled when the profile lists it,
   for a demo or simulator on the same machine; never set it on a production collector.

Seshat still accepts and forwards events from any sender; only the *active poll* is gated. A device
that is not allowed stays unknown (or is named by an inventory connector, which is not affected).

The counters are `seshat_kb_snmp_polls_total{result}` on `/metrics`, with `result` one of
`attempted`, `refused_address`, `refused_allowlist` and `rate_limited`. A steady rise in
`refused_allowlist` means devices outside your allowed networks are sending traffic: add their
network if they are yours, or ignore it if they are not.

**Upgrading:** profiles saved before these checks have no allowed networks, so they now poll only
adopted and inventory devices, no longer devices known only from traffic. Add the CIDRs of the
networks whose unknown devices you want learned by polling (including public addresses) to the
profile after upgrading, or that learning stops. Polling a device on `127.0.0.1` (for example a
local simulator) is no longer possible; bind the simulator to a private address instead.

*Not exercised against a real device in this build*: the poller is tested through a fake session
that records every operation. Try it on one device first.

## Review: adopt, merge, ignore

Devices, Unknown lists what no source has made known. **Adopt** makes a device known with facts
you type (recorded as `manual`; they win over everything). **Merge** folds a device that reached
Seshat under a second address into the one you already have (same site and VRF). **Ignore** sets
it aside without deleting it; it leaves the list, is never expired and shows as unknown on events.
Each action is in the audit log. Operators and admins can review; only admins edit connectors.

## The device index and backfill

Every change to a known device is published to the sinks as a `seshat.device` document (one
revision per change, collected over 5 s per device so a seed or learn pass produces one). Index it
with the other datasets and join at query time, or fix up older events: events sent while a device
was unknown stay `unknown` in the destination until you backfill them.
To backfill, run an `_update_by_query` per device address over the time window in your destination.

## Settings reference

| Variable | Default | Meaning |
|---|---|---|
| `SESHAT_KB_UNKNOWN_CAP` | `50000` | most unknown (non-adopted, non-ignored) records kept |
| `SESHAT_KB_UNKNOWN_TTL` | `24h` | an unknown record unseen for this long is removed |
| `SESHAT_KB_REFRESH` | `24h` | known facts go stale after this |
| `SESHAT_KB_CREATE_RATE` | `200` | new unknown records per second per site and VRF |
| `SESHAT_KB_WORKERS` | `4` | background learning workers |
| `SESHAT_KB_LEARN_QUEUE` | `10000` | bounded learn queue; a full queue drops the job and retries on the next sighting |

A record also bounds what senders can teach it. Hostnames come in two slots: up to 16 given by an
operator, an inventory connector, DNS, SNMP or a pack (the newest kept), and up to 8 learned from
syslog headers (the newest kept). A learned name can never push out a name from the first slot, so a
host spoofing a device's address cannot replace its real names; when a trusted source later names
the same host, the name moves to the first slot. At most 64 flow exporter ids
(`<address>/<observation domain>`) are kept, newest first. A hostname longer than 253 bytes is ignored
and other learned identity strings are clipped to 256 bytes, so the cost of every update stays flat
however many names one sender invents.

Metrics: `seshat_kb_lookups_total{result=hit|stale|unknown|created|limited}`,
`seshat_kb_devices{status=known|unknown|stale|ignored}`, `seshat_kb_learn_queue_depth`.

## Known limits

* Flow records: the enrichment step stamps whatever event it is given; the flow input will add its
  in/out interface lookup when it lands. Traps (`ifIndex` varbind) are covered now.
* Multi-node: each node holds its own KB and writes through to the shared store; peers pick up
  each other's changes at restart. Live replication between SQLite nodes is described in `docs/ha.md`.
* Tested with SQLite only here. The store code is portable SQL and the shared store suite runs
  the new device tests against PostgreSQL when `TEST_DATABASE_URL` is set; that was not available
  when this was built.
