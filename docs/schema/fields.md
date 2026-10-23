# Seshat field reference

Schema version **1.0**, built on **ECS 8.11**. This file is the complete field list; the machine
readable form is [`seshat-event.schema.json`](seshat-event.schema.json) and the Elasticsearch /
OpenSearch mappings live in [`deploy/elasticsearch`](../../deploy/elasticsearch) and
[`deploy/opensearch`](../../deploy/opensearch). How the schema is organised and versioned is in
the [README](README.md).

## How to read the tables

- **Field**: dotted path. Documents are emitted as nested JSON objects (`"host": {"name": ...}`),
  never as literal dotted keys.
- **Type**: the index type. `keyword[]`, `ip[]` and similar mean "array of"; every field can hold
  an array in Elasticsearch/OpenSearch, but Seshat emits arrays only where the type says so.
  `flattened` maps to `flattened` (Elasticsearch) or `flat_object` (OpenSearch). `nested` fields
  are arrays of objects that need `nested` queries. `geo_point` is used only by the optional
  GeoIP fields. In the data-stream templates `data_stream.*` is `constant_keyword` on
  Elasticsearch and `keyword` on OpenSearch.
- **Origin**: `ECS` = the field name and meaning come from the Elastic Common Schema (Seshat
  states how it fills it); `seshat` = defined by Seshat, under the closed `seshat.*` namespace.
- **Req**: `Y` = required in every dataset that carries the field, `C` = required in some datasets
  only (see **Datasets** and the description), `O` = optional. "Required" means Seshat always
  writes it and the JSON Schema rejects documents without it.
- **Datasets**: which datasets carry the field: `all`, or a list of `trap`, `syslog`, `flow`,
  `flow_rollup`, `tracker`, `device`, `metric` (the dataset `seshat.<name>`).
- **Example**: synthetic. Addresses are from the documentation ranges (192.0.2.0/24,
  198.51.100.0/24, 203.0.113.0/24, 2001:db8::/32), MACs are `02:00:5e:xx:xx:xx`, hostnames are under
  `example.com`, the organisation is `Example Org` / `EXO`.

Conventions that apply to every field:

- **Timestamps** are RFC 3339 UTC strings.
- **MAC addresses** are lowercase, colon-separated (`02:00:5e:10:00:03`). ECS suggests the
  hyphenated uppercase RFC 7042 form; Seshat normalises to one form everywhere so the Device
  Tracker, routing rules and dashboards compare equal. Convert in a destination pipeline if you
  need the ECS form.
- **IP addresses** are the textual form (RFC 5952 for IPv6). Overlapping address space is
  disambiguated by `seshat.source.site` / `seshat.source.vrf`, not by rewriting addresses.
- **Severity** is on the syslog scale everywhere: 0 emergency ... 7 debug.
- **Never emitted**: SNMPv1/v2c community strings, SNMPv3 keys, passwords, tokens. They exist in
  no field of any dataset.
- Anything vendor-specific that has no first-class field goes into a `flattened` field
  (`labels`, `seshat.device.custom`, `seshat.device.provenance`, `seshat.trap.vars`,
  `seshat.syslog.sd`, `seshat.syslog.extension`, `seshat.flow.ie`), so packs never require a
  mapping change.

## Datasets

| `event.dataset` | `event.kind` | One document is... |
|---|---|---|
| `seshat.trap` | `event` | one SNMP trap or inform |
| `seshat.syslog` | `event` | one syslog message |
| `seshat.flow` | `event` | one flow record (also NSEL firewall events, which carry `seshat.flow.*` and are handled as event traffic) |
| `seshat.flow_rollup` | `metric` | one roll-up row for a one-minute window |
| `seshat.tracker` | `event` | one Device Tracker sighting or interval open/extend/close |
| `seshat.device` | `state` | one revision of a device knowledge-base record |
| `seshat.metric` | `metric` | one streaming-telemetry sample (gNMI, Cisco MDT, Juniper JTI): one leaf value |

## Field tables

### Base and ECS housekeeping

| Field | Type | Origin | Req | Datasets | Description | Example |
|---|---|---|---|---|---|---|
| `@timestamp` | date | ECS | Y | all | Event time. The device-reported time when it is present and plausible, otherwise the receive time (`event.created`). UTC, millisecond precision or better. | `2026-10-12T14:03:07.412Z` |
| `ecs.version` | keyword | ECS | Y | all | ECS version the field names follow. | `8.11.0` |
| `data_stream.type` | keyword | ECS | Y | all | Data stream type. Always `logs`. | `logs` |
| `data_stream.dataset` | keyword | ECS | Y | all | Data stream dataset. Always equals `event.dataset`. | `seshat.trap` |
| `data_stream.namespace` | keyword | ECS | Y | all | Data stream namespace: the organisation short name, lowercased (see README, section Data streams). | `exo` |
| `message` | text | ECS | C | all | Human-readable one-line rendering. Traps: `<MIB>::<name>` plus rendered varbinds. Syslog: the MSG part after the header. Flows and device records: optional summary. | `IF-MIB::linkDown ifIndex.10114=10114 ifOperStatus.10114=down` |
| `tags` | keyword[] | ECS | O | all | Free-form tags added by Seshat or by routing rules. Seshat itself adds the tags listed under "Tags set by Seshat" below. | `["seshat-unknown-device"]` |
| `labels` | flattened | ECS | O | all | Operator-defined key/value pairs added by routing rules. Values are strings. Stored as one flattened field so labels never need mapping changes. | `{"team": "netops"}` |

### `event.*`

| Field | Type | Origin | Req | Datasets | Description | Example |
|---|---|---|---|---|---|---|
| `event.kind` | keyword | ECS | Y | all | `event` for traps, syslog, flows and tracker sightings; `metric` for roll-ups and streaming-telemetry samples; `state` for device records. | `event` |
| `event.category` | keyword[] | ECS | Y | all | ECS event category list (`network`, `authentication`, `host`, `configuration`, ...). Pack mappings set it; the default is `network`. | `["network"]` |
| `event.type` | keyword[] | ECS | O | all | ECS event type list (`info`, `connection`, `start`, `end`, `change`, `denied`, ...). | `["info"]` |
| `event.action` | keyword | ECS | O | all | What happened. Traps: the notification name. Tracker: `sighting`, `interval-opened`, `interval-extended`, `interval-closed`, `watch.hit`, `unknown.appeared`. Flows: `flow` (NSEL firewall events: `flow-created`, `flow-denied`, `flow-deleted`). | `linkDown` |
| `event.dataset` | keyword | ECS | Y | all | One of `seshat.trap`, `seshat.syslog`, `seshat.flow`, `seshat.flow_rollup`, `seshat.tracker`, `seshat.device`, `seshat.metric`. The routing key for data streams. | `seshat.trap` |
| `event.module` | keyword | ECS | Y | all | Always `seshat`. | `seshat` |
| `event.id` | keyword | ECS | Y | all | Unique event id (ULID, generated at receive time). Stable across retries and destinations, so it is safe as a document id for de-duplication. | `01K7XEXAMPLE0TRAP00000001` |
| `event.created` | date | ECS | Y | all | When Seshat received (or, for roll-ups and device records, produced) the event. | `2026-10-12T14:03:07.440Z` |
| `event.ingested` | date | ECS | O | all | Set by the destination's ingest pipeline, never by Seshat. Mapped so pipelines can set it. | `2026-10-12T14:03:08.100Z` |
| `event.original` | keyword | ECS | C | syslog, flow, trap | The raw message as received (syslog line). Not indexed and without doc values; present only in `_source`. Optional for traps and flows. | `<165>1 2026-10-12T14:03:07.412Z switch3.example.com sshd 2411 ID47 ...` |
| `event.severity` | long | ECS | C | trap, syslog, tracker | Severity on the syslog scale 0 (emergency) to 7 (debug). Syslog: the PRI severity. Traps: set by the pack mapping, default 5 (notice). | `3` |
| `event.code` | keyword | ECS | O | trap, syslog, flow | Vendor message code or mnemonic when a pack extracts one. | `LINK-UPDOWN` |
| `event.outcome` | keyword | ECS | O | syslog, flow | `success`, `failure` or `unknown`, when the pack can tell. | `failure` |
| `event.start` | date | ECS | Y | flow, flow_rollup | Flow start time (flow) or start of the roll-up window. | `2026-10-12T14:02:41.000Z` |
| `event.end` | date | ECS | Y | flow, flow_rollup | Flow end time (flow) or end of the roll-up window. | `2026-10-12T14:03:05.000Z` |
| `event.duration` | long | ECS | O | flow, flow_rollup | Duration in nanoseconds (ECS convention). | `24000000000` |

### `observer.*`

| Field | Type | Origin | Req | Datasets | Description | Example |
|---|---|---|---|---|---|---|
| `observer.vendor` | keyword | ECS | Y | all | The organisation name from branding. Changes with branding (a value, not a field name). | `Example Org` |
| `observer.product` | keyword | ECS | Y | all | Always `Seshat`. | `Seshat` |
| `observer.version` | keyword | ECS | Y | all | Seshat version that produced the event. | `0.1.0` |
| `observer.name` | keyword | ECS | O | all | Collector or edge instance name. | `collector-1.example.com` |
| `observer.type` | keyword | ECS | O | all | Always `gateway`. | `gateway` |
| `observer.ip` | ip[] | ECS | O | all | Addresses of the collector that produced the event. | `["192.0.2.5"]` |

### `host.*` and `related.*`

| Field | Type | Origin | Req | Datasets | Description | Example |
|---|---|---|---|---|---|---|
| `host.name` | keyword | ECS | C | trap, syslog, flow, device, metric | The sending device as observed: sysName, syslog header hostname or the KB name. Device records: the KB name. | `switch3.example.com` |
| `host.ip` | ip[] | ECS | C | trap, syslog, flow, device, metric | The sending device's address(es). Events: the source address of the datagram (and the agent address when different). Device records: every known address. | `["192.0.2.11"]` |
| `host.mac` | keyword[] | ECS | O | trap, syslog, flow, device | Device MAC addresses when known. Always lowercase, colon-separated (`02:00:5e:10:00:03`); this deliberately differs from the hyphenated RFC 7042 notation ECS suggests, so values match what the Device Tracker normalises. | `["02:00:5e:10:00:03"]` |
| `related.ip` | ip[] | ECS | O | trap, syslog, flow, tracker, metric | Every IP address mentioned in the event (host, source, destination, varbind addresses, tracked endpoint). | `["192.0.2.11"]` |
| `related.hosts` | keyword[] | ECS | O | trap, syslog, flow, tracker | Every hostname mentioned in the event. | `["switch3.example.com"]` |
| `related.user` | keyword[] | ECS | O | syslog, tracker | Every user name mentioned in the event. | `["admin"]` |

### `error.*`

| Field | Type | Origin | Req | Datasets | Description | Example |
|---|---|---|---|---|---|---|
| `error.message` | text | ECS | O | trap, syslog, flow, metric | Set when decoding was partial (bad checksum, truncated PDU, unparsable header). The event is still forwarded. | `truncated varbind list` |
| `error.code` | keyword | ECS | O | trap, syslog, flow, metric | Short machine code for the decode problem. | `snmp.truncated` |

### `log.*`, `process.*`, `user.*` (syslog)

| Field | Type | Origin | Req | Datasets | Description | Example |
|---|---|---|---|---|---|---|
| `log.level` | keyword | ECS | Y | syslog | Lowercase RFC 5424 severity name (see the severity table). | `notice` |
| `log.syslog.facility.code` | long | ECS | Y | syslog | Syslog facility number 0-23. Mirror of `seshat.syslog.facility.code`. | `20` |
| `log.syslog.facility.name` | keyword | ECS | Y | syslog | Syslog facility name (see the facility table). Mirror of `seshat.syslog.facility.name`. | `local4` |
| `log.syslog.severity.code` | long | ECS | Y | syslog | Syslog severity number 0-7. Mirror of `seshat.syslog.severity.code`. | `5` |
| `log.syslog.severity.name` | keyword | ECS | Y | syslog | Syslog severity name. Mirror of `seshat.syslog.severity.name`. | `notice` |
| `log.syslog.priority` | long | ECS | Y | syslog | PRI value: facility * 8 + severity. When the PRI is missing Seshat assumes `user.notice` (13) and tags the event `seshat-no-pri`. | `165` |
| `process.name` | keyword | ECS | O | syslog | Mirror of `seshat.syslog.appname` (RFC 5424 APP-NAME or the RFC 3164 TAG). | `sshd` |
| `process.pid` | long | ECS | O | syslog | Numeric `seshat.syslog.procid` when it parses as an integer. | `2411` |
| `user.name` | keyword | ECS | O | syslog, flow | User name extracted by a pack parser. | `admin` |

### `source.*` and `destination.*`

| Field | Type | Origin | Req | Datasets | Description | Example |
|---|---|---|---|---|---|---|
| `source.ip` | ip | ECS | O | syslog, flow, flow_rollup | Source address. Flows: required in practice; overlapping address space is disambiguated by `seshat.source.site` and `seshat.source.vrf`. | `192.0.2.50` |
| `source.port` | long | ECS | O | syslog, flow, flow_rollup | Source transport port. | `49822` |
| `source.mac` | keyword | ECS | O | syslog, flow, flow_rollup | Source MAC address (lowercase, colon-separated) when the exporter reports it. | `02:00:5e:20:00:07` |
| `source.bytes` | long | ECS | O | flow, flow_rollup | Bytes sent by the source (scaled by the sampling rate when `seshat.flow.scaled` is true). Unidirectional flow records populate only the source that sent them; bidirectional exporters (NSEL, IPFIX reverse IEs) fill both. | `1843200` |
| `source.packets` | long | ECS | O | flow, flow_rollup | Packets sent by the source, scaled like `source.bytes`. | `12000` |
| `source.domain` | keyword | ECS | O | syslog, flow | Source DNS name when resolved by enrichment or parsed from the message. | `host.example.com` |
| `source.as.number` | long | ECS | O | flow, flow_rollup | Source autonomous system number (from the exporter record or an operator-supplied database). | `64500` |
| `source.as.organization.name` | keyword | ECS | O | flow, flow_rollup | AS organisation from an operator-supplied database (none bundled). | `Example Transit` |
| `source.geo.country_iso_code` | keyword | ECS | O | flow, flow_rollup | Country from an operator-supplied MaxMind-format database (none bundled). | `ZZ` |
| `source.geo.city_name` | keyword | ECS | O | flow, flow_rollup | City from an operator-supplied database. | `Example City` |
| `source.geo.location` | geo_point | ECS | O | flow, flow_rollup | Coordinates from an operator-supplied database. | `{"lat": 0.0, "lon": 0.0}` |
| `source.nat.ip` | ip | ECS | O | syslog, flow | Translated source address (NSEL, firewall logs). | `203.0.113.10` |
| `source.nat.port` | long | ECS | O | syslog, flow | Translated source port. | `20112` |
| `destination.ip` | ip | ECS | O | syslog, flow, flow_rollup | Destination address. Flows: required in practice; overlapping address space is disambiguated by `seshat.source.site` and `seshat.source.vrf`. | `198.51.100.20` |
| `destination.port` | long | ECS | O | syslog, flow, flow_rollup | Destination transport port. | `443` |
| `destination.mac` | keyword | ECS | O | syslog, flow, flow_rollup | Destination MAC address (lowercase, colon-separated) when the exporter reports it. | `02:00:5e:20:00:08` |
| `destination.bytes` | long | ECS | O | flow, flow_rollup | Bytes sent by the destination (scaled by the sampling rate when `seshat.flow.scaled` is true). Unidirectional flow records populate only the destination that sent them; bidirectional exporters (NSEL, IPFIX reverse IEs) fill both. | `0` |
| `destination.packets` | long | ECS | O | flow, flow_rollup | Packets sent by the destination, scaled like `destination.bytes`. | `0` |
| `destination.domain` | keyword | ECS | O | syslog, flow | Destination DNS name when resolved by enrichment or parsed from the message. | `host.example.com` |
| `destination.as.number` | long | ECS | O | flow, flow_rollup | Destination autonomous system number (from the exporter record or an operator-supplied database). | `64501` |
| `destination.as.organization.name` | keyword | ECS | O | flow, flow_rollup | AS organisation from an operator-supplied database (none bundled). | `Example Transit` |
| `destination.geo.country_iso_code` | keyword | ECS | O | flow, flow_rollup | Country from an operator-supplied MaxMind-format database (none bundled). | `ZZ` |
| `destination.geo.city_name` | keyword | ECS | O | flow, flow_rollup | City from an operator-supplied database. | `Example City` |
| `destination.geo.location` | geo_point | ECS | O | flow, flow_rollup | Coordinates from an operator-supplied database. | `{"lat": 0.0, "lon": 0.0}` |
| `destination.nat.ip` | ip | ECS | O | syslog, flow | Translated destination address (NSEL, firewall logs). | `203.0.113.10` |
| `destination.nat.port` | long | ECS | O | syslog, flow | Translated destination port. | `20112` |

### `network.*`

| Field | Type | Origin | Req | Datasets | Description | Example |
|---|---|---|---|---|---|---|
| `network.transport` | keyword | ECS | O | syslog, flow, flow_rollup | Lowercase IANA protocol keyword (`tcp`, `udp`, `icmp`, `icmp6`, `gre`, ...). | `tcp` |
| `network.iana_number` | keyword | ECS | O | syslog, flow, flow_rollup | IANA protocol number as a string. | `6` |
| `network.type` | keyword | ECS | O | syslog, flow, flow_rollup | `ipv4` or `ipv6`. | `ipv4` |
| `network.protocol` | keyword | ECS | O | syslog, flow, flow_rollup | Application protocol when known (`dns`, `https`, ...). | `https` |
| `network.application` | keyword | ECS | O | syslog, flow, flow_rollup | Application name from the exporter (NBAR/AppID style IEs) or the roll-up key for per-application roll-ups. | `web-browsing` |
| `network.direction` | keyword | ECS | O | syslog, flow, flow_rollup | ECS direction: `ingress`, `egress`, `inbound`, `outbound`, `internal`, `external`, `unknown`. Flows: `ingress`/`egress` as exported. | `ingress` |
| `network.bytes` | long | ECS | O | flow, flow_rollup, syslog | Total bytes of the record, scaled by the sampling rate. Roll-ups: the window total for the key. | `1843200` |
| `network.packets` | long | ECS | O | flow, flow_rollup, syslog | Total packets, scaled like `network.bytes`. | `12000` |
| `network.community_id` | keyword | ECS | O | flow, syslog | Community ID v1 flow hash, for joining flows to IDS/firewall events. | `1:YSgEowGgu1HXOlTuZJGj4Py0lXA=` |
| `network.vlan.id` | keyword | ECS | O | flow, flow_rollup | VLAN id of the flow when exported (source VLAN, see `seshat.flow.src_vlan` for both directions). | `120` |

### `seshat.schema_version`

| Field | Type | Origin | Req | Datasets | Description | Example |
|---|---|---|---|---|---|---|
| `seshat.schema_version` | keyword | seshat | Y | all | Schema version in `MAJOR.MINOR` form (see README, versioning rule). Present on every document. | `1.0` |

### `seshat.source.*`

| Field | Type | Origin | Req | Datasets | Description | Example |
|---|---|---|---|---|---|---|
| `seshat.source.listener` | keyword | seshat | C | trap, syslog, flow, tracker | Name of the listener (or poller, for tracker documents) that received the data. | `syslog-udp-default` |
| `seshat.source.input` | keyword | seshat | C | trap, syslog, flow, tracker, metric | Input family: `snmp`, `syslog`, `flow`, `telemetry`, `poller`, `edge`. | `syslog` |
| `seshat.source.protocol` | keyword | seshat | O | trap, syslog, flow, metric | Transport the datagram or stream arrived on: `udp`, `tcp`, `tls`, `grpc`. | `udp` |
| `seshat.source.ip` | ip | seshat | O | trap, syslog, flow, metric | Sender address as received by the listener (after edge forwarding: the original sender, not the edge). | `192.0.2.11` |
| `seshat.source.port` | long | seshat | O | trap, syslog, flow, metric | Sender port. | `51514` |
| `seshat.source.site` | keyword | seshat | O | trap, syslog, flow, flow_rollup, tracker, metric | Site scope from the listener or the edge. Part of the device identity key, so overlapping address space at different sites never collides. | `example-site-a` |
| `seshat.source.vrf` | keyword | seshat | O | trap, syslog, flow, flow_rollup, tracker, metric | VRF scope from the listener. | `default` |
| `seshat.source.edge` | keyword | seshat | O | trap, syslog, flow, flow_rollup, tracker, metric | Identity of the Seshat Edge that forwarded the message. Absent for directly received data. | `edge-a1` |

### `seshat.device.*`

| Field | Type | Origin | Req | Datasets | Description | Example |
|---|---|---|---|---|---|---|
| `seshat.device.status` | keyword | seshat | Y | all | `known`, `unknown` or `stale`. Unknown senders still produce full events. | `known` |
| `seshat.device.id` | keyword | seshat | C | all | Stable device id from the device KB. | `dev-0003` |
| `seshat.device.name` | keyword | seshat | O | all | Device name (inventory name, else sysName). | `switch3.example.com` |
| `seshat.device.vendor` | keyword | seshat | O | all | Vendor from inventory or pack classification. | `Example Vendor` |
| `seshat.device.model` | keyword | seshat | O | all | Hardware model. | `EX-3000-48P` |
| `seshat.device.os` | keyword | seshat | O | all | Operating system family. | `ExampleOS` |
| `seshat.device.os_version` | keyword | seshat | O | all | Operating system version. | `4.2.1` |
| `seshat.device.serial` | keyword | seshat | O | all | Chassis serial number. | `EXSN0000003` |
| `seshat.device.site` | keyword | seshat | O | all | Site from inventory. | `example-site-a` |
| `seshat.device.role` | keyword | seshat | O | all | Role from inventory (`access-switch`, `core-router`, `firewall`, ...). | `access-switch` |
| `seshat.device.tenant` | keyword | seshat | O | all | Tenant from inventory. | `example-tenant` |
| `seshat.device.tags` | keyword[] | seshat | O | all | Inventory tags. | `["idf", "poe"]` |
| `seshat.device.pack` | keyword | seshat | O | all | Vendor pack (id@version) that classified the device. | `example-vendor@1.0.0` |
| `seshat.device.custom` | flattened | seshat | O | all | Inventory custom fields, stored flattened so any inventory schema fits. | `{"rack": "R3"}` |
| `seshat.device.first_seen` | date | seshat | O | all | When the KB first saw the device. | `2026-09-01T08:00:00.000Z` |
| `seshat.device.last_seen` | date | seshat | O | all | When the KB last heard from the device. | `2026-10-12T14:03:07.412Z` |
| `seshat.device.interface.name` | keyword | seshat | O | trap, syslog, flow, flow_rollup, tracker, metric | Interface name resolved from the KB (ifIndex to ifName). Traps: the interface the notification is about. Tracker: the port the endpoint was seen on. | `GigabitEthernet1/0/14` |
| `seshat.device.interface.index` | long | seshat | O | trap, syslog, flow, flow_rollup, tracker, metric | ifIndex as sent by the device. | `10114` |
| `seshat.device.interface.alias` | keyword | seshat | O | trap, syslog, flow, flow_rollup, tracker, metric | ifAlias (operator description) from the KB. | `Room 214 jack J-214` |
| `seshat.device.sys_name` | keyword | seshat | O | device | SNMPv2-MIB sysName. | `switch3` |
| `seshat.device.sys_object_id` | keyword | seshat | O | device | SNMPv2-MIB sysObjectID. | `1.3.6.1.4.1.32473.1.3` |
| `seshat.device.engine_id` | keyword | seshat | O | device | SNMP engine ID (hex) registered for SNMPv3 traps. | `80007ed90402000000000003` |
| `seshat.device.exporter_ids` | keyword[] | seshat | O | device | Flow exporter identities (`<ip>/<observation domain>`). | `["192.0.2.11/1"]` |
| `seshat.device.source` | keyword | seshat | Y | device | Where the record came from: `inventory`, `learned`, `dns`, `snmp`, `manual`. | `inventory` |
| `seshat.device.revision` | long | seshat | Y | device | Monotonic revision counter. Device records are appended on every change; the highest revision per `seshat.device.id` is current. | `17` |
| `seshat.device.interfaces` | nested | seshat | O | device | Interface table from IF-MIB/LLDP. Query with `nested` queries. | `[{"index": 10114, "name": "GigabitEthernet1/0/14"}]` |
| `seshat.device.interfaces.index` | long | seshat | O | device | ifIndex. | `10114` |
| `seshat.device.interfaces.name` | keyword | seshat | O | device | ifName. | `GigabitEthernet1/0/14` |
| `seshat.device.interfaces.alias` | keyword | seshat | O | device | ifAlias. | `Room 214 jack J-214` |
| `seshat.device.interfaces.speed_bps` | long | seshat | O | device | Interface speed in bits per second. | `1000000000` |
| `seshat.device.interfaces.type` | keyword | seshat | O | device | IANAifType name. | `ethernetCsmacd` |
| `seshat.device.interfaces.admin_status` | keyword | seshat | O | device | `up`, `down` or `testing`. | `up` |
| `seshat.device.interfaces.oper_status` | keyword | seshat | O | device | `up`, `down`, `testing`, `unknown`, `dormant`, `notPresent`, `lowerLayerDown`. | `up` |
| `seshat.device.provenance` | flattened | seshat | O | device | Per-field provenance: `<field>.source`, `<field>.observed_at`, `<field>.confidence`. | `{"vendor.source": "inventory"}` |

### `seshat.enrichment.*` and `seshat.route.*`

| Field | Type | Origin | Req | Datasets | Description | Example |
|---|---|---|---|---|---|---|
| `seshat.enrichment.level` | keyword | seshat | Y | trap, syslog, flow, flow_rollup, tracker, metric | `none`, `partial` or `full`. | `full` |
| `seshat.enrichment.sources` | keyword[] | seshat | O | trap, syslog, flow, flow_rollup, tracker, metric | Which KB sources contributed (`inventory`, `dns`, `snmp`, `pack`). | `["inventory", "pack"]` |
| `seshat.enrichment.kb_observed_at` | date | seshat | O | trap, syslog, flow, flow_rollup, tracker, metric | Age of the KB record used: when its newest contributing fact was observed. | `2026-10-12T13:55:00.000Z` |
| `seshat.enrichment.backfilled` | boolean | seshat | O | trap, syslog, flow, flow_rollup, tracker, metric | True on documents re-emitted by the backfill script after a device became known. | `false` |
| `seshat.route.matched` | keyword[] | seshat | O | trap, syslog, flow, flow_rollup, tracker, metric | Ids of the routes that matched. Debug aid; present only where a destination's field filter keeps it. | `["route-all-traps"]` |
| `seshat.route.destinations` | keyword[] | seshat | O | trap, syslog, flow, flow_rollup, tracker, metric | Ids of the destinations the event was copied to. | `["dest-logstash"]` |

### `seshat.trap.*`

| Field | Type | Origin | Req | Datasets | Description | Example |
|---|---|---|---|---|---|---|
| `seshat.trap.oid` | keyword | seshat | Y | trap | Notification OID (snmpTrapOID.0), dotted. For SNMPv1 traps, the RFC 3584 translation (enterprise + `.0.` + specific, or the generic trap OID). | `1.3.6.1.6.3.1.1.5.3` |
| `seshat.trap.name` | keyword | seshat | O | trap | Notification name from the MIB. Absent when untranslated. | `linkDown` |
| `seshat.trap.mib` | keyword | seshat | O | trap | MIB module that defines the notification. | `IF-MIB` |
| `seshat.trap.enterprise` | keyword | seshat | O | trap | Enterprise OID (v1 `enterprise`, v2 `snmpTrapEnterprise.0` when present, otherwise the OID's enterprise prefix). | `1.3.6.1.6.3.1.1.5` |
| `seshat.trap.description` | text | seshat | O | trap | The notification's `DESCRIPTION` from the MIB (public text only; vendor packs may omit it). | `A linkDown trap signifies that the SNMP entity ... has detected the ifOperStatus object ... is about to enter the down state.` |
| `seshat.trap.version` | keyword | seshat | Y | trap | Wire version: `v1`, `v2c`, `v3`. | `v2c` |
| `seshat.trap.pdu_type` | keyword | seshat | Y | trap | `trap` or `inform`. | `trap` |
| `seshat.trap.translated` | boolean | seshat | Y | trap | False when no loaded MIB or pack could name the notification (it appears in the unknown inbox). | `true` |
| `seshat.trap.agent_address` | ip | seshat | O | trap | SNMPv1 `agent-addr` or `snmpTrapAddress.0`; the originating agent when different from the datagram source. | `192.0.2.11` |
| `seshat.trap.uptime_ticks` | long | seshat | O | trap | `sysUpTime.0` in hundredths of a second. | `812345600` |
| `seshat.trap.generic_type` | long | seshat | O | trap | SNMPv1 generic-trap number (0-6), v1 only. | `2` |
| `seshat.trap.specific_type` | long | seshat | O | trap | SNMPv1 specific-trap number, v1 only. | `0` |
| `seshat.trap.engine_id` | keyword | seshat | O | trap | SNMPv3 authoritative engine ID (hex). | `80007ed90402000000000003` |
| `seshat.trap.context_name` | keyword | seshat | O | trap | SNMPv3 context name. | `example-context` |
| `seshat.trap.security_name` | keyword | seshat | O | trap | SNMPv3 USM user name. SNMPv1/v2c community strings are never emitted anywhere in the schema. | `trapuser` |
| `seshat.trap.varbinds` | nested | seshat | O | trap | Variable bindings after `sysUpTime.0` and `snmpTrapOID.0`, in wire order. Each element has `oid`, `name`, `type`, `value`, `raw`. Query with `nested` queries. | `[{"oid": "1.3.6.1.2.1.2.2.1.1.10114", ...}]` |
| `seshat.trap.varbinds.oid` | keyword | seshat | Y | trap | Full instance OID, dotted. | `1.3.6.1.2.1.2.2.1.8.10114` |
| `seshat.trap.varbinds.name` | keyword | seshat | O | trap | Symbolic name with instance suffix when the MIB resolves it. | `ifOperStatus.10114` |
| `seshat.trap.varbinds.type` | keyword | seshat | Y | trap | SMI/ASN.1 type: `Integer32`, `Unsigned32`, `Gauge32`, `Counter32`, `Counter64`, `TimeTicks`, `IpAddress`, `OctetString`, `ObjectIdentifier`, `Opaque`, `Null`, `BITS`. | `Integer32` |
| `seshat.trap.varbinds.value` | keyword | seshat | Y | trap | Value rendered through the MIB's textual convention (enum label, MAC as `aa:bb:...`, DateAndTime as ISO 8601, DisplayString as text). Always a string. | `down` |
| `seshat.trap.varbinds.raw` | keyword | seshat | O | trap | Value as received, hex with `0x` prefix. Not indexed (`index: false`), kept in `_source`. | `0x02` |
| `seshat.trap.vars` | flattened | seshat | O | trap | Convenience map of varbind name (instance suffix removed) to rendered value, for vendor-specific varbinds that do not need `nested` queries. Last value wins on duplicate names. | `{"ifOperStatus": "down"}` |

### `seshat.syslog.*`

| Field | Type | Origin | Req | Datasets | Description | Example |
|---|---|---|---|---|---|---|
| `seshat.syslog.format` | keyword | seshat | Y | syslog | Wire format that parsed: `rfc5424`, `rfc3164`, `cef`, `leef`, `other`. | `rfc5424` |
| `seshat.syslog.priority` | long | seshat | Y | syslog | PRI value. | `165` |
| `seshat.syslog.facility.code` | long | seshat | Y | syslog | Facility number 0-23. | `20` |
| `seshat.syslog.facility.name` | keyword | seshat | Y | syslog | Facility name (RFC 5424 table 1). | `local4` |
| `seshat.syslog.severity.code` | long | seshat | Y | syslog | Severity number 0-7. | `5` |
| `seshat.syslog.severity.name` | keyword | seshat | Y | syslog | Severity name (RFC 5424 table 2). | `notice` |
| `seshat.syslog.version` | long | seshat | O | syslog | RFC 5424 VERSION (1). Absent for RFC 3164. | `1` |
| `seshat.syslog.hostname` | keyword | seshat | O | syslog | HOSTNAME as written in the header (may differ from `host.name`). | `switch3.example.com` |
| `seshat.syslog.appname` | keyword | seshat | O | syslog | RFC 5424 APP-NAME, or the RFC 3164 TAG without the PID. | `sshd` |
| `seshat.syslog.procid` | keyword | seshat | O | syslog | RFC 5424 PROCID (or the RFC 3164 PID). | `2411` |
| `seshat.syslog.msgid` | keyword | seshat | O | syslog | RFC 5424 MSGID. | `ID47` |
| `seshat.syslog.sd` | flattened | seshat | O | syslog | STRUCTURED-DATA as `<SD-ID>.<PARAM>` to value. Flattened because SD-IDs are open-ended. | `{"exampleSDID@32473.iut": "3"}` |
| `seshat.syslog.extension` | flattened | seshat | O | syslog | Key/value pairs a pack parser or CEF/LEEF extension extracted, stored flattened (vendor-specific by nature). | `{"cs1": "policy-7"}` |
| `seshat.syslog.parser` | keyword | seshat | O | syslog | Pack parser that matched (`<pack>/<parser>`). Absent when no parser matched (the line is clustered in the unknown inbox). | `builtin/rfc5424` |
| `seshat.syslog.template_id` | keyword | seshat | O | syslog | Hash of the message with digits, hex and addresses masked; identical for messages of the same shape. | `t-9f2c41ab` |

### `seshat.flow.*`

| Field | Type | Origin | Req | Datasets | Description | Example |
|---|---|---|---|---|---|---|
| `seshat.flow.version` | keyword | seshat | Y | flow | `netflow5`, `netflow9`, `ipfix`, `sflow5`, `jflow`, `netstream`, `nsel`. | `ipfix` |
| `seshat.flow.exporter` | ip | seshat | C | flow, flow_rollup | Exporter address (IPFIX exporter / NetFlow source / sFlow agent address). | `192.0.2.11` |
| `seshat.flow.domain` | long | seshat | O | flow | Observation domain id (IPFIX), source id (NetFlow v9), engine (v5) or sub-agent id (sFlow). | `1` |
| `seshat.flow.template` | long | seshat | O | flow | Template id used to decode the record (NetFlow v9 / IPFIX). | `256` |
| `seshat.flow.sampling_rate` | long | seshat | Y | flow | 1-in-N sampling rate applied by the exporter; 1 when unsampled. | `100` |
| `seshat.flow.scaled` | boolean | seshat | Y | flow | True when `network.bytes`/`network.packets` were multiplied by `sampling_rate`. | `true` |
| `seshat.flow.bytes_raw` | long | seshat | O | flow | Byte count exactly as exported (unscaled). | `18432` |
| `seshat.flow.packets_raw` | long | seshat | O | flow | Packet count exactly as exported (unscaled). | `120` |
| `seshat.flow.tcp_flags` | long | seshat | O | flow | TCP control bits (IPFIX tcpControlBits): FIN 1, SYN 2, RST 4, PSH 8, ACK 16, URG 32, ECE 64, CWR 128, NS 256. For sampled exporters this is the OR of sampled packets. | `27` |
| `seshat.flow.tcp_flags_names` | keyword[] | seshat | O | flow | Names of the bits set in `tcp_flags`. | `["FIN", "SYN", "PSH", "ACK"]` |
| `seshat.flow.tos` | long | seshat | O | flow | IP type of service byte (DSCP << 2 \| ECN). | `0` |
| `seshat.flow.dscp` | long | seshat | O | flow | DSCP value (0-63) derived from `tos`. | `0` |
| `seshat.flow.input_ifindex` | long | seshat | O | flow | Ingress interface index as exported (SNMP ifIndex). | `10114` |
| `seshat.flow.output_ifindex` | long | seshat | O | flow | Egress interface index as exported. | `10101` |
| `seshat.flow.input_ifname` | keyword | seshat | O | flow | Ingress interface name resolved from the device KB. | `GigabitEthernet1/0/14` |
| `seshat.flow.output_ifname` | keyword | seshat | O | flow | Egress interface name resolved from the device KB. | `GigabitEthernet1/0/1` |
| `seshat.flow.next_hop` | ip | seshat | O | flow | Next-hop router address. | `192.0.2.1` |
| `seshat.flow.src_mask` | long | seshat | O | flow | Source prefix length. | `24` |
| `seshat.flow.dst_mask` | long | seshat | O | flow | Destination prefix length. | `24` |
| `seshat.flow.src_vlan` | long | seshat | O | flow | Source VLAN id. | `120` |
| `seshat.flow.dst_vlan` | long | seshat | O | flow | Destination VLAN id. | `30` |
| `seshat.flow.icmp_type` | long | seshat | O | flow | ICMP type (ICMP flows). | `8` |
| `seshat.flow.icmp_code` | long | seshat | O | flow | ICMP code (ICMP flows). | `0` |
| `seshat.flow.end_reason` | keyword | seshat | O | flow | IPFIX flowEndReason: `idle-timeout`, `active-timeout`, `end-of-flow`, `forced-end`, `lack-of-resources`. | `end-of-flow` |
| `seshat.flow.ie` | flattened | seshat | O | flow | Vendor/enterprise information elements without a first-class field, keyed `<pen>.<ie-name or id>`. Populated through pack dictionaries; unknown IEs appear in the unknown inbox. | `{"32473.exampleIe": "7"}` |
| `seshat.flow.id` | keyword | seshat | O | flow | Exporter-assigned flow id (IPFIX flowId), as a string. | `81237422` |
| `seshat.flow.firewall_event` | keyword | seshat | O | flow | Firewall event code or label as exported (IPFIX firewallEvent, NSEL NF_F_FW_EVENT) when a pack dictionary maps it; the label also drives `event.action` for NSEL. | `flow-created` |
| `seshat.flow.firewall_ext_event` | long | seshat | O | flow | Extended firewall event code (NSEL NF_F_FW_EXT_EVENT). | `1001` |
| `seshat.flow.nat_event` | keyword | seshat | O | flow | NAT event code (IPFIX natEvent). | `1` |
| `seshat.flow.vrf` | keyword | seshat | O | flow | VRF name exported with the flow (IPFIX VRFname). | `example-vrf` |
| `seshat.flow.ingress_vrf_id` | long | seshat | O | flow | Ingress VRF id (IPFIX ingressVRFID). | `100` |
| `seshat.flow.egress_vrf_id` | long | seshat | O | flow | Egress VRF id (IPFIX egressVRFID). | `100` |
| `seshat.flow.observed_at` | date | seshat | O | flow | Observation time of the record when the exporter reports one (IPFIX observationTimeMilliseconds). | `2026-10-12T14:03:05.000Z` |
| `seshat.flow.application.category` | keyword | seshat | O | flow | Application category name from the exporter (Cisco AVC). | `web` |
| `seshat.flow.application.subcategory` | keyword | seshat | O | flow | Application sub-category name from the exporter. | `example-sub` |
| `seshat.flow.application.group` | keyword | seshat | O | flow | Application group name from the exporter. | `example-group` |

### `seshat.rollup.*`

| Field | Type | Origin | Req | Datasets | Description | Example |
|---|---|---|---|---|---|---|
| `seshat.rollup.kind` | keyword | seshat | Y | flow_rollup | `top_talker`, `interface`, `application`. | `top_talker` |
| `seshat.rollup.interval_seconds` | long | seshat | Y | flow_rollup | Window length in seconds (default 60). | `60` |
| `seshat.rollup.flows` | long | seshat | Y | flow_rollup | Number of flow records aggregated into the document. | `1342` |
| `seshat.rollup.rank` | long | seshat | O | flow_rollup | Rank within the window for ranked kinds (1 = largest). | `1` |
| `seshat.rollup.top_n` | long | seshat | O | flow_rollup | N of the top-N cut-off that produced the document. | `10` |
| `seshat.rollup.if_index` | long | seshat | O | flow_rollup | Interface index (`interface` roll-ups). | `10114` |
| `seshat.rollup.if_name` | keyword | seshat | O | flow_rollup | Interface name (`interface` roll-ups). | `GigabitEthernet1/0/14` |
| `seshat.rollup.direction` | keyword | seshat | O | flow_rollup | `ingress` or `egress` (`interface` roll-ups). | `ingress` |
| `seshat.rollup.other` | boolean | seshat | O | flow_rollup | True on the single document that sums every key beyond the top-N cut-off (the cardinality cap); it carries no key fields. | `false` |

### `seshat.metric.*`

| Field | Type | Origin | Req | Datasets | Description | Example |
|---|---|---|---|---|---|---|
| `seshat.metric.path` | keyword | seshat | Y | metric | YANG path of the sample with list keys, in gNMI path syntax. Slashes inside key values are kept. | `/interfaces/interface[name=Ethernet1/1]/state/counters/in-octets` |
| `seshat.metric.name` | keyword | seshat | Y | metric | The leaf name: the last path element. | `in-octets` |
| `seshat.metric.value` | double | seshat | O | metric | The sample. A JSON number for numeric leaves (integers keep full precision in `_source`), a string or a boolean for the other types; non-numeric values are not indexed here (the mapping ignores malformed values) and are searchable in `value_string`. Absent on delete events. | `1843200` |
| `seshat.metric.value_type` | keyword | seshat | Y | metric | `int64`, `uint64`, `double`, `string`, `bool` or `delete` (the path was deleted on the device). | `uint64` |
| `seshat.metric.value_string` | keyword | seshat | O | metric | String form of non-numeric values (`string`, `bool`), so they stay searchable. | `UP` |
| `seshat.metric.labels` | flattened | seshat | O | metric | List keys of the path flattened to label names (`interface`, `neighbor`, ...). A single-key list element contributes its element name; multi-key elements contribute `<element>_<key>`. | `{"interface": "Ethernet1/1"}` |
| `seshat.metric.source` | keyword | seshat | Y | metric | Which telemetry adapter produced the sample: `gnmi`, `mdt` (Cisco model-driven telemetry) or `jti` (Juniper). | `gnmi` |
| `seshat.metric.subscription` | keyword | seshat | O | metric | Subscription (MDT) or sensor/subscription name as the device reports it, when it does. | `sub-interfaces` |

### `seshat.tracker.*`

| Field | Type | Origin | Req | Datasets | Description | Example |
|---|---|---|---|---|---|---|
| `seshat.tracker.fact` | keyword | seshat | Y | tracker | Which fact family the document carries: `location`, `l3`, `wireless`, `user`. | `location` |
| `seshat.tracker.source` | keyword | seshat | Y | tracker | How the fact was learned: `poll-fdb`, `poll-arp`, `poll-wireless`, `poll-subscriber`, `trap`, `dhcp`, `radius`, `ad`, `flow`, `api`, `inventory`, `dns`, `oui`, `fingerprint`. | `trap` |
| `seshat.tracker.observed_at` | date | seshat | Y | tracker | When the fact was observed (not when it was indexed). | `2026-10-12T14:03:06.000Z` |
| `seshat.tracker.first_seen` | date | seshat | O | tracker | Interval start (interval events). | `2026-10-12T09:41:00.000Z` |
| `seshat.tracker.last_seen` | date | seshat | O | tracker | Interval end or last confirmation (interval events). | `2026-10-12T14:03:06.000Z` |
| `seshat.tracker.interval_id` | keyword | seshat | O | tracker | Stable id of the interval this document opens, extends or closes. | `iv-loc-000417` |
| `seshat.tracker.confidence` | double | seshat | O | tracker | Confidence 0.0-1.0 assigned by the collector or the pack. | `0.9` |
| `seshat.tracker.mac` | keyword | seshat | O | tracker | Tracked endpoint MAC (lowercase, colon-separated). | `02:00:5e:20:00:07` |
| `seshat.tracker.ip` | ip | seshat | O | tracker | Tracked endpoint IP. | `192.0.2.57` |
| `seshat.tracker.vrf` | keyword | seshat | O | tracker | VRF of the IP fact. | `default` |
| `seshat.tracker.hostname` | keyword | seshat | O | tracker | Hostname from DHCP/DNS. | `laptop-17.example.com` |
| `seshat.tracker.user` | keyword | seshat | O | tracker | User from RADIUS/AD. | `jdoe` |
| `seshat.tracker.oui_vendor` | keyword | seshat | O | tracker | Vendor from the IEEE OUI registry. | `Example NIC Maker` |
| `seshat.tracker.device_type` | keyword | seshat | O | tracker | Device type from the DHCP fingerprint. | `laptop` |
| `seshat.tracker.randomized_mac` | boolean | seshat | O | tracker | True when the locally-administered bit (0x02 in the first octet) is set. Synthetic `02:00:5e:...` documentation MACs have it set by construction, so the examples show `true`. | `true` |
| `seshat.tracker.lease_expires` | date | seshat | O | tracker | DHCP lease expiry (`l3` facts). | `2026-10-12T20:03:06.000Z` |
| `seshat.tracker.gateway` | ip | seshat | O | tracker | Default gateway (`l3` facts). | `192.0.2.1` |
| `seshat.tracker.watch.id` | long | seshat | O | tracker | Id of the watch-list entry that matched (`watch.hit` events). | `7` |
| `seshat.tracker.watch.kind` | keyword | seshat | O | tracker | Kind of the matching watch entry: `mac`, `ip`, `user`, `hostname`, `vendor-prefix` (`watch.hit` events). | `mac` |
| `seshat.tracker.watch.value` | keyword | seshat | O | tracker | Value of the matching watch entry (`watch.hit` events). | `02:00:5e:20:00:07` |
| `seshat.tracker.watch.label` | keyword | seshat | O | tracker | Operator label of the matching watch entry (`watch.hit` events). | `lost laptop` |
| `seshat.tracker.watch.reason` | keyword | seshat | O | tracker | Why the entry fired: `appeared` (new MAC), `moved` (new location), `seen` (first fact after a quiet period) (`watch.hit` events). | `moved` |
| `seshat.tracker.location.site` | keyword | seshat | O | tracker | Site of the switch or AP. | `example-site-a` |
| `seshat.tracker.location.device` | keyword | seshat | O | tracker | Switch/AP name. | `Example Switch 3` |
| `seshat.tracker.location.port` | keyword | seshat | O | tracker | Port name (ifName). | `GigabitEthernet1/0/14` |
| `seshat.tracker.location.ifindex` | long | seshat | O | tracker | Port ifIndex. | `10114` |
| `seshat.tracker.location.vlan` | long | seshat | O | tracker | VLAN id. | `120` |
| `seshat.tracker.location.ap` | keyword | seshat | O | tracker | Access point name (`wireless` facts). | `Example AP 12` |
| `seshat.tracker.location.ssid` | keyword | seshat | O | tracker | SSID (`wireless` facts). | `Example-Guest` |
| `seshat.tracker.location.band` | keyword | seshat | O | tracker | Radio band: `2.4`, `5`, `6`. | `5` |
| `seshat.tracker.location.rssi` | long | seshat | O | tracker | RSSI in dBm. | `-61` |
| `seshat.tracker.location.channel` | long | seshat | O | tracker | Radio channel (`wireless` facts). | `36` |
| `seshat.tracker.location.circuit_id` | keyword | seshat | O | tracker | Access-network circuit id (circuit locations: cable modem index, ONT, PPPoE agent circuit or NAS port, DHCP option 82 circuit-id). | `cm14` |
| `seshat.tracker.location.remote_id` | keyword | seshat | O | tracker | Remote id of the circuit (DHCP option 82 remote-id, PPPoE agent remote id). | `line-1042` |
| `seshat.tracker.location.circuit_kind` | keyword | seshat | O | tracker | Access technology of the circuit: `cable-modem`, `ont`, `pppoe`, `dhcp-option82`. | `cable-modem` |
| `seshat.tracker.location.trace` | keyword[] | seshat | O | tracker | Inventory trace labels, port outwards: port description, patch panel, jack, room. | `["Panel P2/14", "Jack J-214", "Room 214"]` |
## Value tables

### Syslog facility (RFC 5424, table 1)

| Code | Name | Code | Name | Code | Name |
|---|---|---|---|---|---|
| 0 | `kern` | 8 | `uucp` | 16 | `local0` |
| 1 | `user` | 9 | `cron` | 17 | `local1` |
| 2 | `mail` | 10 | `authpriv` | 18 | `local2` |
| 3 | `daemon` | 11 | `ftp` | 19 | `local3` |
| 4 | `auth` | 12 | `ntp` | 20 | `local4` |
| 5 | `syslog` | 13 | `security` | 21 | `local5` |
| 6 | `lpr` | 14 | `console` | 22 | `local6` |
| 7 | `news` | 15 | `solaris-cron` | 23 | `local7` |

### Syslog severity (RFC 5424, table 2)

| Code | Name | Code | Name |
|---|---|---|---|
| 0 | `emergency` | 4 | `warning` |
| 1 | `alert` | 5 | `notice` |
| 2 | `critical` | 6 | `informational` |
| 3 | `error` | 7 | `debug` |

`log.level` is the lowercase severity name. `PRI = facility * 8 + severity` (0-191).

### TCP control bits (`seshat.flow.tcp_flags`)

| Bit value | Name | Bit value | Name |
|---|---|---|---|
| 1 | `FIN` | 16 | `ACK` |
| 2 | `SYN` | 32 | `URG` |
| 4 | `RST` | 64 | `ECE` |
| 8 | `PSH` | 128 | `CWR` |
| | | 256 | `NS` |

### Protocols (`network.transport`, `network.iana_number`)

Names are the lowercase keyword from the IANA Assigned Internet Protocol Numbers registry
(`tcp` = 6, `udp` = 17, `icmp` = 1, `icmp6` = 58, `gre` = 47, `esp` = 50, `sctp` = 132, ...).
Protocols without a keyword set only `network.iana_number`.

### SNMP varbind (`seshat.trap.varbinds[]`)

```json
{ "oid": "1.3.6.1.2.1.2.2.1.8.10114", "name": "ifOperStatus.10114", "type": "Integer32", "value": "down", "raw": "0x02" }
```

`oid` is always present and dotted. `name` is present when a loaded MIB resolves the OID.
`value` is the rendering through the MIB's textual convention (enum label, MAC address, ISO 8601
date-time, display string); without a MIB it is the plain rendering of the type (decimal for
integers, dotted for OIDs, hex for octet strings). `raw` keeps the bytes as received in hex. The
first two varbinds of every v2c/v3 notification (`sysUpTime.0`, `snmpTrapOID.0`) are not repeated
here: they are in `seshat.trap.uptime_ticks` and `seshat.trap.oid`. Use `nested` queries on
`varbinds`, or the flattened `seshat.trap.vars` map for simple lookups.

### Tags set by Seshat

`seshat-unknown-device` (sender not in the KB), `seshat-untranslated` (trap OID not resolved),
`seshat-unparsed` (no syslog parser matched), `seshat-no-pri` (syslog line without a PRI),
`seshat-backfilled` (re-emitted after the device became known).
