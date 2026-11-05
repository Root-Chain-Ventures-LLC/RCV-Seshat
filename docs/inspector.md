# Event inspector and enrichment provenance

For any event, one place shows the message **as it was received**, the **enriched document** Seshat
sends to destinations, and **where each enriched value came from**.

* The console page **Inspect** (administrators, operators and viewers) and its API
  `GET /api/inspect/events` and `GET /api/inspect/events/{id}` read the most recent events of each
  input from memory.
* The same provenance travels with the event: `seshat.enrichment.fields` and
  `seshat.enrichment.origins` in every document that carries enrichment, so the data store can answer
  "where did this value come from" without the console. Saved searches for OpenSearch Dashboards and
  Kibana are in `deploy/dashboards`.

## Provenance in the document

```json
"enrichment": {
  "level": "full",
  "sources": ["inventory"],
  "kb_observed_at": "2026-10-12T13:55:00.000Z",
  "fields": {
    "seshat.device.vendor": "kb:inventory:netbox",
    "seshat.device.model": "kb:inventory:netbox",
    "seshat.device.role": "kb:manual",
    "host.name": "kb:dns",
    "event.action": "pack:cisco",
    "seshat.interface.name": "pack:cisco"
  },
  "origins": [
    {"id": "kb:inventory:netbox", "kind": "kb", "name": "netbox", "source": "inventory", "observed_at": "2026-10-12T13:55:00.000Z", "confidence": 0.95},
    {"id": "kb:manual", "kind": "kb", "name": "manual", "source": "manual", "observed_at": "2026-10-12T13:57:10.000Z", "confidence": 1},
    {"id": "kb:dns", "kind": "kb", "name": "dns", "source": "dns", "observed_at": "2026-10-12T13:55:02.000Z", "confidence": 0.5},
    {"id": "pack:cisco", "kind": "pack", "name": "cisco", "version": "0.1.0"}
  ]
}
```

`fields` maps a field, by its dotted path, to the id of the origin that set it. `origins` describes
each id once. `seshat.enrichment.sources` (the source kinds) is unchanged.

| Origin id | `kind` | What it names | Fields it is credited with |
|---|---|---|---|
| `kb:<source>` or `kb:<source>:<connector>` | `kb` | The device record the event's sender matched. `source` is `manual`, `inventory`, `snmp`, `pack`, `learned` or `dns`; for `inventory` the id and `name` carry the connector (`netbox`, `nautobot`, `csv`, `http`; one connector of each kind can be configured, so the connector name is its kind). `observed_at` is when that source last supplied the fields, `confidence` the source's confidence. A second observation of the same source gets a `~1` suffix | `seshat.device.{name,vendor,model,os,os_version,role,tenant,site,tags,pack}`, `seshat.device.name` and `host.name` only when the record's own name or sysName supplied them (a name that falls back to a hostname is not attributed: the record keeps one provenance entry for all its hostnames), the interface name and alias from the record's interface table (`seshat.device.interface.*`, `seshat.flow.input_ifname` and `output_ifname`, `seshat.rollup.if_name`) |
| `pack:<name>` | `pack` | The vendor pack whose syslog grammar matched or whose trap mapping applied, with its manifest `version` | every field the grammar set (`event.action`, `seshat.interface.*`, `cisco.*`, `seshat.syslog.parser`, ...); for a trap, the fields the pack's trap mapping (`traps:` in its mapping files) set, such as `event.action` |
| `mib:<module>` | `mib` | The MIB module that defined the notification, and, per varbind, the module that defined that varbind | `seshat.trap.{name,mib,description,translated}`; `seshat.trap.varbinds[<i>].name` for each named varbind (`i` is its index in `seshat.trap.varbinds`; the first 16 varbinds); `seshat.trap.vars` (a map built from the named varbinds) is attributed to the module of the first one |
| `oui:ieee` | `oui` | The IEEE OUI registry (`source`: `embedded`, `refreshed` or `uploaded`; `version` and `observed_at`: when it was loaded) | `seshat.tracker.oui_vendor` |

Only fields the enrichment set are listed. Values the input parsed straight from the message
(`message`, `log.syslog.*`, the syslog header fields) are the original's own content, not enrichment.
A field that several origins could supply names the one whose value is in the document. A sender the
knowledge base does not know has `level: none` and no `kb:` origin; pack and MIB fields are still
attributed.

The provenance is rendered once per device-record revision, grammar rule (and combination of optional
fields) or MIB module (and combination of varbind modules) and shared by every event that carries it: it
costs a pointer per event and a copy of a few hundred bytes when the document is rendered, and nothing
is marshaled or allocated per event. `seshat.enrichment.origins` is mapped as a flattened field, not
as nested documents.

### Turning it on or off per destination

`format_options.provenance` is `compact` (the document carries `seshat.enrichment.fields` and
`seshat.enrichment.origins`) or `off` (it leaves them out and is otherwise unchanged).
**Destinations created from this release on default to `compact`. Destinations that already exist when
you upgrade keep sending exactly the documents they sent before:** the upgrade (migration 0210) sets
`provenance: off` on each of them once. Switch one on in Destinations ("Enrichment provenance") or by
setting `format_options.provenance` to `compact`; a later upgrade does not change a destination again.
`fields.exclude` can drop the two fields too. The Inspect page always shows provenance, whatever a
destination does, because it reads it from the event.

## The Inspect page

Select **Inspect** in the console. The list shows the newest events of every input; filter by input,
source address (an address or a CIDR prefix), host (host name, device name or syslog hostname), a
text in the message or the original, or an `event.id` pasted from the data store. **Live** refreshes
the list every few seconds. An event has three views:

* **Original**: the message exactly as the listener read it (a line for syslog, the datagram for
  traps), as text, or as a hex dump when it is binary; a toggle shows the hex of a text message.
  Flow records and telemetry samples are built from decoded records and have no single original. An
  SNMPv1/v2c **community string is overwritten with `*`** in the view (and in the per-destination
  rendering); everything else is shown as received. When the input has [passthrough](schema/passthrough.md)
  on and routed, the pane shows **the passthrough record of the message** (the bytes exactly as read,
  which also gives a flow record its datagram, as hex) and the **passthrough id** that joins the two
  (`seshat.source.passthrough_id`, copyable); the inspector keeps the most recent records of each input
  in its own buffer, and when the record has left it the pane falls back to the datagram the event kept,
  then to `event.original`, and still shows the id.
* **Enriched**: the document every destination starts from (ECS JSON, with the branding of this
  installation), or, with "Shown as", the event rendered by one of the destinations the current route
  table sends it to (its format, content and field include/exclude lists). The routes listed are
  evaluated now, not when the event passed.
* **Provenance**: for every enriched field, its value and the origin that set it, then the origins
  with their pack and version, connector, `observed_at` and confidence, linked to the device record,
  the connector settings and the Packs page. It also shows the grammar and template that parsed a
  syslog message.

### What is kept, and what is not

The inspector keeps the last `SESHAT_INSPECT_RING` events of each input (default 500, 0 to 5000, `0`
turns it off) **in memory only**: nothing is written to disk and a restart empties it. A value outside
0 to 5000 stops the start-up with an error naming the variable. Each input has its own ring, so a busy
input never pushes out a quiet one; at most 64 rings exist and any further input name (edge collectors
supply their own) is folded into a ring called `other`. The ring is a tap behind the router: storing an
event is one atomic pointer write, it never blocks the pipeline, and when a ring is full it overwrites
its oldest slot and counts it (`seshat_inspector_overwritten_total{input}`; also
`seshat_inspector_events_total`, `seshat_inspector_buffered` and `seshat_inspector_capacity` in
`/metrics`). In a cluster each node shows what it received.

**Memory.** The ring holds the event, not a rendering of it. An event whose datagram, message or
`event.original` is longer than 8 KiB is stored as a copy that keeps only the first 8 KiB of each (the
view says it was cut), so a large datagram is not pinned. An ordinary event is stored as it is, about 3 to
5 KiB with its document and original. Plan `capacity x inputs x 5 KiB`: the default (500) on the four
usual inputs is about 10 MB. The real worst case at the limits (5000 events x 64 rings) is about 1.6 GB
for ordinary events; it needs 64 distinct input names, which an installation without edge collectors
cannot produce. An oversized line (up to the syslog line limit of 64 KiB) can still keep its other parsed
fields (hostname, application name) alive through the received line: the ceiling per such event is the
line limit, not 8 KiB. Keep `SESHAT_INSPECT_RING` at the default unless you have measured the memory.

**Cost of a search.** A search examines at most 20,000 buffered events (shared between the rings, newest
first; the response says `scan_truncated` when it stopped early), matches text without allocating
(ASCII letters compare without regard to case), and is limited to a few searches per second per caller
(`429 limit_exceeded` with `Retry-After`). A text search covers the message, `event.original` and the
original datagram; for an SNMPv1/v2c message it covers the datagram on both sides of the community string
and never the community, so a search cannot be used to confirm a guess at it.

### Access and audit

Administrators, operators and viewers may use it; the `user` role gets `403` like every other
console route. It is read-only. An API token limited to sites or tenants sees only events from those
sites or tenants (the site is the device's inventory site when the knowledge base has one, else the
site of the listener; an event outside the scope answers `404`), and learns nothing else about the
installation: no routes, no destination names (`destination=` is `403 out_of_scope`) and no ring
statistics. Because an event can show raw log content, **every view of a single event is written to the
audit log** as `inspect.event.view`, with the event id, dataset, input and, when a destination rendering
was asked for, its name (never the content). **A search** (any of `text`, `host`, `source_ip`, `id`,
`dataset`) is audited as `inspect.events.search` with who and the filters (not what was found), once a
minute per caller and search; the plain list the page refreshes is not audited. A destination whose
format numbers its records in a live stream (the edge upstream envelope) cannot be previewed
(`422 not_renderable`), so looking never consumes a sequence number.

## API

`GET /api/inspect/events` takes `input`, `dataset`, `source_ip`, `host`, `text`, `id`, `limit` (1 to
500, default 100) and `cursor` (the `next_cursor` of the previous page). It returns `events` (newest
first), `next_cursor`, `capacity`, `scanned`, `scan_truncated` and per-input `inputs` counters.

`GET /api/inspect/events/{id}` returns `original` (`present`, `encoding` `text` or `hex`, `value`,
`bytes`, `truncated`, `redacted`, `source`), `enriched` (`format`, `content`, `document`), `provenance` (`level`,
`fields` with values and origin ids, `origins` with links, `parser`, `template_id`), `routes` and,
with `destination=<name>`, `rendered`. An id that is not in the ring (or is outside the caller's
scope) is `404 not_found`. Errors use the usual `{"error": {"code", "message"}}` body; the paths are
in `GET /api/openapi.json`.

## Saved searches for Dashboards and Kibana

`deploy/dashboards` holds saved objects (index patterns `logs-seshat.*` and `logs-seshat.device-*`
and four saved searches) for OpenSearch Dashboards 2.x and Kibana 8.x, including "original vs
enriched" (`event.original` beside the enriched fields) and "where enrichment came from". How to
import them is in `deploy/dashboards/README.md` and `docs/outputs.md`.
