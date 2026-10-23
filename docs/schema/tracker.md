# Seshat and Device Tracker portal data contract

Contract name `seshat.tracker`, **version 1**. This document defines what crosses the boundary
between Seshat (which learns where devices are) and the **Device Tracker portal** (`device-tracker`
binary, the lookup page for everyday users). It covers all four ways the portal can get its data
with one shared shape:

| Mode | Mechanism | Contract surface |
|---|---|---|
| A. Push sync (default) | Seshat pushes batches to the portal over HTTPS | [Push-sync envelope](#push-sync-envelope) |
| B. Lookup API | Portal calls Seshat's read-only `/api/tracker/*` | [Lookup response](#lookup-response) |
| C. Direct database | Portal reads a read-only Postgres role | [`tracker_public` views](#tracker_public-views) |
| D. Shared Postgres, same cluster | Same as C, in the same database | `tracker_public` views |

The portal's lookup page renders one JSON shape (the lookup response) whichever mode feeds it. In
modes A, C and D the portal builds that response from the same row shapes that the views expose;
the sync `data` objects use exactly the view column names, so a portal store is a copy of the views.

Everything here is read-only toward the network: nothing in the contract describes or permits a
write action on a device.

## Conventions

- **Timestamps**: RFC 3339 UTC with `Z` (`2026-10-12T14:03:06Z`; fractional seconds allowed). In
  SQL, `timestamptz`.
- **MAC addresses**: lowercase, colon-separated (`02:00:5e:20:00:07`). Queries are normalised to this
  form (accepting `-`, `.`/Cisco-dotted and bare-hex input) before matching.
- **IP addresses**: textual; SQL type `inet`. Overlapping space is separated by `site` and `vrf`.
- **Freshness and provenance on every fact.** Every fact that can age carries the same five
  attributes, called the **provenance set** below:

  | Attribute | Type | Meaning |
  |---|---|---|
  | `observed_at` | timestamp | When the fact was last observed or confirmed (not when it was stored) |
  | `age_seconds` | integer | `generated_at - observed_at`, computed by the responder so clients need no clock |
  | `source` | string | How it was learned: `poll-fdb`, `poll-arp`, `poll-wireless`, `poll-subscriber`, `trap`, `dhcp`, `radius`, `ad`, `flow`, `api`, `inventory`, `dns`, `oui`, `fingerprint` |
  | `confidence` | number or null | 0.0 to 1.0, assigned by the collector/pack; null if not assessed |
  | `stale` | boolean | True when `age_seconds` exceeds the threshold stated in `stale_after_seconds` |

  A client must never present a stale fact as current: the UI shows the age ("40 s ago via trap")
  and marks stale facts.
- **Versioning.** `contract.version` is an integer. Within a version only additive changes are
  made: new optional keys, new columns at the end of a view, new enumeration values. A consumer must
  ignore keys it does not know. A breaking change increments the version, the lookup response and sync
  envelope carry the new number, and the views move to a new schema (`tracker_public_v2`) that exists
  next to the old one for a deprecation period.
- **Errors** follow the product convention: `{"error": {"code": "...", "message": "..."}}`. Users
  with the `user` role may call only the lookup; every other API returns 403, never an empty list.

## Lookup response

`GET /api/tracker/lookup?q=<mac|ip|hostname|user>`; the portal exposes the same path with the same
response. Requires an authenticated session or API token. Every call is audited (who, what, when).

- The query is classified (`mac`, `ip`, `hostname`, `user`), normalised, and echoed back.
- `results` holds one entry per distinct device (keyed by MAC), newest first. No match is
  `200` with `"results": []`, not `404`. An IP or user can legitimately match several devices.
- Facts the caller's scope or redaction policy hides are omitted and their paths are listed in
  `redactions`, so the UI can say "hidden by policy" instead of "unknown".
- `data_as_of` is the age of the data behind the answer: in mode B the newest observation in
  Seshat's store, in mode A the portal's last successful sync (so it keeps answering, with an honest
  "data as of", when Seshat is unreachable).

### Example (all values synthetic)

```json
{
  "contract": { "name": "seshat.tracker.lookup", "version": 1 },
  "generated_at": "2026-10-12T14:03:46Z",
  "data_as_of": "2026-10-12T14:03:30Z",
  "stale_after_seconds": 1800,
  "query": { "raw": "02-00-5E-20-00-07", "type": "mac", "normalized": "02:00:5e:20:00:07" },
  "redactions": [],
  "results": [
    {
      "identity": {
        "mac": "02:00:5e:20:00:07",
        "randomized_mac": true,
        "vendor":   { "value": "Example NIC Maker", "observed_at": "2026-10-12T13:41:00Z", "age_seconds": 1366, "source": "oui", "confidence": 1.0, "stale": false },
        "type":     { "value": "laptop", "observed_at": "2026-10-12T09:41:12Z", "age_seconds": 15754, "source": "fingerprint", "confidence": 0.7, "stale": true },
        "hostname": { "value": "laptop-17.example.com", "observed_at": "2026-10-12T13:58:02Z", "age_seconds": 344, "source": "dhcp", "confidence": 0.9, "stale": false },
        "user":     { "value": "jdoe", "observed_at": "2026-10-12T13:20:10Z", "age_seconds": 2616, "source": "radius", "confidence": 0.95, "stale": true }
      },
      "location": {
        "kind": "wired",
        "site": "example-site-a",
        "device": { "id": "dev-0003", "name": "Example Switch 3" },
        "port": { "name": "GigabitEthernet1/0/14", "ifindex": 10114 },
        "vlan": 120,
        "trace": [
          { "kind": "patch_panel", "label": "Panel P2/14" },
          { "kind": "jack", "label": "Jack J-214" },
          { "kind": "front_port", "label": "FP14", "device": "Patch Panel P2", "location": "Room 214 / Rack R3", "source": "netbox" },
          { "kind": "interface", "label": "eth0", "device": "Wall Plate J-214", "location": "Room 214", "source": "netbox" }
        ],
        "circuit": {
          "id": "0x00040078000e", "remote_id": "0x0006020000112233", "kind": "dhcp-option82",
          "label": "Circuit 0x00040078000e on Example Core 1",
          "device": { "id": "dev-0001", "name": "Example Core 1" },
          "observed_at": "2026-10-12T14:00:11Z", "age_seconds": 215, "source": "dhcp", "confidence": 0.85, "stale": false
        },
        "since": "2026-10-12T09:41:00Z",
        "observed_at": "2026-10-12T14:03:06Z",
        "age_seconds": 40,
        "source": "trap",
        "confidence": 0.9,
        "stale": false
      },
      "l3": {
        "ips": [
          {
            "ip": "192.0.2.57",
            "vrf": "default",
            "gateway": "192.0.2.1",
            "lease_expires": "2026-10-12T20:03:06Z",
            "since": "2026-10-12T09:41:12Z",
            "observed_at": "2026-10-12T14:00:11Z",
            "age_seconds": 215,
            "source": "poll-arp",
            "confidence": 0.9,
            "stale": false
          }
        ]
      },
      "history": [
        {
          "id": "iv-loc-000417", "kind": "location",
          "from": "2026-10-12T09:41:00Z", "to": null, "last_confirmed": "2026-10-12T14:03:06Z",
          "source": "trap", "confidence": 0.9,
          "site": "example-site-a",
          "device": { "id": "dev-0003", "name": "Example Switch 3" },
          "port": { "name": "GigabitEthernet1/0/14", "ifindex": 10114 },
          "vlan": 120
        },
        {
          "id": "iv-loc-000388", "kind": "location",
          "from": "2026-10-09T08:12:00Z", "to": "2026-10-09T17:30:00Z", "last_confirmed": "2026-10-09T17:29:41Z",
          "source": "poll-fdb", "confidence": 0.8,
          "site": "example-site-a",
          "device": { "id": "dev-0007", "name": "Example Switch 7" },
          "port": { "name": "GigabitEthernet1/0/3", "ifindex": 10103 },
          "vlan": 120
        },
        {
          "id": "iv-loc-000418", "kind": "location",
          "from": "2026-10-12T09:41:12Z", "to": null, "last_confirmed": "2026-10-12T14:00:11Z",
          "source": "dhcp", "confidence": 0.85,
          "device": { "id": "dev-0001", "name": "Example Core 1" },
          "circuit_id": "0x00040078000e"
        },
        {
          "id": "iv-l3-000912", "kind": "l3",
          "from": "2026-10-12T09:41:12Z", "to": null, "last_confirmed": "2026-10-12T14:00:11Z",
          "source": "poll-arp", "confidence": 0.9,
          "ip": "192.0.2.57", "vrf": "default", "gateway": "192.0.2.1"
        },
        {
          "id": "iv-wl-000051", "kind": "wireless",
          "from": "2026-10-11T13:00:00Z", "to": "2026-10-11T13:47:00Z", "last_confirmed": "2026-10-11T13:46:30Z",
          "source": "poll-wireless", "confidence": 0.9,
          "site": "example-site-a",
          "ap": { "id": "dev-0112", "name": "Example AP 12" },
          "ssid": "Example-Guest", "band": "5"
        },
        {
          "id": "iv-user-000204", "kind": "user",
          "from": "2026-10-12T08:55:00Z", "to": null, "last_confirmed": "2026-10-12T13:20:10Z",
          "source": "radius", "confidence": 0.95,
          "ip": "192.0.2.57", "user": "jdoe"
        }
      ],
      "history_truncated": false
    }
  ]
}
```

### Field reference

`results[]` entry:

| Path | Type | Required | Notes |
|---|---|---|---|
| `identity.mac` | string | yes | Normalised MAC |
| `identity.randomized_mac` | boolean | yes | Locally-administered bit set (first octet bit `0x02`); synthetic `02:00:5e:...` MACs have it set by construction |
| `identity.vendor` / `.type` / `.hostname` / `.user` | fact object | no | `{ "value": string }` plus the provenance set. Absent when unknown or redacted |
| `location` | object or null | yes | The best current attachment point; null when nothing is known |
| `location.kind` | string | yes | `wired`, `wireless` or `circuit` (an access-network circuit, below) |
| `location.site` | string | no | Site of the switch or AP |
| `location.device` | object | wired, circuit | `{ "id", "name" }` of the switch; for a circuit, of the relay, CMTS, OLT or BNG the circuit hangs off |
| `location.port` | object | wired; circuit when known | `{ "name", "ifindex" }`. Ports with a switch/router neighbour (uplinks) are never reported as an endpoint location |
| `location.vlan` | integer | no | |
| `location.ap`, `.ssid`, `.band`, `.rssi` | object, string, string, integer | wireless | `ap` is `{ "id", "name" }`; `band` is `2.4`, `5` or `6`; `rssi` in dBm |
| `location.channel` | integer | no | Radio channel of a wireless location (additive) |
| `location.circuit` | object | circuit; no otherwise | `{ "id", "remote_id"?, "kind"?, "label", "device"?, provenance set }`. `label` reads `Circuit <id> on <relay>`; `kind` is `cable-modem`, `ont`, `pppoe`, `dhcp-option82` or another technology. On a `circuit` location it is the whole attachment (`device` is the relay itself); on a `wired` location it is the circuit the endpoint was also seen on, with its own age and source (`device` is then the relay) |
| `location.trace[]` | array | no | Inventory trace from the port outwards: `{ "kind", "label", "device"?, "location"?, "source"? }`. Hops without `source` come from the port description (the interface alias). Hops with `"source": "netbox"` come from the inventory's cable trace (below): `kind` is `front_port`, `rear_port`, `patch_panel`, `interface` or `circuit`, `label` the port name, `device` the device it is on (a patch panel), `location` its room and rack (`Room 214 / Rack R3`). A PPPoE circuit adds `{ "kind": "session", "label": <Acct-Session-Id> }` |
| `location.since` | timestamp | yes | Start of the current interval |
| `location.observed_at` etc. | provenance set | yes | See conventions |
| `l3.ips[]` | array | yes (may be empty) | One entry per currently known IP |
| `l3.ips[].ip`, `.vrf` | string | yes | |
| `l3.ips[].gateway` | string | no | |
| `l3.ips[].lease_expires` | timestamp | no | DHCP lease expiry when known |
| `l3.ips[].circuit_id`, `.remote_id` | string | no | DHCP option 82 sub-options (additive) |
| `l3.ips[].since` | timestamp | yes | Start of the current interval |
| `l3.ips[].observed_at` etc. | provenance set | yes | `observed_at` is the "last confirmed" time |
| `history[]` | array | yes (may be empty) | Intervals, all kinds mixed, newest `from` first |
| `history[].id` | string | yes | Stable interval id (same value as `interval_id` in the views and in sync records) |
| `history[].kind` | string | yes | `location`, `l3`, `wireless`, `user` |
| `history[].from` | timestamp | yes | First observation of this fact |
| `history[].to` | timestamp or null | yes | When the interval closed (the entity moved or the fact expired); null while it is current |
| `history[].last_confirmed` | timestamp | yes | Last time the fact was re-confirmed |
| `history[].source`, `.confidence` | string, number | yes | |
| `history[]` kind attributes | | | location: `site`, `device`, `port`, `vlan`, `circuit_id` (circuit locations carry no `port` unless known). l3: `ip`, `vrf`, `gateway`. wireless: `site`, `ap`, `ssid`, `band`. user: `ip`, `user` |
| `history_truncated` | boolean | yes | True when older intervals were cut off by a server limit |

Top level: `contract`, `generated_at`, `data_as_of`, `stale_after_seconds` (the threshold the
responder applied to every `stale` flag in this response, a server setting stated here so clients do
not guess), `query`, `redactions` (paths hidden by policy, e.g.
`["results[0].identity.user"]`), `results`. The paths in use: `identity.user`, `identity.hostname`,
`location.trace`, `l3.ips`, `history.user`, `history.l3` and `history.older_than_<N>d` (each prefixed
`results[i].`). The portal adds the optional keys `notices` (for example `no_scope`) and `portal`
(`{ mode, state, as_of }`: where the answer came from); Seshat never sets them and consumers ignore keys
they do not know.

## `tracker_public` views

For modes C and D (Postgres backend only) Seshat maintains a schema `tracker_public` holding only
views over the tracker tables. The portal connects with a role that has `USAGE` on that schema and
`SELECT` on those views and nothing else:

```sql
COMMENT ON SCHEMA tracker_public IS 'seshat-tracker-contract 1';
CREATE ROLE tracker_portal_ro NOLOGIN;        -- the login role inherits from this
GRANT USAGE ON SCHEMA tracker_public TO tracker_portal_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA tracker_public TO tracker_portal_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA tracker_public GRANT SELECT ON TABLES TO tracker_portal_ro;
```

The views never expose credentials, configuration, audit data or event payloads. The contract
version is the number in the schema comment. Within a version columns are only appended. Every
view has `site` and `tenant` so the portal can scope rows by the user's SSO group.

### `tracker_public.devices`

One row per tracked endpoint (key: `mac`).

| Column | Type | Notes |
|---|---|---|
| `mac` | text | Primary key; normalised |
| `randomized_mac` | boolean | |
| `oui_vendor` | text | From the IEEE OUI registry |
| `oui_vendor_observed_at` | timestamptz | |
| `device_type` | text | From the DHCP fingerprint |
| `device_type_observed_at` | timestamptz | |
| `device_type_source` | text | |
| `device_type_confidence` | real | |
| `hostname` | text | From DHCP/DNS |
| `hostname_observed_at` | timestamptz | |
| `hostname_source` | text | |
| `user_name` | text | From RADIUS/AD |
| `user_observed_at` | timestamptz | |
| `user_source` | text | |
| `site` | text | Site of the most recent sighting |
| `tenant` | text | |
| `first_seen` | timestamptz | |
| `last_seen` | timestamptz | |

### `tracker_public.sightings_current`

One row per MAC that currently has a location (the "where is it now" answer, joined with
inventory). Wired and wireless are one row; columns that do not apply are null.

| Column | Type | Notes |
|---|---|---|
| `mac` | text | Primary key; references `devices.mac` |
| `kind` | text | `wired`, `wireless` or `circuit` (a MAC with both a wired and a circuit location is one `wired` row) |
| `site` | text | |
| `tenant` | text | |
| `device_id` | text | Switch (or controller) id |
| `device_name` | text | |
| `port_name` | text | Wired |
| `ifindex` | bigint | Wired |
| `vlan` | integer | |
| `ap_id` | text | Wireless |
| `ap_name` | text | Wireless |
| `ssid` | text | Wireless |
| `band` | text | Wireless: `2.4`, `5`, `6` |
| `rssi` | integer | Wireless, dBm |
| `trace` | jsonb | Array of `{ "kind", "label" }`, port outwards |
| `since` | timestamptz | Start of the current interval |
| `observed_at` | timestamptz | Last confirmation |
| `source` | text | |
| `confidence` | real | 0.0 to 1.0 |
| `interval_id` | text | The open `intervals_location` / `intervals_wireless` row this summarises |
| `channel` | integer | Wireless (additive) |
| `circuit_id`, `remote_id`, `circuit_kind` | text | Circuit rows only (additive) |

### `tracker_public.intervals_location`

Wired location history. One row per `(mac, device, port, vlan)` interval.

| Column | Type | Notes |
|---|---|---|
| `interval_id` | text | Primary key |
| `mac` | text | |
| `site` | text | |
| `tenant` | text | |
| `device_id` | text | |
| `device_name` | text | |
| `port_name` | text | |
| `ifindex` | bigint | |
| `vlan` | integer | |
| `trace` | jsonb | |
| `valid_from` | timestamptz | Maps to `history[].from` |
| `valid_to` | timestamptz | Null while current; maps to `history[].to` |
| `last_confirmed` | timestamptz | |
| `is_current` | boolean | `valid_to IS NULL` |
| `source` | text | |
| `confidence` | real | |
| `location_kind` | text | `wired` or `circuit` (additive; one open row per kind per MAC) |
| `circuit_id`, `remote_id`, `circuit_kind` | text | Circuit rows only (additive; null otherwise) |

### `tracker_public.intervals_l3`

IP to MAC history. One row per `(mac, ip, vrf)` interval.

| Column | Type | Notes |
|---|---|---|
| `interval_id` | text | Primary key |
| `mac` | text | |
| `ip` | inet | |
| `vrf` | text | |
| `gateway` | inet | |
| `lease_expires` | timestamptz | |
| `site` | text | |
| `tenant` | text | |
| `valid_from` | timestamptz | |
| `valid_to` | timestamptz | |
| `last_confirmed` | timestamptz | |
| `is_current` | boolean | |
| `source` | text | |
| `confidence` | real | |
| `circuit_id`, `remote_id` | text | DHCP option 82 sub-options when the relay added them (additive; null otherwise) |

### `tracker_public.intervals_wireless`

Association history. One row per `(mac, ap, ssid)` interval.

| Column | Type | Notes |
|---|---|---|
| `interval_id` | text | Primary key |
| `mac` | text | |
| `site` | text | |
| `tenant` | text | |
| `ap_id` | text | |
| `ap_name` | text | |
| `ssid` | text | |
| `band` | text | |
| `rssi_last` | integer | Last RSSI seen in the interval |
| `channel` | integer | Radio channel (additive; null when unknown) |
| `valid_from` | timestamptz | |
| `valid_to` | timestamptz | |
| `last_confirmed` | timestamptz | |
| `is_current` | boolean | |
| `source` | text | |
| `confidence` | real | |

### `tracker_public.intervals_user`

IP to user history (RADIUS/802.1X accounting, AD logon events). One row per `(ip, user)` interval.
`mac` is filled when the user event could be tied to a MAC, otherwise null.

| Column | Type | Notes |
|---|---|---|
| `interval_id` | text | Primary key |
| `ip` | inet | |
| `vrf` | text | |
| `mac` | text | Nullable |
| `user_name` | text | The portal's redaction policy may hide this column |
| `site` | text | |
| `tenant` | text | |
| `valid_from` | timestamptz | |
| `valid_to` | timestamptz | |
| `last_confirmed` | timestamptz | |
| `is_current` | boolean | |
| `source` | text | |
| `confidence` | real | |

Lookups by MAC, IP, hostname and user are backed by indexes on the underlying tables
(`devices.mac`, `devices.hostname`, `devices.user_name`, `intervals_l3.ip`, `intervals_user.ip`,
`intervals_user.user_name`).

## Push-sync envelope

Mode A. Seshat (or a Seshat Edge forwarding for its site) is the **sender**; the portal is the
**receiver**. The sender dials out; the collector network accepts no inbound connection. Delivery
is **at-least-once and idempotent**: any batch can be sent again and the receiver ends in the same
state.

### Request

```
POST /api/sync/v1/batches HTTP/1.1
Authorization: Bearer <pre-shared token>        (or mTLS client certificate)
Content-Type: application/json
Content-Encoding: gzip                           (optional)
Idempotency-Key: 6f1d2c1e-0b7a-4d63-9a64-1c2f7a9e0001
```

```json
{
  "contract": { "name": "seshat.tracker.sync", "version": 1 },
  "sender": { "instance_id": "seshat-1", "stream_id": "stream-example-org" },
  "batch": {
    "id": "6f1d2c1e-0b7a-4d63-9a64-1c2f7a9e0001",
    "kind": "delta",
    "sent_at": "2026-10-12T14:03:31Z",
    "first_seq": 1042,
    "last_seq": 1045,
    "count": 4,
    "data_as_of": "2026-10-12T14:03:30Z"
  },
  "records": [
    {
      "seq": 1042, "op": "upsert", "entity": "intervals_location",
      "key": { "interval_id": "iv-loc-000417" },
      "data": {
        "interval_id": "iv-loc-000417", "mac": "02:00:5e:20:00:07", "site": "example-site-a", "tenant": "example-tenant",
        "device_id": "dev-0003", "device_name": "Example Switch 3", "port_name": "GigabitEthernet1/0/14", "ifindex": 10114, "vlan": 120,
        "trace": [ { "kind": "patch_panel", "label": "Panel P2/14" }, { "kind": "jack", "label": "Jack J-214" }, { "kind": "room", "label": "Room 214" } ],
        "valid_from": "2026-10-12T09:41:00Z", "valid_to": null, "last_confirmed": "2026-10-12T14:03:06Z",
        "is_current": true, "source": "trap", "confidence": 0.9
      }
    },
    {
      "seq": 1043, "op": "upsert", "entity": "sightings_current",
      "key": { "mac": "02:00:5e:20:00:07" },
      "data": {
        "mac": "02:00:5e:20:00:07", "kind": "wired", "site": "example-site-a", "tenant": "example-tenant",
        "device_id": "dev-0003", "device_name": "Example Switch 3", "port_name": "GigabitEthernet1/0/14", "ifindex": 10114, "vlan": 120,
        "ap_id": null, "ap_name": null, "ssid": null, "band": null, "rssi": null,
        "trace": [ { "kind": "patch_panel", "label": "Panel P2/14" }, { "kind": "jack", "label": "Jack J-214" }, { "kind": "room", "label": "Room 214" } ],
        "since": "2026-10-12T09:41:00Z", "observed_at": "2026-10-12T14:03:06Z", "source": "trap", "confidence": 0.9,
        "interval_id": "iv-loc-000417"
      }
    },
    {
      "seq": 1044, "op": "upsert", "entity": "devices",
      "key": { "mac": "02:00:5e:20:00:07" },
      "data": {
        "mac": "02:00:5e:20:00:07", "randomized_mac": true,
        "oui_vendor": "Example NIC Maker", "oui_vendor_observed_at": "2026-10-12T13:41:00Z",
        "device_type": "laptop", "device_type_observed_at": "2026-10-12T09:41:12Z", "device_type_source": "fingerprint", "device_type_confidence": 0.7,
        "hostname": "laptop-17.example.com", "hostname_observed_at": "2026-10-12T13:58:02Z", "hostname_source": "dhcp",
        "user_name": "jdoe", "user_observed_at": "2026-10-12T13:20:10Z", "user_source": "radius",
        "site": "example-site-a", "tenant": "example-tenant",
        "first_seen": "2026-09-30T07:12:00Z", "last_seen": "2026-10-12T14:03:06Z"
      }
    },
    {
      "seq": 1045, "op": "delete", "entity": "intervals_user",
      "key": { "interval_id": "iv-user-000199" }
    }
  ]
}
```

Envelope fields:

| Path | Type | Notes |
|---|---|---|
| `contract.name` / `.version` | string / integer | `seshat.tracker.sync` / 1 |
| `sender.instance_id` | string | Seshat instance or edge that produced the batch |
| `sender.stream_id` | string | Identifies one **sequence stream**. Sequence numbers are only comparable inside a stream; a cluster uses one stream so replicas do not interleave |
| `batch.id` | string (UUID) | Also sent as `Idempotency-Key` |
| `batch.kind` | string | `delta` (default) or `snapshot` (see Resync) |
| `batch.first_seq`, `batch.last_seq`, `batch.count` | integer | `last_seq - first_seq + 1 = count`; sequence numbers inside a batch are gapless and ascending. An empty heartbeat batch has `count: 0` and null `first_seq`/`last_seq`; it only refreshes `data_as_of` |
| `batch.data_as_of` | timestamp | Newest observation the sender has handed over; the portal shows it as "data as of" |
| `records[].seq` | integer | Monotonic, gapless per stream, assigned by the sender when the change is committed to its outbox (not a clock value) |
| `records[].op` | string | `upsert` (insert or replace the whole row) or `delete` |
| `records[].entity` | string | One of the view names: `devices`, `sightings_current`, `intervals_location`, `intervals_l3`, `intervals_wireless`, `intervals_user` |
| `records[].key` | object | Primary key columns of the entity: `mac` for `devices` and `sightings_current`, `interval_id` for the interval views |
| `records[].data` | object | For `upsert`: the complete row, keyed by the view's column names (JSON types: text to string, inet to string, timestamptz to RFC 3339 string, jsonb to JSON, null allowed). Absent for `delete` |

Limits proposed for version 1 (both configurable on the sender): at most 1,000 records and 5 MiB
uncompressed per batch.

### Receiver rules (idempotency)

The receiver stores `applied_through` per `sender.stream_id`.

1. Authenticate; reject a `contract.version` it does not support with `409` and
   `error.code: "unsupported_contract"`.
2. If `batch.last_seq <= applied_through`, the batch was already applied: do nothing and answer
   `200` with `"duplicate": true` and the unchanged `applied_through`.
3. If `batch.first_seq > applied_through + 1`, a batch was lost: answer `409` with
   `error.code: "sequence_gap"` and `"expected_seq": applied_through + 1`. The sender resumes from
   `expected_seq` (it keeps its outbox until acknowledged) or, if it no longer has those records,
   performs a resync.
4. If the batch overlaps (`first_seq <= applied_through < last_seq`), skip the records with
   `seq <= applied_through` and apply the rest.
5. Apply all remaining records in **one transaction**, then set `applied_through = last_seq` in
   the same transaction. A crash in between simply makes the sender resend.
6. `upsert` replaces the row for `key` (insert if absent); `delete` removes it (no error if
   absent). Because rows are keyed by natural keys and carry the full row, replaying a record can
   never produce a different result than applying it once.
7. A batch is accepted or rejected as a whole.

### Response

```json
{ "ok": true, "stream_id": "stream-example-org", "applied_through": 1045, "duplicate": false, "received_at": "2026-10-12T14:03:31Z" }
```

`warnings` (an array of strings) is added when the credential is a legacy single-sender credential or a sync token
without a site/tenant scope (see [Sender isolation](#sender-isolation)). Senders ignore it; operators should act on it.

| Status | Meaning | Sender action |
|---|---|---|
| `200` | Applied, or already applied (`duplicate: true`) | Advance the outbox to `applied_through` |
| `400` | Malformed batch (bad JSON, `count` mismatch, unknown entity, bad key) | Do not retry; alert; the batch is quarantined on the sender |
| `401` / `403` | Bad token / certificate, sender not allowed for this stream, or `out_of_scope`: a record names a site or tenant outside the token's scope (the body carries `rejected`, the number of offending records, and `first_seq`; nothing of the batch is applied) | Stop and alert |
| `409` | `sequence_gap` (with `expected_seq`), `unsupported_contract`, or `key_conflict`: a legacy credential addressed an interval id held by a stream (nothing of the batch is applied) | Resume from `expected_seq`, or resync / upgrade; for `key_conflict` fix the sender's ids and alert |
| `413` | Batch too large | Halve the batch and retry |
| `429` / `5xx` / network error | Receiver busy or down | Retry with the same `batch.id`/`Idempotency-Key` using exponential backoff; keep buffering to disk |

### Resync (`batch.kind: "snapshot"`)

When the receiver is new, was restored from backup, or reports a gap the sender can no longer fill,
the sender sends a **snapshot**: the full current content of every entity as `upsert` records, in
batches of `kind: "snapshot"` with an extra `batch.snapshot` object:

```json
"snapshot": { "id": "snap-0001", "part": 3, "final": false }
```

Snapshot records take the next sequence numbers of the stream like any others. When the receiver
applies the batch with `"final": true` it deletes, for each entity, every row **of that sender's stream** that was
not upserted under that `snapshot.id`, in the same transaction, which makes the receiver an exact copy of
the sender's state at snapshot time. Rows of other streams are never touched. Deltas that were committed after the
snapshot started follow as ordinary `delta` batches.

### Sender isolation

Every row the portal stores carries the `stream_id` of the stream that wrote it (migration 0131). A sender can only
overwrite, delete and sweep its own rows. Two honest senders do not collide:

- **Intervals** (`iv-loc-...`, `iv-l3-...`, `iv-wl-...`, `iv-user-...`): senders number them themselves, so two
  senders both send `iv-loc-000001`. A stream keeps the id it chose while nobody else holds it; when another
  stream does, the row is stored under a per-stream range (the id the portal shows for it is then larger) and the
  sender's later updates and deletes of `iv-loc-000001` find it again. One sender's id never overwrites or deletes
  another's.
- **Devices** are keyed by MAC address alone. The first stream to write a MAC owns that device summary; a later
  stream's record for the same MAC is skipped (the rest of its batch applies) and counted in the response as
  `skipped_conflicts`. That stream's intervals for the MAC are still stored. Do not give two senders the same
  MAC if both need their own device summary.
- The legacy credential (static token, mTLS) uses the ids as sent and gets `409 key_conflict` when an interval id
  is held by a stream.

A sync token also carries an **allowed scope** (sites and/or tenants, the same scope object other tokens use):

| Credential | What it may write |
|---|---|
| Sync token with a `scope` (and the `stream_id` it requires) | Records whose `site` is one of the scope's sites and whose `tenant` is one of its tenants (a record may leave one of them empty, not both). Anything else is refused with `403 out_of_scope`. Its stream's rows, plus any pre-upgrade rows inside its scope, are its own. |
| Sync token with `scope.all` / `*` | Any site or tenant, explicitly. Its stream's rows, plus pre-upgrade rows, are its own. |
| Sync token without a scope (created before scopes applied to sync) | Accepted for compatibility, with a warning in the log, in the ingest response (`warnings`) and in the token list; not limited to a site or tenant. Re-create it with a scope. |
| `SESHAT_PORTAL_SYNC_TOKEN` and mTLS client certificates | **Legacy single-sender credential, deprecated** (a startup warning is logged). Unscoped, and only for rows that belong to no stream: it can write and sweep the rows with an empty `stream_id` (everything stored before the upgrade) and nothing else. It cannot overwrite or delete a stream's rows. |

Rows stored before the upgrade have an empty `stream_id`. The first final snapshot of an unscoped sender adopts them: what
it sends becomes its own, what it does not send is swept. A scoped sender adopts, and sweeps, only the pre-upgrade rows
inside its own scope.

### What the portal does with it

The portal keeps the received rows in its own store (SQLite or Postgres) with the same column
names, builds lookup responses from them (freshness is computed at query time from `observed_at`),
shows `data_as_of` from the newest `batch.data_as_of`, and applies its own field redaction and
SSO-group scoping (by `site` / `tenant`) when it answers. The sync token grants write access to the
portal's tracker store only, and the receiver never calls back into the collector network.

## Relationship to the `seshat.tracker` event dataset

The Device Tracker also publishes `seshat.tracker` events to log destinations (fields in
[`fields.md`](fields.md)). Those events are a stream of observations for SIEM and audit use;
the tables and sync records above are the queryable current-state-plus-history model. The two use
the same vocabulary (`source`, `confidence`, `observed_at`, interval ids), so an event's
`seshat.tracker.interval_id` joins to `history[].id` and to the `interval_id` columns.
