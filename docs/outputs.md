# Routing and outputs

Seshat accepts everything and forwards it where you tell it to. Two things decide where an event
goes: the **route table** (which events go to which destinations) and each **destination** (how the
event is shaped, queued, retried and delivered). Both live in the database, are edited in the UI
(Routes, Destinations) or through the API, and take effect on every change without a restart and
without losing events.

```
input -> route table -> destination A: intake -> render -> disk queue -> batch -> sender -> remote
                     \-> destination B: intake -> render -> disk queue -> batch -> sender -> remote
```

The hot path (receive, decode, route) does no network or database I/O. Routing evaluates the
compiled route table and hands the event to each matching destination's in-memory intake; everything
slow (rendering, the disk queue, the network) happens on that destination's own goroutines. **One
slow, stuck or full destination never delays another.**

## Routes

A route is `name`, `enabled`, `priority`, `match`, `stop` and `destinations`. An event is copied to the
destinations of **every** enabled route it matches (once per destination, even if several routes
name it). Routes are evaluated in priority order (lower first, then by name); `stop: true` ends
evaluation after that route matches.

A fresh install has one route, **`everything`** (priority 1000, match `true`, no destinations), so
the table is never empty. Events that reach no destination are counted in
`seshat_route_unrouted_total` and appear nowhere else, so a missing route is visible rather than
silent. Delete the default route if you do not want it; it is not re-created.

### Match expressions

```
event.dataset == "seshat.trap" && event.severity >= 4 && host.ip in 192.0.2.0/24
```

| Syntax | Meaning |
|---|---|
| `field == value`, `field != value` | equality (strings are case-sensitive) |
| `<` `<=` `>` `>=` | ordering, number fields only (`event.severity`, `seshat.source.port`) |
| `field ^= "text"` | string prefix |
| `field =~ "regex"`, `field !~ "regex"` | RE2 regular expression, unanchored (`^`/`$` to anchor) |
| `field in [a, b, c]`, `field not in [...]` | set membership |
| `host.ip in 192.0.2.0/24` | CIDR membership; also `in [198.51.100.0/24, 203.0.113.9]`, `==`, `!=` |
| `a && b`, `a \|\| b`, `!a` | boolean AND, OR, NOT (the words `and`, `or`, `not` work too); parentheses group |
| `field` | true when the field is set (non-empty, non-zero) |
| `known` | true when the device knowledge base knows the sender (`seshat.device.status == "known"`) |
| `true`, `false` | constants. An empty expression matches every event |

Values are double-quoted, single-quoted or backtick-quoted strings (backticks are raw, handy for
regular expressions), integers, or bare IP addresses and CIDRs (IPv6 that starts with a letter must
be quoted). For multi-valued fields (`host.ip`, `seshat.device.tags`, `event.category`) a comparison
matches when **any** element matches, and the negated forms (`!=`, `!~`, `not in`) match when **none**
does. A missing value never matches an ordering or equality, and always matches the negated forms.

Fields: `event.{dataset,kind,module,action,id,category,type,severity}`, `message`, `error.code`,
`observer.{vendor,name}`, `host.{name,ip,mac}`, `related.{ip,hosts}`,
`seshat.source.{listener,input,protocol,ip,port,site,vrf,edge}`,
`seshat.device.{status,id,name,vendor,model,os,site,role,tenant,pack,tags}`,
`seshat.enrichment.level`, `seshat.trap.{oid,name,mib,enterprise,version,pdu_type}`,
`seshat.metric.{path,name,source,subscription}`, `seshat.metric.labels.<key>` and `known`.
Short names: `severity`, `dataset`, `input`, `listener`, `vendor`, `model`, `device`, `site`, `role`,
`tenant`. `GET /api/outputs/meta` lists them all.

**Telemetry samples.** The fields of a `seshat.metric` event ([`inputs/telemetry.md`](inputs/telemetry.md))
can be matched like any other text field, so a route can carry just the paths a consumer needs instead of
every sample of every subscription. `seshat.metric.labels.<key>` reads one label (`interface`, `component`,
`neighbor`, ...; the label names are in the event's `seshat.metric.labels`, they have no dots). A metric
field of an event that is not a sample is unset, so `==`, `^=`, `=~` and `in` do not match it and `!=`, `!~` and
`not in` do (a regular expression that matches the empty string, such as `.*`, therefore matches those events
too; anchor it or add `event.dataset == "seshat.metric"`). Prefix and glob matching on the path use the
existing `^=` and `=~`:

```
# transceiver power only, from any subscription
seshat.metric.path =~ `^/components/component\[.*\]/transceiver/`

# interface error counters of one interface family, from gNMI
seshat.metric.name in ["in-errors", "out-errors"] && seshat.metric.labels.interface ^= "Ethernet" && seshat.metric.source == "gnmi"

# everything under /interfaces, nothing else
seshat.metric.path ^= "/interfaces/"
```

Expressions are compiled once when the route is saved (a bad one is refused with the column of the
error). Evaluation allocates nothing; parsed addresses are cached per event across routes.
Measured on the development host (16 cores, one goroutine, a mixed table of 1000 routes: CIDR,
regex, sets, prefix, `&&`/`||`): about **56 microseconds per event against all 1000 routes**, 0
allocations. The same mix with 20 routes (`Match20Routes`) takes about 1.2 microseconds per event.

**Try it first:** the Routes page and `POST /api/routes/dry-run` take an event document (paste one,
or "use the latest received") and show which routes match, which destinations it would reach, and,
while you type in the editor, whether the expression under edit matches. Nothing is delivered.

## Destinations

A destination has a `type` and the following common settings. Names are lower-case slugs
(`logstash-main`); the name is the `{id}` in the API and the `dest` label in metrics.

| Field | Meaning |
|---|---|
| `enabled` | disabled destinations do not run; their queue stays on disk |
| `content` | `enriched` (the schema document, default), `raw` (the original datagram, raw relay only) or `both` (the schema document with the original datagram in `event.original`: text as is, binary as `0x` hex) |
| `format` | `ecs-json` (default), `raw`, `syslog-5424`, `cef`, `leef`, `template` |
| `template` | a Go `text/template` over the event as nested maps (`{{.host.name}}`, `{{.seshat.trap.name}}`, `{{._brand.org_name}}`, functions `json upper lower join`). On `elasticsearch`/OpenSearch and `beats` destinations every interpolated string is escaped for the inside of a JSON string (quote, backslash, control characters, line and paragraph separators), `{{json .x}}` still emits a complete quoted value, and the output must be exactly one JSON object: it is compacted to one line, and anything else (a second object, trailing text, an unquoted raw value that is not JSON) is a render error, the event is counted `rejected` with the reason in `last_error` and is never sent. Other destination types receive the template output exactly as written |
| `fields.include` / `fields.exclude` | dotted field paths to keep or drop (ecs-json and template). `@timestamp` is always kept. `seshat.route` is only present when an include list names it |
| `format_options` | `facility` (0-23, default 16), `app_name` (default `seshat`), `pen` (see syslog), `enrich` (`snmp_trap` and `syslog_relay` only, see NMS forwarding) |
| `batching` | `max_events` (500), `max_bytes` (4 MiB), `max_wait` (`1s`), `low_latency` (send as soon as an event is available) |
| `overflow` | `spill` (default), `drop_oldest`, `backpressure`; see below |
| `queue` | `max_bytes` (1 GiB, 0 = unbounded), `segment_bytes` (8 MiB), `fsync` (`interval` default, `always`, `never`) |
| `retry` | `initial` (`500ms`) doubling to `max` (`30s`), with jitter; `Retry-After` is honoured |
| `tls` | `enabled`, `server_name`, `insecure_skip_verify`, `ca_pem`, `cert_pem` (the client key is the `tls_key` secret) |
| `settings` | type-specific, below |
| `secrets` | write-only; sealed at rest, never returned, never written to the audit log |

**Secrets** are accepted in `secrets` on create and update, sealed with AES-256-GCM under
`SESHAT_SECRET_KEY` (the same facility as SNMPv3 passphrases) and returned only as `secrets_set`
(the names). On update, secrets you do not mention are kept and an empty value removes one.
Changing `SESHAT_SECRET_KEY` makes stored secrets unreadable; the destination then shows as invalid
until you set them again.

**To remove a secret** send an empty string or `null` for it in `secrets`, or list its name in
`clear_secrets` (`"clear_secrets": ["password"]`). An explicit clear wins over a value sent for the
same name in the same request. The destination form in the web UI has a **Clear** button next to
each secret that shows *set*.

**Credentials inside `settings` are secrets too.** Two places hold them besides `secrets`:

* HTTP header values (`settings.headers` of `webhook`, `prometheus_remote_write` and `otlp_metrics`):
  every value is sealed; the header names stay visible.
* URLs (`url` / `urls`): the password of `https://user:password@host` and the value of a query
  parameter whose name contains `token`, `key`, `secret`, `pass`, `pwd`, `auth`, `sig`, `cred`,
  `bearer`, `session`, `cookie` or `jwt` (so `?token=`, `?api_key=`, `?X-Amz-Signature=` ...).

They are sealed in place at rest, returned as `***` to every role (admin and operator) by every
endpoint, and kept when an update sends the `***` back (a header or parameter you leave out is
removed; a `***` with nothing stored behind it is a validation error). Destinations written by an
older version with these values in the clear keep working and are sealed at the next start (or the
next save). Prefer a header or the named secrets over URL parameters, and never put a credential in
the URL path. Errors, the **Test** result, `last_error` and log lines show URLs with these values
masked.

**Network guard.** Destination URLs are checked when you save them and again when the connection is
made: loopback, link-local, unspecified and cloud-metadata addresses are refused (private RFC 1918
ranges are fine). An administrator who really wants a local target (for example an OpenSearch on the
same host) starts Seshat with `SESHAT_ALLOW_LOCAL_TARGETS=1`; the error names this variable. HTTP
redirects are followed only within the same scheme, host and port, so an `Authorization` header, an
API key header or the event batch is never forwarded to another host; a redirect to somewhere else
counts as a failed delivery (point the destination at the final URL).

**Warnings.** The destination (list, detail and status) carries a `warnings` array, shown as a badge
in the UI and logged once when the configuration loads, for: a credential (basic/API key/bearer
auth, HEC token, webhook authorization or HMAC secret, a sensitive header, a token in the URL) on an
`http://` URL; Kafka SASL `PLAIN` without TLS; `tls.insecure_skip_verify` on, which turns off
certificate verification (the server's identity is no longer checked). The same applies to streaming
telemetry targets (password without TLS, `insecure_skip_verify`).

### Formats and branding

Branding values are read at render time and never change a field name: `observer.vendor`
and the CEF/LEEF vendor are the organisation name, the data-stream namespace
(`data_stream.namespace`, the suffix of `logs-<dataset>-<namespace>`) is `org_short` lower-cased,
the HTTP `User-Agent` is `<OrgShort>-Seshat/<version>`, and a file destination without a `path` is
named `<org_short lower-case>-seshat-<destination>.ndjson`. A rebrand applies to new events at once;
events already queued keep the values they were rendered with.

* **ecs-json**: the schema document, one JSON object. Documents carry `data_stream.*` so any
  pipeline can route without re-deriving it.
* **syslog-5424**: `<PRI>1 TIMESTAMP HOST APP - MSGID SD MSG`. PRI is `facility*8 + event.severity`
  (default facility 16, severity 5), HOST is the sending device, MSGID the trap name or dataset.
  Structured data exists only when an enterprise number is known (`format_options.pen` on the destination, else the enterprise number in
  Settings > Branding): `[seshat@<pen> dataset=".." id=".." status=".." site=".." listener=".." trap=".."]`;
  without one the SD field is `-`. CEF, LEEF and JSON bodies sent by a **syslog** destination are
  wrapped in the same RFC 5424 header.
* **cef**: `CEF:0|<org name>|Seshat|<version>|<trap OID or dataset>|<trap name or message>|<0-10>|extensions`
  with severity mapped from the syslog scale and extension values escaped (`\`, `=`, newlines).
* **leef**: `LEEF:2.0|<org name>|Seshat|<version>|<id>|^|key=value^key=value`.

### Overflow policies

Every destination owns a disk queue, bounded by `queue.max_bytes`. What happens when it is full:

| Policy | At the limit |
|---|---|
| `spill` (default) | everything already queued is kept; new events for this destination are refused and counted (`dropped`). The disk is the buffer while the remote is down. |
| `drop_oldest` | the oldest segment is deleted to make room, so the newest data survives. Counted as `dropped`. |
| `backpressure` | the destination stops draining its in-memory intake (32768 events); when that fills, new events for **this destination only** are refused (`dropped`) and `/api/destinations/{id}/status` shows `backpressure: true`. Inputs and other destinations are untouched. |

Between the router and the queue sits an in-memory intake of 32768 events per destination. A burst
larger than that while the disk cannot keep up is dropped for that destination and counted.

### The queue directory

`$SESHAT_DATA_DIR/queue/<destination>/` holds that destination's queue: numbered segment files
(`00000000000000000001.seg`, 8 MiB each by default, append-only records of `length | CRC-32C |
enqueue time | payload`) and `consumer.pos`, the delivery offset. At most `queue.max_bytes` of
**undelivered** data is kept (plus up to a quarter segment of already-delivered data that is
reclaimed at the next segment roll), so the worst case on disk is the sum of the limits of all
destinations: with the default 1 GiB and five destinations, plan 5 GiB of free space in the data
volume (or lower the limits). An empty queue occupies almost nothing. Mount `/data` on a volume
that outlives the container.

Crash safety: on start each segment is validated record by record and a torn or corrupt tail is
cut off (logged, and visible as `recovered_bytes` in the status). Delivery is **at least once**:
the offset is saved after each acknowledged batch but synced to disk at most once per second
(`fsync: always` syncs every record and every commit), so after a crash up to about a second of
already-delivered events may be sent again. Elasticsearch and OpenSearch destinations use the event
id as the document `_id`, so a repeat is a harmless version conflict. Disabling a destination or
stopping Seshat keeps its queue; deleting a destination deletes it (`?keep_queue=true` keeps it).

### Hot reload

Saving a route or destination persists it, then swaps a new route table in atomically. Destinations
whose configuration did not change are not touched (same connection, same queue); changed ones are
reconfigured in place; removed or disabled ones are stopped after the swap, flushing what the router
had already handed them. A destination or route that cannot be built is reported (`problems` in the
list responses, state `invalid`) and skipped; it never blocks the others. Other nodes sharing the
database pick changes up within about five seconds.

## Destination types

All examples are the JSON body of `POST /api/destinations` (secrets in `secrets`). Addresses are
documentation names; use your own.

### Logstash (`beats`)

Lumberjack v2 over TCP, acknowledged, optional TLS, windowed, zlib-compressed frames. Pair with
`deploy/logstash/seshat-beats-input.conf`. Needs the `ecs-json` format.

```json
{"name": "logstash-main", "type": "beats", "enabled": true,
 "settings": {"addresses": ["logstash.example.com:5044"], "window": 1024, "compression": 3},
 "tls": {"enabled": true, "ca_pem": "-----BEGIN CERTIFICATE-----..."}}
```

`addresses` are tried in order. A connection lost mid-batch retries only the events the server had
not acknowledged. For client-certificate authentication add `tls.cert_pem` and the `tls_key` secret.

### Elasticsearch (`elasticsearch`)

`_bulk` with `create` actions into the data streams `logs-<dataset>-<org_short>`
(`logs-seshat.trap-rcv`), the index templates from `deploy/elasticsearch` installed first.

```json
{"name": "es-main", "type": "elasticsearch", "enabled": true,
 "settings": {"urls": ["https://es1.example.com:9200", "https://es2.example.com:9200"], "auth": "api_key", "compress": true},
 "secrets": {"api_key": "<id>:<key>"}}
```

`auth` is `none`, `basic` (`username` + `password` secret), `api_key` (`api_key` secret: `id:key` or
the base64 form) or `bearer` (`token` secret). A whole-request 429/503/5xx is retried with
backoff honouring `Retry-After`; a 413 splits the batch; per item, 201/200 and 409 are success,
429/5xx are retried alone, other 4xx (mapping errors) are rejected for good and counted
(`rejected`), with the first reason in `last_error`.

The bulk body is line-framed, so a document must be exactly one line. A queued body that is not a
single-line JSON object (a raw CR or LF) is refused before the request is built, counted `rejected`
and never sent; the rest of the batch is delivered. `template` documents are escaped and checked
when they are rendered (see the `template` option above), so a syslog message cannot add a bulk
action such as a delete for another index.

### OpenSearch (`elasticsearch`)

Same type; point it at OpenSearch and use `deploy/opensearch` templates.

```json
{"name": "os-main", "type": "elasticsearch", "enabled": true,
 "settings": {"urls": ["https://os.example.com:9200"], "auth": "basic", "username": "seshat"},
 "secrets": {"password": "<password>"}}
```

### Kafka (`kafka`)

`github.com/segmentio/kafka-go` (MIT). Any format. One fixed topic, or one topic per dataset
(`seshat.trap`, with an optional `topic_prefix`). Topics must exist (auto-creation is not used).

```json
{"name": "kafka-main", "type": "kafka", "enabled": true,
 "settings": {"brokers": ["kafka1.example.com:9093"], "topic_per_dataset": true, "topic_prefix": "net.",
              "key": "dataset", "compression": "zstd", "required_acks": "all",
              "sasl": "scram-sha-512", "username": "seshat"},
 "secrets": {"password": "<password>"}, "tls": {"enabled": true}}
```

`key` is `none` (spread across partitions), `event_id` or `dataset`. SASL: `plain`, `scram-sha-256`,
`scram-sha-512`. Each message carries a `dataset` header.

### Splunk HEC (`splunk_hec`)

JSON event objects to `/services/collector/event`, `Authorization: Splunk <token>`. JSON bodies are
sent as the event with `time` and `host` taken from `@timestamp` and `host.name`; other formats
(CEF, LEEF) are sent as a string event.

```json
{"name": "splunk-main", "type": "splunk_hec", "enabled": true,
 "settings": {"url": "https://splunk.example.com:8088", "index": "network", "source": "seshat", "ack": true},
 "secrets": {"token": "<hec token>"}, "tls": {"enabled": true}}
```

With `ack: true` the batch counts as delivered when the indexer acknowledges it (the token needs
`useACK`); otherwise on the 200.

### Syslog (`syslog`)

UDP, TCP or TLS. TCP/TLS use octet counting (RFC 6587) by default, `"framing": "newline"` for
receivers that need it. UDP sends one datagram per message and rejects (counts) messages over 65507
bytes instead of truncating them.

One event is one log line: CR, LF and NUL inside a message are sent as the text `\r`, `\n` and
`\x00`, so a sender-supplied message cannot become several log lines at the collector. The setting
`"keep_newlines": true` sends CR and LF unchanged; it is only accepted with `protocol` `tcp` or `tls`
and octet framing (the length prefix delimits the message), and NUL is still escaped. The same
rule applies to the `syslog_relay` type. **Edges:** a 0.1.0 edge decodes destination settings
strictly and refuses a local syslog or file destination that carries `keep_newlines`; upgrade the
edges before using the setting on a destination an edge runs. The same holds for a Elasticsearch,
OpenSearch or Beats `template`: events an older edge queued with a pretty-printed or newline-ended
body are refused (permanently, counted) by the new sender, which requires one single-line JSON object.

```json
{"name": "siem-syslog", "type": "syslog", "enabled": true, "format": "cef",
 "settings": {"address": "siem.example.com:6514", "protocol": "tls"},
 "format_options": {"facility": 16, "pen": "32473"},
 "tls": {"enabled": true, "server_name": "siem.example.com", "ca_pem": "-----BEGIN CERTIFICATE-----..."}}
```

The default format is `syslog-5424`; any other format is wrapped in an RFC 5424 header.

### File (`file`)

One event per line (NDJSON for `ecs-json`), flushed per batch and fsynced at most once a second.
`path` is relative to `SESHAT_OUTPUT_DIR` (default `<data dir>/output`); absolute paths and `..` are
refused. Rotation by `max_size_mb` (default 256) and/or `rotate` (`hourly`, `daily`, UTC); rotated
files are named `<stem>-<UTC timestamp>.ndjson`, optionally gzipped, and `max_files` bounds them.
`file_mode` is the permission of the files (octal string, default `"0640"`: owner read/write, group read, so a
log shipper in the group can collect them; `"0600"` keeps them private). The process umask is 077, so this
setting, not the umask, decides; directories the output creates get the matching search bits (0750 for 0640).

A record is always exactly one line: CR, LF and NUL inside a rendered event (a `syslog-5424`, `cef`,
`leef` or `template` body) are written as the text `\r`, `\n` and `\x00`. A template that writes
multi-line records on purpose can set `"keep_newlines": true`: CR and LF are then written unchanged
(NUL is still escaped) and a record may span several lines, so only use it for a destination whose
content you control.

With the Linux packages the service can write only below its state directory. For a `SESHAT_OUTPUT_DIR` elsewhere
add a systemd drop-in with `ReadWritePaths=-/that/directory` and create the directory (owned by `seshat`, mode
0700) first; otherwise the destination fails with `read-only file system` and its events stay queued
([`packaging.md`](packaging.md), "Configuration and data"). Containers: mount a volume there.

```json
{"name": "archive", "type": "file", "enabled": true,
 "settings": {"path": "traps.ndjson", "max_size_mb": 100, "rotate": "daily", "gzip": true, "max_files": 14}}
```

CSV output is not implemented yet; use a `template` format that renders a CSV line.

### Webhook (`webhook`)

`POST` of a JSON array of the rendered events (or your `body_template`), with extra `headers`, an
`authorization` secret sent as the `Authorization` header, and an optional signature: with the
`hmac_secret` secret set, the header `X-Seshat-Signature` (configurable) carries
`sha256=<hex HMAC-SHA256 of the exact body>`. 2xx is success; 408, 425, 429 and 5xx are retried
(`Retry-After` honoured); 401/403 are retried (a rotated credential must not drop queued events);
other 4xx discard the batch (`rejected`).

```json
{"name": "chatops", "type": "webhook", "enabled": true,
 "settings": {"url": "https://hooks.example.com/seshat",
              "body_template": "{\"text\": {{json (printf \"%d events\" .Count)}}, \"events\": [{{join \",\" .Events}}]}"},
 "secrets": {"hmac_secret": "<shared secret>"}}
```

### Raw relay (`raw_relay`)

Forwards the original datagram of each event byte for byte (content and format `raw`) to a UDP or
TCP target. It works for every input that keeps the datagram on the event: traps and informs, syslog
(a UDP datagram, or one line or frame of a TCP/TLS stream) and, once the flow input lands, flow
datagrams. TCP can add `newline` or `octet` framing; the datagram is never altered, so with `newline`
framing a datagram that contains a line break is split there (use `octet` for binary or multi-line
datagrams). By default the datagram leaves from Seshat's
own address; `preserve_source` changes that, see mode 1 below. Details in "NMS forwarding".

### Metric destinations (`prometheus_remote_write`, `influx_line`, `otlp_metrics`)

These three types consume the `seshat.metric` events of the streaming-telemetry input
([`inputs/telemetry.md`](inputs/telemetry.md)). They read the `ecs-json` rendering, so the format
must be `ecs-json` and `fields.include` / `fields.exclude` must be empty. An event of any other
dataset is skipped and counted (`skipped_not_metric` in the destination's sender stats), so a
route such as `event.dataset == "seshat.metric"` is advisable but not required. Non-numeric samples
(`string`, `delete`) are skipped by Prometheus and OTLP (`skipped_non_numeric`); Influx keeps strings
as string fields. The Test button sends one synthetic interface counter. Metric events routed to
the other destination types (Elasticsearch, file, Kafka, ...) are plain JSON documents.

Series are identified by the path without list keys plus the labels: the `seshat.metric.labels`,
`host` (`host.name`, else the first `host.ip`), `site` (`seshat.device.site`, else the input's
site). A path label that is itself called `host`, `site` or `source` is renamed `label_<name>`.

| Type | Wire format | Settings |
|---|---|---|
| `prometheus_remote_write` | Remote-write 1.0: a snappy-compressed `WriteRequest` protobuf, `Content-Encoding: snappy`, `X-Prometheus-Remote-Write-Version: 0.1.0`. Metric name = `metric_prefix` (default `seshat_`) + the path without keys, non-alphanumerics as `_` (`seshat_interfaces_interface_state_counters_in_octets`). Booleans are 0/1. Samples of one series are sent in time order in one `TimeSeries`. | `url`, `username` + `password` secret (basic) **or** `token` secret (bearer), `headers` (e.g. `X-Scope-OrgID`), `metric_prefix`, `timeout`, TLS |
| `influx_line` | Line protocol. Measurement = `measurement_prefix` + the path without keys and without the leaf (`interfaces/interface/state/counters`); tags = labels, `host`, `site`, `source`; fields = the leaves sharing measurement, tags and timestamp (`in-octets=1843200u,out-octets=99u`): `i` integers, `u` unsigned, floats, booleans, strings quoted. Escaping follows the InfluxDB line-protocol reference: commas and spaces in the measurement, commas, equals signs and spaces in tag keys, tag values and field keys, and quotes and backslashes in string values; a backslash elsewhere is written as is. Line protocol cannot express a name or value that ends in a backslash, so trailing backslashes are dropped, and a line break is sent as a space; an empty tag key or value is omitted. The encoder is tested against the official InfluxData line-protocol parser. | `mode` `http` (default) or `udp`; HTTP: `url` and `bucket` (+ `org`, `token` secret) for InfluxDB 2 `/api/v2/write`, or `database` (+ `username`, `password` secret) for InfluxDB 1 `/write`; `precision` `ns` (default), `us`, `ms`, `s`; UDP: `address`, `max_packet` (default 1400, datagrams are filled with whole lines); `measurement_prefix`, `timeout`, TLS |
| `otlp_metrics` | OTLP/HTTP protobuf `ExportMetricsServiceRequest` posted to `<url>/v1/metrics` (optionally gzip). One resource per device (`host.name`, `seshat.site`), one gauge per dotted path (`metric_prefix` + `interfaces.interface.state.counters.in-octets`), one data point per sample with the path labels as attributes; integers as `as_int`, the rest as `as_double`. | `url`, `username` + `password` or `token`, `headers`, `gzip`, `metric_prefix`, `timeout`, TLS |

Every sample is exported as an untyped gauge or a gauge data point: the telemetry stream does not
say whether a leaf is a counter, so use `rate()` / `non_negative_derivative()` on the cumulative
ones. Responses: 2xx is success; 429, 408 and 5xx are retried honouring `Retry-After`; 401 and 403
are retried (a rotated credential must not drop queued data); any other 4xx discards that batch
(Prometheus answers 400 for out-of-order samples).

## NMS forwarding

There are four ways to hand notifications to a network management system (NMS) or
another collector. They are ordinary destinations; route to them like any other.

| Mode | Destination | What the NMS receives | Use it when |
|---|---|---|---|
| 1. Raw relay | `raw_relay` | the original datagram, unchanged; with `preserve_source`, from the original device's IP and port | the NMS must see the device itself as the sender (access lists, per-device views, licences by source address) |
| 2. Re-originated trap | `snmp_trap` | a fresh v2c or v3 trap or inform from Seshat; original agent address in `snmpTrapAddress.0`, original community in `snmpTrapCommunity.0` | the NMS understands `snmpTrapAddress`, or you must change version or credentials (v1/v2c/v3 in, v2c/v3 out), want acknowledged informs, or cannot grant raw sockets |
| 3. Enriched trap | `snmp_trap` with `format_options.enrich` | mode 2 plus site, role, device name, interface name, enrichment level, vendor and tenant as varbinds under your enterprise number | the NMS can map extra varbinds (it loads the generated `<ORG_SHORT>-SESHAT-MIB`) and operators want the context in the alarm |
| 4. Syslog / flow relay | `raw_relay` (original bytes) or `syslog_relay` (parsed, re-emitted) | the original syslog line or flow datagram, or an RFC 5424 message with the original hostname, app-name, procid, msgid and timestamp | another collector or analyser should get the same data without Seshat's own format |

Mode 1 needs the network to cooperate. Modes 2 to 4 need nothing special, which is why they are the
default recommendation: start with mode 2, move to mode 1 only if the NMS cannot use
`snmpTrapAddress`.

### Mode 1: raw relay with source preservation

```json
{"name": "nms-raw", "type": "raw_relay", "enabled": true,
 "settings": {"address": "nms.example.com:162", "preserve_source": true}}
```

With `"preserve_source": true` each datagram is sent as a UDP packet whose **source IP and port are
the original sender's** (IPv4 and IPv6; `protocol` must be `udp`). Seshat builds the IP and UDP
headers itself and writes them to a raw socket (`AF_INET`/`AF_INET6`, `SOCK_RAW`, `IPPROTO_RAW`,
which implies `IP_HDRINCL`). Requirements:

* **`CAP_NET_RAW`** for the Seshat process. Seshat tries to open the socket at start. Without the
  capability the destination does not crash: its state is `failing`, `blocked` reads `needs
  CAP_NET_RAW ...`, the Destinations form says so next to the toggle, `seshat_output_blocked{dest}`
  is 1, and **events stay queued** until the capability is granted (Seshat probes again every ten
  seconds, so no destination edit is needed once the process has it). With the packages, grant it
  with the drop-in `nms-relay-preserve-source.conf` ([`packaging.md`](packaging.md#capabilities)).
* **A network path that accepts the spoofed source.** Switches and routers with unicast reverse-path
  filtering (uRPF), "IP source guard" or anti-spoofing ACLs, and cloud security groups, drop these
  packets silently. Seshat cannot detect that: it sees a successful send. Test with a packet capture
  on the NMS side (`tcpdump -ni any udp port 162`) before relying on it. Host `rp_filter` on the NMS
  or on a Linux router in between matters too (`net.ipv4.conf.*.rp_filter`).
* Linux only. On other platforms the destination reports that source preservation is unavailable.
* The relay target is resolved at send time; the original source must be of the same IP family as
  the target (an IPv6 device cannot be relayed to an IPv4 NMS this way, use mode 2). Datagrams without
  a usable source are rejected and counted, not retried.
* The IPv4 packet is sent without the DF bit and may be fragmented by the kernel when larger than the
  path MTU; the UDP checksum is always computed.

Granting the capability. A capability only helps a process that actually holds it after `exec`; a
non-root process in a container does not, unless it is an ambient capability. The published image runs
as the non-root user 65532, so for compose or Kubernetes run the container as root and drop
everything else:

```yaml
# docker compose (compose.yaml, service seshat)
    user: "0:0"
    cap_drop: [ALL]
    cap_add: [NET_RAW]
```

```yaml
# Kubernetes (container securityContext)
securityContext:
  runAsUser: 0
  capabilities:
    drop: ["ALL"]
    add: ["NET_RAW"]
```

```ini
# systemd (a drop-in: systemctl edit seshat); works for a non-root User=
[Service]
AmbientCapabilities=CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_RAW
```

When the capability is missing, `GET /api/outputs/meta` (`capabilities.raw_socket`) and the
Destinations form say so. Port 162 or 514 below 1024 is a separate matter (`CAP_NET_BIND_SERVICE`, or
the compose port mapping to 1162 and 1514 that the image uses by default).

### Mode 2: re-originated trap (`snmp_trap`)

```json
{"name": "nms-trap", "type": "snmp_trap", "enabled": true,
 "settings": {"address": "nms.example.com:162", "version": "v2c", "rate_per_second": 200},
 "secrets": {"community": "the-nms-trap-community"}}
```

Each trap or inform that matches the route becomes a **new notification sent by Seshat**:

* `sysUpTime.0` (the original uptime) and `snmpTrapOID.0` (the original trap OID; an SNMPv1 trap is
  mapped per RFC 3584),
* the original varbinds, verbatim: same OIDs, types and values, in the original order,
* `snmpTrapAddress.0` (`1.3.6.1.6.3.18.1.3.0`, IpAddress): the original agent address (the sender's
  address when the trap did not say). For an IPv6 origin, which an IpAddress cannot hold, the 16 raw
  bytes travel as an OCTET STRING,
* `snmpTrapCommunity.0` (`1.3.6.1.6.3.18.1.4.0`) when the original was v1 or v2c: the original
  community (`settings.omit_community` leaves it out). A v3 original has none. If the original already
  carried either of these (a trap relayed by another proxy), it is kept as it is.

Settings:

| Setting | Meaning |
|---|---|
| `address` | the NMS, `host:port` (162) |
| `version` | `v2c` (default) or `v3`. Incoming v1, v2c and v3 are all translated to this |
| `inform` | send informs and wait for the acknowledgement instead of traps |
| `timeout`, `retries` | for informs: wait per attempt (default 5s) and extra attempts (default 2). An inform that is never acknowledged fails the delivery; the event stays in the queue and is retried with the destination's backoff |
| `rate_per_second` | per-destination cap; excess notifications wait in the queue, nothing is dropped |
| `omit_community` | do not carry the original community |
| secret `community` | the NMS's trap community (v2c). This is the **target** credential, unrelated to the original community |
| `v3.user` | v3 only: a user of the SNMPv3 user store (Inputs, SNMP); its stored passphrases are used |
| `v3.username`, `v3.auth_protocol`, `v3.priv_protocol`, secrets `auth_pass`, `priv_pass` | v3 only: an inline user instead (`SHA` default, `SHA224/256/384/512`, `MD5`, `none`; privacy `none` default, `AES`, `AES192/256`, `AES192C/256C`, `DES`) |
| `v3.context_name` | v3 context name |
| `v3.engine_id` | v3 traps: Seshat is the authoritative engine and must be known to the NMS. Hex, 5 to 32 bytes; empty derives a stable one from the destination name. Register it (and the user) at the NMS, exactly as for any v3 trap sender. Engine boots is the process start time, so it only grows across restarts. For informs the NMS is authoritative and engine discovery is automatic |

A stored `v3.user` is read when the destination loads; edit and re-save the destination after
changing the user. Counters (`GET /api/destinations/{id}/status` under `sender_stats`, and
`seshat_output_sender_total{dest,counter}`): `traps_sent`, `informs_acked`, `informs_unacked`,
`send_errors`, `rate_limited` (notifications that had to wait), `skipped` (events that could not be
translated).

Only events that are traps or informs are re-originated; a syslog event routed here is counted as
`skipped`.

**What an NMS does with `snmpTrapAddress`.** It is an ordinary varbind defined by RFC 3584 for trap
proxies; the NMS sees Seshat as the sender of the packet and the device only in that varbind. Whether
a given NMS uses it to attribute the alarm to the original device is product-specific and often
needs a setting, so check its documentation or try it (the "Trying it" steps below show the varbind
on the wire). If the NMS ignores it, use mode 1, or mode 3 so the device name also travels as
`seshatDeviceName`.

### Mode 3: enriched trap (`enrich`)

```json
{"name": "nms-enriched", "type": "snmp_trap", "enabled": true,
 "settings": {"address": "nms.example.com:162"}, "secrets": {"community": "the-nms-trap-community"},
 "format_options": {"enrich": true}}
```

With `format_options.enrich` the enrichment is **appended to the original notification** (same
`snmpTrapOID.0`, original varbinds first, then `snmpTrapAddress.0` and `snmpTrapCommunity.0`), as
scalar instances under your own enterprise number: `enterprises.<PEN>.1.1.<n>.0`, in this order:

| `n` | Object | From | Type |
|---|---|---|---|
| 1 | `seshatSite` | `seshat.device.site`, else `seshat.source.site` | OCTET STRING |
| 2 | `seshatRole` | `seshat.device.role` | OCTET STRING |
| 3 | `seshatDeviceName` | `seshat.device.name`, else `host.name` | OCTET STRING |
| 4 | `seshatInterfaceName` | `seshat.device.interface.name` | OCTET STRING |
| 5 | `seshatEnrichmentLevel` | `seshat.enrichment.level` (none 0, partial 1, full 2) | INTEGER |
| 6 | `seshatDeviceVendor` | `seshat.device.vendor` | OCTET STRING |
| 7 | `seshatTenant` | `seshat.device.tenant` | OCTET STRING |

Objects with no value are left out; the level is always present. The descriptors in the generated
MIB are brand-neutral (`seshatSite`, ...); only the module name carries your
organisation, and the OIDs and the order do not change when you rebrand.

**It needs your IANA enterprise number**, entered under Settings > Branding. Until it is set, saving
an enriching destination is refused with `409 needs_enterprise_number`, the Destinations form disables
the toggle and links to the setting, and an enriching destination that exists when the number is
removed turns `failing` with `blocked: enrichment needs the operator's enterprise number...` instead of
sending unenriched notifications. Download the MIB for the NMS from Settings > Branding or
`GET /api/mibs/generated/seshat.mib`.

### Mode 4: syslog and flow relay

* **Original bytes** (`raw_relay`): the syslog line or flow datagram exactly as received. For syslog
  over TCP/TLS each message is one line or frame; use `protocol: tcp` with `framing: newline` or
  `octet` (or UDP) to re-send. `preserve_source` works the same as for traps.
* **Parsed and re-emitted** (`syslog_relay`): the event is written as RFC 5424 with the **original**
  header fields: timestamp (as parsed, UTC with millisecond precision; the instant is preserved, the
  original UTC offset is not), hostname (the sender's own, else the sender's address), app-name,
  procid, msgid, PRI (facility and severity as sent) and the message. The original structured data is
  not carried (the parsed form flattens it) and **no Seshat structured data is added**, unless
  `format_options.enrich` is on, which appends `[seshat@<PEN> site=".." device=".." role=".."]` (the
  same enterprise-number rule as mode 3). Settings are the same as the `syslog` type (`address`,
  `protocol` udp/tcp/tls, `framing`, `tls`). Events that are not syslog are counted as `skipped`.

```json
{"name": "siem-relay", "type": "syslog_relay", "enabled": true,
 "settings": {"address": "collector.example.com:514", "protocol": "udp"}}
```

### Trying it

On a deployed box any trap receiver works as the NMS:

```
snmptrapd -f -Lo -On --disableAuthorization=yes udp:1162      # Net-SNMP, prints every varbind
```

or a second Seshat container (Inputs, SNMP, listener on `:1162`, Events tail). Point the destination
at it, press Test on the Destinations page (it sends a synthetic documentation-range trap from
`192.0.2.250`), then send a real one with `snmptrap -v2c -c public <seshat>:162 '' 1.3.6.1.6.3.1.1.5.3`.
Check `snmpTrapAddress.0` is the sending device, and for mode 1 compare the packet's source address
with `tcpdump` on the NMS side.

## Shared message bus (optional)

By default a replica delivers only what it received, from its own disk queue: if
the replica is down, its backlog waits for it. With a shared bus between receive and deliver the
replicas **publish** rendered, per-destination batches to a durable log and **every replica
consumes every destination**, so a dead replica's backlog (anything that reached the bus) is
delivered by the others, and pods can be stateless. Two drivers: NATS JetStream and Kafka.

```
SESHAT_QUEUE_BUS_URL=nats://bus.example.com:4222            # or tls://..., or nats://a:4222,nats://b:4222
SESHAT_QUEUE_BUS_URL=kafka://broker1:9092,broker2:9092/seshat   # prefix after the host list; ?tls=1 for TLS
SESHAT_QUEUE_BUS_MODE=off|hybrid|only
```

Every variable is listed in `.env.example` (retention, TLS, credentials, parallelism, partitions);
a bad value stops the start with a message that names the variable. Nothing is created on the bus
until it is reachable, and a bus that is down at start does not stop the gateway.

### Modes

| Mode | Receive path | When the bus is down | Use it for |
|---|---|---|---|
| `off` (default) | router -> render -> **local disk queue** -> deliver | not involved | single box, or replicas with persistent `/data` |
| `hybrid` | router -> render -> **local disk queue (write-ahead)** -> forwarder -> bus -> every replica delivers | intake continues into the local queue; the forwarder retries with backoff and the queue drains when the bus returns; nothing is lost | the safe default once a URL is set; persistent `/data` |
| `only` | router -> render -> **publish to the bus** -> every replica delivers | events go to the local queue until the bus is back (the forwarder then drains it, oldest first, and publishing becomes direct again once it is empty) | stateless pods (ephemeral `/data`), lowest latency, no double write |

The trade-off between the two: `hybrid` writes every event twice (local queue, then bus) and adds
the local queue's latency (it forwards immediately, 100 ms at most), but an event that reached the
queue is durable on the receiving replica before anything else happens. `only` has no local write
in the healthy case, so a replica that crashes loses the events that were in its memory but not yet
acknowledged by the bus (the intake channel and the batch being published, normally well under a
second of traffic); and while the bus is down it depends on the local queue after all, which on an
ephemeral `/data` is lost if the pod restarts during that outage. Neither mode ever blocks the
receive path: when the intake channel is full events are dropped and counted, as without a bus.

Per destination: `queue.bus: "off"` keeps one destination on its own queue (changing it restarts
that destination on the same queue directory); `queue.bus_workers` sets the number of concurrent
consumers on each replica (default `SESHAT_QUEUE_BUS_PARALLELISM`, 1). `file` destinations
(a file belongs to one machine) and the edge upstream stream never use the bus.

### What goes on the bus

A message is a batch of the records the local queue holds, already rendered for the destination
(format, field filter, branding, the original datagram for raw relays) with their enqueue times;
at most `SESHAT_QUEUE_BUS_MAX_BATCH_BYTES` (512 KiB). The replica that **delivers** supplies the
connection, credentials and TLS settings of the destination from the shared configuration, so a
destination must be reachable from every replica; formatting was done by the replica that
received the event, so during a rolling change of a destination's format a few batches may carry
the old shape. A single record larger than the limit is dropped and counted
(`seshat_bus_publish_total{result="too_large"}`, `dropped` in the status).

* **NATS JetStream**: one stream `<prefix>_bus` with a subject per destination, work-queue
  retention (a batch is deleted when its destination acknowledges it), file storage, a durable
  explicit-ack pull consumer per destination shared by all replicas. `SESHAT_QUEUE_BUS_MAX_AGE`
  (default 72h) and `_MAX_BYTES` bound the stream; when `_MAX_BYTES` is reached the stream
  **refuses** new batches (the local queue keeps them) rather than evicting undelivered ones.
  Handlers send in-progress keep-alives, so a slow destination does not trigger a redelivery;
  a consumer that dies is redelivered to another after `SESHAT_QUEUE_BUS_ACK_WAIT` (60 s), and one
  that is shut down nacks its batch for immediate redelivery.
* **Kafka** (`segmentio/kafka-go`): topic `<prefix>.<destination>` created on first use
  (`SESHAT_QUEUE_BUS_PARTITIONS` partitions, default 6, `retention.ms` from `_MAX_AGE`,
  `retention.bytes` from `_MAX_BYTES`), consumer group `<prefix>-<destination>`, acks=all,
  manual offset commits after the destination accepted the batch. A group never uses more
  consumers than the topic has partitions (replicas x workers beyond that idle). Kafka does not
  refuse writes when a topic is full: size retention deletes the oldest segments even if nobody
  consumed them, so alert on `seshat_bus_consume_lag` well before that.

The bus carries event data in clear text. Use TLS and authentication, and keep it off networks the
events should not cross.

### Ordering and duplicates

* **Delivery is at least once.** A batch is acknowledged only after the destination accepted it.
* **Ordering is best effort.** One replica forwards its queue in order, and with one consumer
  per destination a single replica delivers in order, but several replicas (or workers) consume
  concurrently and a redelivered batch comes back late. Do not rely on arrival order; events carry
  their own timestamps. Destinations that need order should use one worker on one replica, which
  means giving up the shared drain.
* **Duplicates.** A repeat is possible in these cases, each at most one batch (default 500 events
  or 512 KiB): a consumer that delivered but died before acknowledging; an acknowledgement the bus
  did not confirm; a forwarder that published and then crashed before its queue offset was saved
  (the offset is synced about once per second, as without a bus). NATS removes a re-publish of
  identical records inside its 2 minute window (message id = hash of the records); Kafka has no
  such window here. Elasticsearch and OpenSearch destinations use the event id as `_id`, so a
  repeat is a harmless version conflict; for the other types the receiver sees the batch twice.
* **Loss.** Not in `hybrid` while the receiving replica's disk survives, and not once a batch is on
  the bus (subject to the retention you configured). In `only` see the trade-off above.

### Status and monitoring

`GET /api/destinations/{id}/status` gains `via_bus` and a `bus` object: `mode`, `state`
(`connecting`, `up`, `down`), `lag_batches` (batches the destination's consumers have not
acknowledged, across all replicas; `null` until measured, refreshed every 5 s), `workers`,
published and consumed counters, `fallback_events` (mode `only`: events that went to the local
queue), `backpressure` (the bus is reachable but refuses batches: stream full) and `last_error`.
A destination whose bus is down or refusing is `degraded`; `queue_depth` is then the local queue
holding the events. `GET /api/queue` summarises the mode, driver, bus URL (credentials removed),
state, publish counters, local backlog, per-destination rows and the standing warnings; Settings >
Queue shows the same and Destinations shows a "via bus" chip.

| Metric | Meaning |
|---|---|
| `seshat_bus_publish_total{result}` | batches by result: `ok`, `error` (unreachable or refused; the batch stays or goes to the local queue), `too_large`, `fallback` (mode `only`: writes that went to the local queue instead) |
| `seshat_bus_consume_lag{dest}` | batches on the bus not yet acknowledged by the destination's consumers, all replicas |
| `seshat_bus_state{mode,state}` | 1 for the current state (`off`, `connecting`, `up`, `down`), 0 for the others |
| `seshat_bus_consume_total{dest}` | batches this replica consumed and delivered |

### Stateless pods

With `mode=only`, PostgreSQL (`SESHAT_DATABASE_URL`) and a bus, `/data` can be an `emptyDir`.
Set `SESHAT_DATA_EPHEMERAL=1` in that case (the Helm chart should set it when persistence is off; see `docs/storage.md`). With the
bus mode `off` the process then logs an error at start, and `GET /api/queue` and Settings > Queue
show the warning: the disk queues and a SQLite database would vanish with the pod. See
`docs/storage.md` for the Helm values.

### Changing the mode

`off` -> `hybrid`/`only`: a queue left on disk is forwarded to the bus on the next start.
`hybrid`/`only` -> `off`: first let the bus drain (`seshat_bus_consume_lag` 0 and an empty local queue on
every replica), because batches left on the bus are not consumed by a replica with the bus off. Deleting a
destination leaves its backlog on the bus until retention expires it (NATS keeps the durable consumer
name `<destination>`; remove the stream or consumer with the `nats` CLI to reclaim it at once).

### Trying it on a box

```
docker run -d --name seshat-nats -p 4222:4222 -v seshat-nats:/data nats:latest -js -sd /data
# two Seshat processes (or containers) sharing one PostgreSQL, each with its own /data:
SESHAT_QUEUE_BUS_URL=nats://127.0.0.1:4222 SESHAT_QUEUE_BUS_MODE=hybrid   # same on both
curl -s -b cookies http://replica-a:8080/api/queue        # state "up"
# send traps/syslog to replica A, stop replica A, watch replica B deliver:
curl -s -b cookies http://replica-b:8080/api/destinations/<name>/status    # bus.consumed_events rises
```

## Monitoring

Per destination (`dest` label):

| Metric | Meaning |
|---|---|
| `seshat_output_events_total{dest,result}` | `sent`, `failed` (events in an attempt that failed; they are retried), `dropped` (overflow, intake full), `rejected` (refused for good), `skipped` (no original datagram for a raw destination), `paused` (arrived while drained) |
| `seshat_output_queue_depth{dest}` | events waiting |
| `seshat_output_queue_bytes{dest}` | bytes waiting |
| `seshat_output_lag_seconds{dest}` | age of the oldest undelivered event (0 when empty) |
| `seshat_output_last_success_timestamp{dest}` | Unix time of the last delivery (0 before the first) |
| `seshat_output_blocked{dest}` | 1 while a standing condition stops delivery until someone acts (no `CAP_NET_RAW` for `preserve_source`, enrichment without an enterprise number) |
| `seshat_output_sender_total{dest,counter}` | counters an output type keeps itself; `snmp_trap`: `traps_sent`, `informs_acked`, `informs_unacked`, `send_errors`, `rate_limited`, `skipped` |

Also `seshat_route_unrouted_total`, `seshat_route_matched_total{route}` and
`seshat_output_destinations{state}`. `GET /api/ready` includes `"outputs": "configured=N healthy=M"` (for an administrator, an operator or the metrics token)
and never fails readiness because a destination is down. A destination's state is `healthy`,
`degraded` (a failed attempt, a full queue or backpressure), `failing` (three or more consecutive
failures), `paused` (drained), `disabled` or `invalid` (its stored configuration cannot be built).

## API

Administrators write, operators read, users get 403.

| Method and path | |
|---|---|
| `GET /api/outputs/meta` | option lists for the editors |
| `GET/POST /api/routes`, `GET/PUT/DELETE /api/routes/{id}` | route table |
| `POST /api/routes/dry-run` | `{"event": {...}, "match": "optional expression"}` |
| `GET/POST /api/destinations`, `GET/PUT/DELETE /api/destinations/{id}` | destinations (with live status) |
| `POST /api/destinations/{id}/test` | send one synthetic event straight to the destination; returns `ok`, `latency_ms`, `error` |
| `GET /api/destinations/{id}/status` | queue depth and bytes, lag, last success, last error, counters |
| `POST /api/destinations/{id}/drain?timeout_seconds=30` | stop intake and wait for the queue to flush; events arriving meanwhile are counted as `paused` |
| `POST /api/destinations/{id}/resume` | accept events again |
| `GET /api/queue` | buffering mode, shared-bus driver and state, local and bus backlog per destination, warnings |

Validation errors are `400 {"error": {"code": "validation_failed", "fields": {"settings": "..."}}}`.
A destination that routes still use cannot be deleted (`409 in_use`).

