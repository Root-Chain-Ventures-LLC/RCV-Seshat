# The passthrough stream (`seshat.passthrough`, version 1)

Contract name `seshat.passthrough`, **version 1**. This document defines the record an input emits when its
**passthrough** switch is on: the original message exactly as the listener read it, with a minimal envelope.
Nothing in it is decoded, classified or enriched, so it can be shipped as fast as Seshat can read and queue it, and
it can be compared with the enriched events of the same message.

```
                       +--> passthrough record (original + envelope) --> routes with stream "passthrough" --> destinations
socket read (listener) |
                       +--> decode -> classify -> enrich --------------> routes with stream "enriched" -----> destinations
```

The two streams are independent. They use separate routes, and each destination has its own queue, so a slow, full
or stopped destination for the enriched stream never delays the passthrough stream, and the reverse. Pointing both
streams at the same destination is allowed; they then share that destination's queue.

## What is taken, and when

The tap sits in each listener's read loop, right after the socket read and the source allow-list, before any rate
limit, decoder, vendor grammar, device lookup or enrichment. It does no network or database work, copies the bytes once
(the decode path reads the same copy) and never blocks the listener.

| Input | One record is | Bytes |
|---|---|---|
| Syslog over UDP | one datagram | the datagram as received, including a trailing CR LF |
| Syslog over TCP and TLS | one message of the stream | the message exactly as it arrived, less the framing delimiter and nothing else: with newline framing the line without its one terminating line feed (a carriage return before it stays), with octet counting the counted bytes (including any trailing line break inside them) |
| SNMP traps and informs | one datagram | the PDU as received, except that the SNMPv1/v2c community string is overwritten (see Security) |
| Flow (NetFlow v5/v9, IPFIX, sFlow) | one datagram, however many flow records it holds | the datagram as received |

- Passthrough is **off by default**, set per input (`passthrough` in the input's settings), and changes take effect
  without a restart. A disabled input pays one atomic read per message.
- The source allow-list applies (a source that is not allowed is never read). The per-source and global rate limits do
  **not** apply to the tap: they protect the decode and enrichment path. Under overload the enriched stream sheds
  first, by its own limits, while the passthrough stream keeps going until one of its own bounds drops.
- **Bounds, applied before anything is allocated for a record**, in this order: (1) no enabled passthrough route has a
  running destination: the tap is idle and the message is not even copied for it (`passthrough.routed` is false);
  (2) every passthrough destination's intake is full: the message is refused and counted as `dropped.full`;
  (3) the input's rate bound, `passthrough_max_eps` (records per second, 0 = 250000, burst a tenth of a second):
  records above it are refused and counted as `dropped.rate`. A refused message simply has no record, and its enriched
  event carries no `passthrough_id`. The counters are `passthrough.dropped` in the input status and
  `seshat_passthrough_dropped_total{input,reason}`.
- A message the decoder cannot read, a PDU of an unknown SNMPv3 sender and a datagram of an unsupported flow version are
  still passed through. Empty messages produce no record.
- Syslog over TCP and TLS is bounded by the input's line limit (64 KiB); a longer message is cut there, in both streams.

## Security

The passthrough stream is the data as it was sent, so it carries what the sender put in it.

- **SNMPv1/v2c community strings** are credentials sent in clear. By default (`passthrough_redact_community`, on) the
  tap overwrites the community octets in the passthrough copy with `*` of the same length: the PDU stays valid BER of
  the same length and still decodes. The enriched event and its raw relay (`raw_relay`, `preserve_source`) are not
  affected and keep forwarding the original datagram, community included: a device that must reach another NMS needs
  its community. Turn the setting off only when the passthrough consumer is as trusted as the network the traps travel.
- **SNMPv3** messages are passed as received. With privacy (authPriv) the scoped PDU is encrypted, but the message
  header is visible: the authoritative engine ID, the user name, the message ids and the security level. Keys and
  passphrases are never on the wire. Messages from unknown senders and discovery messages are included, as are
  datagrams that do not parse as SNMP at all (nothing is inspected, so nothing is trusted).
- **Syslog and flow** data are passed as sent. Syslog messages routinely contain user names, addresses and sometimes
  secrets typed into a command line; the enriched stream has the same content in `event.original`.
- A passthrough destination therefore deserves the access control of the traffic it receives. Relay over TLS
  (`syslog` or `raw_relay` with protocol `tls`) when the path is not private.

## The record

One JSON document per message, in the data stream `logs-seshat.passthrough-<namespace>` (the namespace is the
organisation short name lowercased, as for every other dataset). It follows the common schema
([`fields.md`](fields.md)), restricted to these fields:

| Field | Meaning |
|---|---|
| `@timestamp`, `event.created` | When the listener read the message (UTC, milliseconds). |
| `event.kind` | `event`. |
| `event.dataset`, `data_stream.dataset` | `seshat.passthrough`. |
| `event.module` | `seshat`. |
| `event.id` | Unique id of the record (ULID). **The join key**: enriched events built from the same message carry it in `seshat.source.passthrough_id`. |
| `event.original` | The original message (see Encoding). The field is searchable text in the passthrough index template. |
| `seshat.passthrough.encoding` | `utf8` or `base64`. |
| `seshat.passthrough.bytes` | Length of the original in bytes. |
| `seshat.source.listener`, `.input`, `.protocol` | The listener (for example `syslog-udp-default`), the input family (`syslog`, `snmp` or `flow`) and the transport (`udp`, `tcp`, `tls`). |
| `seshat.source.ip`, `.port` | The sender as seen by the socket. |
| `seshat.source.site`, `.vrf` | The input's scope, when it has one. |
| `seshat.source.edge` | The edge that read the message, when it came through an edge. |
| `observer.*`, `data_stream.*`, `ecs.version`, `seshat.schema_version` | As on every document. |

There is no `host.*`, `message`, `related.*`, `seshat.device.*`, `seshat.enrichment.*` or protocol block, by design.
`seshat.route.*` appears only when a destination's field list asks for it.

### Encoding

`event.original` is a JSON string, so bytes that do not survive JSON are carried as base64:

- `utf8`: `event.original` **is** the original text, unchanged. Used only for syslog messages that are valid UTF-8
  and contain no control characters other than tab, CR and LF.
- `base64`: `event.original` is the standard base64 (RFC 4648, with padding) of the original bytes. Used for every
  trap PDU and flow datagram, and for any syslog message that is not plain text (invalid UTF-8, NUL or other control
  characters). Decoding it gives the original bytes exactly.

This differs on purpose from `event.original` of the enriched stream with destination content `both`, which writes
binary as `0x` followed by hex and does not say so; a passthrough consumer never has to guess.

### Example

```json
{
  "@timestamp": "2026-10-12T14:03:07.412Z",
  "ecs": { "version": "8.11.0" },
  "data_stream": { "type": "logs", "dataset": "seshat.passthrough", "namespace": "exo" },
  "event": {
    "kind": "event",
    "dataset": "seshat.passthrough",
    "module": "seshat",
    "id": "01K7XEXAMPLE0PASS0000001",
    "created": "2026-10-12T14:03:07.412Z",
    "original": "<165>1 2026-10-12T14:03:07.412Z switch3.example.com sshd 2411 ID47 - Failed password for invalid user admin from 198.51.100.77 port 52311 ssh2"
  },
  "observer": { "vendor": "Example Org", "product": "Seshat", "version": "0.1.0", "type": "gateway" },
  "seshat": {
    "schema_version": "1.0",
    "source": { "listener": "syslog-udp-default", "input": "syslog", "protocol": "udp", "ip": "192.0.2.11", "port": 51514, "site": "example-site-a" },
    "passthrough": { "encoding": "utf8", "bytes": 142 }
  }
}
```

The full example is [`examples/passthrough.json`](examples/passthrough.json); it validates against the JSON Schema.

## Joining the two streams

For each message of an input with passthrough on:

- the passthrough record has `event.id = P`;
- every enriched event decoded from that message has `seshat.source.passthrough_id = P`. A flow datagram holds many
  flow records: all of them carry the datagram's `P`, so one passthrough record joins to many flow events. A syslog
  line or a trap joins one to one.

Enriched events of an input with passthrough off carry no `passthrough_id`. Through an edge the join still holds: the
edge's passthrough record keeps its id when the server accepts it, and the enriched events the edge forwarded keep
`passthrough_id`.

The event inspector ([`../inspector.md`](../inspector.md)) uses the join: the Original pane of an event shows the
passthrough record of its message and its id.

## Routing

A route has a `stream`: `enriched` (the default, and what every route created before this contract is) or
`passthrough`. A route only ever sees events of its own stream, so a catch-all route for enriched events does not start
receiving raw records when an input turns passthrough on. The route's match expression works on the passthrough
record; the fields it carries (`event.dataset`, `event.id`, `host.ip` and `related.ip`, both the sender, and
`seshat.source.input`, `.listener`, `.protocol`, `.ip`, `.port`, `.site`, `.vrf`, `.edge`) are the useful ones. Every field
the pipeline derives (`host.name`, `message`, `seshat.device.*`, vendor, severity, trap or syslog fields) is empty on the
record, so a comparison on it is always false. A passthrough route whose match reads such a field is reported in
`warnings` of `GET /api/routes` and in the Routes page, and records that match no passthrough route are counted in
`seshat_passthrough_unrouted_total` and logged with the routes' expressions:

```
# the raw syslog of one site, from one sender range
seshat.source.input == "syslog" && seshat.source.site == "example-site-a" && seshat.source.ip in 192.0.2.0/24
```

A destination that both streams use shares one queue, intake and sender; the route page warns about it
(`GET /api/routes` returns it under `warnings`), and `seshat_output_events_total` carries a `stream` label
(`enriched`, `passthrough`, `unattributed` for records evicted from a full queue) so the two can be told apart. Give the
passthrough stream a destination of its own to keep a backlog of one from delaying the other.

A passthrough route can only use destinations that can carry the record: JSON documents (`ecs-json`, or a template over
the record) to Elasticsearch, OpenSearch, Logstash, Kafka, HEC, a webhook or a file, and the original bytes (content
`raw`) to `raw_relay` and `syslog` destinations, and as one line per message (`escaped` text or `base64`) to a `file`
destination with content `raw`. A `syslog` destination relays syslog only: messages of the trap and flow inputs are
skipped there (counted as `skipped`). Over TCP and TLS a raw relay needs octet counting, so that a message holding a
line break cannot become two messages at the collector (`syslog` refuses newline framing for content raw; `raw_relay`
refuses, and counts as rejected, a message with a line break instead of splitting it). A message larger than a UDP
datagram can carry (65507 bytes), which only a TCP or TLS syslog message can be, is rejected and counted when relayed
over UDP, never truncated. Destinations that render parsed fields (CEF, LEEF, RFC 5424 built from
the event, `snmp_trap`, `syslog_relay`, the metric destinations) are refused for a passthrough route; the route is shown
as a problem and nothing is sent. See [`../outputs.md`](../outputs.md#the-passthrough-stream).

## Edges

An edge with passthrough on (set in the edge's configuration on the server) forwards the records upstream on the same
stream as its events, as records of the type `passthrough`; see [`../edge.md`](../edge.md#the-passthrough-stream-through-an-edge).
The server rebuilds the record: scope, edge id, data stream and observer are the registry's, the encoding and length are
recomputed from the bytes, and nothing but the envelope above survives.

## Not covered

Streaming telemetry (gNMI, Cisco MDT, Juniper JTI) has no passthrough: those inputs receive gRPC streams of protobuf
messages that are reassembled and decoded inside the stream's own framing before any individual message exists, so there
is no original datagram to tap, and a copy of the protobuf would be useless without the subscription state that
decodes it. Use the enriched `seshat.metric` stream.

## Index template

`deploy/elasticsearch/index-template-seshat-passthrough.json` and its OpenSearch twin map the record. They differ from
the other datasets in one field: `event.original` is searchable text here (it is an unindexed keyword elsewhere).

## Versioning

`seshat.passthrough` follows the contract rule in [`../integrations/README.md`](../integrations/README.md#contracts-and-versioning):
new optional fields are additive and keep version 1; consumers ignore what they do not know. Changing the meaning of a
field, or of the encoding, is breaking and adds version 2, with version 1 still served for at least one minor release.
The list of served versions is `GET /api/integrations/contracts`.
