# Flow input

Seshat receives NetFlow v5 and v9, IPFIX and sFlow v5 over UDP, decodes them, corrects for
sampling, names the interfaces from the device knowledge base, optionally adds GeoIP and ASN
data from files you supply, and emits one `seshat.flow` event per flow record. It can also emit
one-minute roll-ups (`seshat.flow_rollup`) so you do not have to store the raw flows.

## Ports and settings

| Listener | Environment variable | Default | Notes |
|---|---|---|---|
| NetFlow | `SESHAT_FLOW_NETFLOW_LISTEN` | `:2055` | `off` disables. |
| IPFIX | `SESHAT_FLOW_IPFIX_LISTEN` | `:4739` | `off` disables. |
| sFlow | `SESHAT_FLOW_SFLOW_LISTEN` | `:6343` | `off` disables. |

The three ports are a convention, not a restriction: **every socket recognises every version** by the
first bytes of the datagram (NetFlow v5, v9, IPFIX and sFlow v5 are told apart there), so a device
that insists on exporting IPFIX to 2055 works. Two listeners configured with the same address bind
once. The listener name in `seshat.source.listener` (`netflow-udp-default`, `ipfix-udp-default`,
`sflow-udp-default`) is the socket the datagram arrived on.

Other variables: `SESHAT_GEOIP_CITY_DB`, `SESHAT_GEOIP_ASN_DB` (see [GeoIP and ASN](#geoip-and-asn-bring-your-own)),
`SESHAT_PACKS_DIR` (element dictionaries).

The roles `all`, `collector` and `edge` start the listeners; `console` does not (the API answers
`404 not_running`).

The operator-editable part (allow-list, per-exporter rate limit, per-exporter sampling overrides,
site and VRF, Community ID, roll-ups, listen addresses) lives in **Inputs, Flows** and in
`GET/PUT /api/inputs/flow` (admin to change, operator to read). Everything applies immediately
except the listen addresses, which apply at the next start (`restart_required` is shown meanwhile).
The environment values are the defaults until the settings are saved once.

`/api/ready` reports each enabled listener to an administrator, an operator or the metrics token (anonymous callers get only the verdict).

## Pointing devices at Seshat

Send flows to the host's UDP port. The exporter's **source address** identifies it: it is the key of
the template cache, of the knowledge-base lookup (together with the site and VRF of the input) and
of the per-exporter limits. Behind NAT, give every site its own Seshat or Edge so addresses do not
collide.

To exercise a deployed box without a device, use the generator:

    seshat-gen flows --version 9     --target HOST:2055 --rate 5000 --count 100000
    seshat-gen flows --version ipfix --target HOST:4739 --rate 5000 --count 100000 --sampling 100
    seshat-gen flows --version sflow --target HOST:6343 --rate 5000 --count 100000
    seshat-gen flows --version 5     --target HOST:2055 --count 1000

It sends synthetic records from documentation addresses, including (for v9 and IPFIX) an options
template that announces the `--sampling` rate and, for sFlow, counter samples.

## What is decoded

| Format | Notes |
|---|---|
| NetFlow v5 | Fixed layout. `seshat.flow.domain` = engine type and id. The header's sampling mode and interval are honoured. Times come from the router's uptime clock. |
| NetFlow v9 | Templates and options templates; scope fields are skipped, the options data feeds sampling. `seshat.flow.domain` = source id. |
| IPFIX | Templates, options templates, template withdrawal, enterprise-specific elements, variable-length elements (short and long length forms), reduced-size encoding of counters, reverse-direction (PEN 29305) byte and packet counts for bidirectional flows. `seshat.flow.domain` = observation domain id. |
| sFlow v5 | Flow samples (compact and expanded) with raw packet headers (Ethernet with 802.1Q tags, bare IPv4 or IPv6), plain IPv4/IPv6 sample records, and the extended switch, router and gateway records. `seshat.flow.domain` = sub-agent id and `seshat.flow.exporter` = the agent address in the datagram. **Counter samples** do not become events: they are counted (`seshat_flow_counter_samples_total`) and the latest generic interface counters per exporter are kept (shown with the exporter in `GET /api/inputs/flow`). |

NetFlow v5/v9 and IPFIX are decoded by Seshat's own code, sFlow by the `decoders/sflow` package of
[goflow2](https://github.com/netsampler/goflow2) (BSD-3-Clause) plus a header parser of our own.
goflow2's `decoders/netflow` package can be driven without its pipeline, and were
benchmarked for NetFlow and IPFIX too. They were not used for those two: decoding one NetFlow v9 datagram of 24
records with 12 fields takes about 38 microseconds and 329 allocations with goflow2 (it decodes every
field into an interface value) against about 5 microseconds and one allocation with Seshat's decoder,
which matters at 200k records/s; and their template store is a structure that cannot be persisted or
re-resolved against a changed dictionary. The wire formats are small and fully covered by the tests.

### Vendor notes

* **J-Flow** is NetFlow v9 (or IPFIX) from Juniper devices. There is no special code. When the
  knowledge base classifies the exporter's vendor as Juniper, `seshat.flow.version` reads `jflow`
  instead of `netflow9`/`ipfix`.
* **NetStream** (Huawei and others) is a NetFlow v9 variant that uses the standard element ids; the
  same rule labels it `netstream` for a Huawei exporter. Seshat ships no Huawei pack. If a NetStream
  device sends vendor-specific ids, they show up in **Inbox, Unknown IEs** and you describe them with a
  `flows/*.yaml` dictionary in a pack of your own (the vendor pack format).
* **ASA NSEL** is NetFlow v9 with Cisco's firewall event elements (ids 33000 and above, 40000 to
  40005). They are described by `packs/cisco/flows/cisco-nsel.yaml`. These ids cannot collide with the
  IANA registry, so they are applied to any exporter that sends them. An NSEL record becomes a
  `seshat.flow` event with `event.category: network`, `event.action` `flow-created`, `flow-denied`,
  `flow-deleted`, `flow-alert` or `flow-update`, `event.type` `start` / `denied` / `end`,
  `event.outcome: failure` for a denied flow, `seshat.flow.version: nsel`, the initiator and responder
  octets in `source.bytes` / `destination.bytes`, and the translated addresses and ports in
  `source.nat.*` / `destination.nat.*`. It is routed like every other event: match on
  `event.action` or `seshat.flow.version`.
* **Cisco AVC / NBAR** application names (PEN 9) are mapped by `packs/cisco/flows/cisco-avc.yaml` to
  `seshat.flow.application.*`.

## Templates

NetFlow v9 and IPFIX exporters describe their records in templates. Seshat keeps them **per
exporter, protocol and observation domain**:

* a changed template replaces the old one (same id, new layout); a repeated identical template only
  refreshes its timestamp; IPFIX withdrawals remove it;
* **changed templates are written to the store** (`flow_templates`, JSON, within 10 s) and loaded at
  start, so a restart does not drop flows until the exporter sends its next template (exporters
  repeat templates only every few minutes, or on a timer of 30 minutes or more);
* a data set whose template has not arrived yet cannot be decoded. It is counted in
  `seshat_flow_records_dropped_total{reason="no_template"}` (per data set; the number of records in it is
  unknowable without the template) and is not guessed at;
* template state is **bounded at every level**, so neither one sender nor a crowd of spoofed ones can
  grow memory without bound (see [Resource bounds](#resource-bounds)). Eviction is least recently used
  and counted in `seshat_flow_evicted_total`. An exporter idle for 24 h is forgotten (its persisted
  templates stay until the flow-template retention removes them, default 30 days; a live exporter's
  rows are re-stamped daily).
  Use the allow-list to refuse unknown senders outright.

`GET /api/inputs/flow/templates[?exporter=ADDR]` lists them with the element names the dictionaries
give, the number of records decoded with each and how many of their elements are unknown.

## Sampling

Many exporters count only 1 packet in N. Seshat finds N, in this order:

1. the **per-exporter override** you set (Inputs, Flows; or `exporters` in the settings API). It wins
   because some devices sample without announcing it, or announce a wrong value;
2. the record itself (`samplingInterval` or `samplerRandomInterval` inside the data record) or its
   sampler id looked up in the options data;
3. the packet header (NetFlow v5 sampling interval) and, for sFlow, the rate in each sample;
4. the exporter's options template data: `samplingInterval` (34), `samplerRandomInterval` (50),
   `samplingPacketInterval` and `samplingPacketSpace` (305, 306; rate = (interval + space) / interval),
   per sampler id (48, 302) with the latest value as the exporter default;
5. otherwise 1.

When the rate is above 1, `network.bytes`, `network.packets`, `source.bytes`, `destination.bytes` and
the packet counts are multiplied by it, `seshat.flow.scaled` is `true`, `seshat.flow.sampling_rate` holds
N, and the numbers exactly as exported are kept in `seshat.flow.bytes_raw` and `seshat.flow.packets_raw`.
A unidirectional record fills only the side that sent it (`source.bytes`); bidirectional exporters (NSEL,
IPFIX reverse elements) fill both.

## Information elements and the unknown inbox

What an element means comes from dictionaries: a built-in core of the IANA elements the decoder needs,
overridden and extended by `<packs>/*/flows/*.yaml`, keyed by enterprise number (PEN) and id
(vendor pack format). A dictionary entry names the element, gives its type and says which event
field it fills; `values` turns codes into labels.

An element **no dictionary describes** is not an error and not dropped:

* its value is carried in `seshat.flow.ie` under `<pen>.<id>` (decimal for up to 8 bytes, `0x` hex above);
* elements that a dictionary names but maps to no field are carried under `<pen>.<name>`;
* it is counted into **Inbox, Unknown IEs** (`flow_unknown_ies`; `GET /api/inbox/unknown-ies`): enterprise
  number, id, how many records carried it, first and last seen, and the first value and exporter as an
  example. Muting hides a row; the values keep flowing.

## Interface names

`seshat.flow.input_ifindex` and `output_ifindex` are the numbers as exported. The enrichment step looks
the exporter up in the device knowledge base and adds `seshat.flow.input_ifname` and `output_ifname`
from its interface table (inventory import or the opt-in SNMP poll; `docs/device-kb.md`). An index the
knowledge base does not know stays a bare number. The same lookup names the interface roll-ups
(`seshat.rollup.if_name`).

## GeoIP and ASN (bring your own)

Set `SESHAT_GEOIP_CITY_DB` and/or `SESHAT_GEOIP_ASN_DB` to MaxMind-format `.mmdb` files you obtained
yourself (a city or country database and an ASN database). **Seshat bundles no data and downloads
none.** They fill `source.geo.*` and `destination.geo.*` (country, city, location) and
`source.as.*` / `destination.as.*` (number, organisation). A BGP AS number the exporter itself reports is kept;
the database adds the organisation name. Private, loopback and link-local addresses are not looked up.

The files are checked every 30 s and reloaded when their modification time changes, with no restart; a
missing or corrupt file is reported on the Flows page and flows continue without it. Lookups happen when
the event is built, so the cost (about a microsecond per address and database) falls on the event
workers, not on the receive path.

## Roll-ups

With **Emit roll-ups** on (off by default), at every minute boundary each exporter emits documents of
the dataset `seshat.flow_rollup` (`event.kind: metric`, `seshat.rollup.interval_seconds: 60`):

| `seshat.rollup.kind` | Rows | Keys |
|---|---|---|
| `top_talker` | top N by bytes as **source**, and top N as **destination** (`source.ip` or `destination.ip` is set) | rank 1..N |
| `interface` | top N interfaces by bytes **ingress** and N **egress** | `seshat.rollup.if_index`, `if_name`, `direction` |
| `application` | top N transport ports (`network.application` is a well-known name such as `https`, else `tcp/8443`) | rank 1..N |

Every row carries `network.bytes` and `network.packets` (scaled by the sampling rate) and
`seshat.rollup.flows`, the number of flow records it aggregated. **Cardinality is bounded**: beyond the
top N, everything is summed into a single row per kind and side with `seshat.rollup.other: true` and no
key fields, so totals stay correct; and each map is capped at 20 000 keys per exporter and minute
(further new keys count only towards "other"). N is the **Top N** setting (1 to 1000, default 10), so an
exporter emits at most 5 x (N + 1) documents a minute.

Why you may want them: raw flows are the largest data set a collector sees (hundreds of thousands of
records a second from one router is normal) and most dashboards only need "who talks most, on which
interface, with which application". Route `seshat.flow_rollup` to your long-term index and keep
`seshat.flow` on a short retention, or send it only to a security tool, or not at all (a route matching
`dataset = seshat.flow` decides, see `docs/outputs.md`). Roll-ups are computed in Seshat before routing, so
turning them on does not remove raw flows from any destination by itself.

## Resource bounds

Everything a sender controls is bounded, with settings in **Inputs, Flows** (`GET/PUT
/api/inputs/flow`); `0` means the built-in default, never "unlimited":

| Setting | Default | Meaning |
|---|---|---|
| `max_templates_per_exporter` | 512 | templates one exporter may hold (it recycles its own least recently used ones, never anyone else's) |
| (built in) | 8 MiB | estimated memory of one exporter's templates (a 512-field template is about 40 KiB) |
| `max_domains_per_exporter` | 64 | observation domains per exporter; a domain exists only once a template installs into it, the least recently active one is evicted first, and a withdrawn domain is removed |
| `max_template_memory_mb` | 128 | all template state of the process; when full, templates of exporters that never decoded a data record go first (oldest first), then the largest established exporter is trimmed |
| `max_exporters` | 10 000 | exporters tracked; when full the least valuable are recycled first: senders that have not shown sustained valid traffic (least recently active first), then sustained exporters by lowest score, and exporters that are configured or known to the device knowledge base only as a last resort. A real new exporter is always admitted |

An exporter counts as **sustained** after at least 50 datagrams with decodable records spread over at least
5 minutes (one forged datagram earns nothing); the score used to rank sustained exporters is the number
of such datagrams times the seconds they span. Exporters listed under `exporters` (sampling overrides)
or known to the knowledge base are protected from the start. Under memory pressure the same order
applies to templates, and eviction only releases memory: stored rows are never deleted by it.

A datagram that is not NetFlow v5/v9, IPFIX or sFlow v5 creates no exporter. Only exporters that have decoded data records get their templates stored in the database
(`flow_templates`, indexed by update time). Persisted templates are loaded under the same bounds at
start-up (at most 100 000 rows are read; the excess is logged and ignored).

## Limits and metrics

* **Allow-list**: datagrams from other addresses are dropped (`seshat_flow_dropped_total{reason="allow_list"}`).
* **Per-exporter rate limits**: token buckets in datagrams per second (`per_exporter_pps`, default
  10 000) and in **records** per second (`per_exporter_rps`, default 100 000, bucket depth
  `per_exporter_record_burst`, default the rate). Over the limit, datagrams
  (`reason="rate_limit"`) or records (`records_dropped{reason="record_limit"}`) are dropped and
  counted. Never blocks. Real exporters sit far below both defaults (a busy router is a few thousand
  datagrams and tens of thousands of records per second). Set a value to `0` for no limit. **Upgrading:**
  an installation whose saved settings predate `per_exporter_rps` keeps no record limit (a key missing
  from the saved settings means the earlier behaviour, not the new default) until you set one; an
  installation that never saved its flow settings gets the new defaults. The first time the record limits
  drop records of an exporter, Seshat logs one warning naming the exporter and the settings.
* **Records per datagram**: `max_records_per_datagram` (default 4096) caps what one datagram can turn
  into events; the rest of that datagram is dropped and counted (`record_limit`). A template whose
  record could be shorter than 4 bytes is refused (`records_dropped{reason="template_invalid"}`):
  with a one-byte record every byte of a 65 KB datagram would otherwise become an event.
* **Malformed packets never stop the listener.** Every length field in an sFlow sampled header is
  checked against the bytes actually captured (an sFlow sample carries only the first bytes of a
  packet, so a header may legitimately claim more than it holds). A truncated IPv6 extension-header
  chain is decoded as far as it goes (addresses, protocol of the last readable header; ports and flags
  are left unset) and counted in `seshat_flow_truncated_headers_total`. If a decoder ever does fail
  on a datagram, that datagram is dropped, `seshat_input_panics_total{input="flow"}` is incremented
  and one rate-limited error line is logged with the exporter address (the line carries the panic text, at most 200 bytes, but never the datagram); the next
  datagram is processed normally.
* Receive buffer 16 MiB requested (the kernel caps it at `net.core.rmem_max`; raise that sysctl for
  exporters that burst).

| Metric | Labels |
|---|---|
| `seshat_flow_packets_received_total` | `version` (`netflow5`, `netflow9`, `ipfix`, `sflow5`) |
| `seshat_flow_records_total` | `version` |
| `seshat_flow_templates_total` | |
| `seshat_flow_dropped_total` | `reason`: `allow_list`, `rate_limit`, `queue_full`, `unsupported_version`, `decode_error`, `too_many_exporters` (no longer produced: exporters are evicted instead) |
| `seshat_flow_records_dropped_total` | `reason`: `no_template`, `malformed`, `template_limit`, `record_limit`, `template_invalid` |
| `seshat_flow_template_state` | gauge, `kind`: `count`, `bytes` (estimated heap held by templates) |
| `seshat_flow_evicted_total` | `kind`: `exporter`, `template`, `domain` |
| `seshat_flow_unknown_ie_records_total` | |
| `seshat_flow_counter_samples_total` | |
| `seshat_flow_truncated_headers_total` | sFlow sampled headers whose IPv6 extension-header chain ran past the captured bytes |
| `seshat_flow_exporters` | gauge |

## Event fields

See `docs/schema/fields.md` (`seshat.flow.*`, `seshat.rollup.*`, ECS `source.*`, `destination.*`, `network.*`) and
the examples `docs/schema/examples/flow.json` and `flow_rollup.json`. Every event carries `host.ip` (the
exporter), `seshat.source.listener`, `seshat.source.site` and `seshat.source.vrf` when set, and the usual
`seshat.device.*` / `seshat.enrichment.*` from the knowledge base. `network.community_id` (Community ID v1,
TCP, UDP and SCTP; ICMP is left out) can be switched off. `@timestamp` is the flow end time when the
exporter reports a plausible one (within 7 days of now), otherwise the receive time; exporters that report
no times (sFlow, many IPFIX templates) get `event.start` = `event.end` and a zero duration.

The raw datagram is not attached to flow events, so the **raw relay** output (which forwards the original
datagram) does not apply to flows yet.

## Performance

Decoding is ordered per exporter (a template must be seen before its data), building events is spread over
all cores. On a development machine one exporter sending NetFlow v9 over loopback at 200 000 records/s is
received and emitted in full; check your own hardware with a generator of your choice before sizing.
