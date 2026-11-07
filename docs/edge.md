# Edge collectors

An **edge** is a small Seshat install for another network: a remote site, a customer network, a
DMZ. It is the same binary started with `--role edge`. It receives traps and syslog locally,
enriches them from a snapshot of its own site's devices, and streams them to the main server over
an outbound HTTPS connection. It needs no database, serves no UI, accepts no inbound management
connection, and keeps working (buffering to disk) while the link is down.

```
devices --traps/syslog--> [ edge: inputs -> site-scoped KB stamp -> router -> disk queue -> stream ]
                                                                          |  \-> optional local raw relay / syslog / file
                                                          outbound HTTPS  v
                                           [ main server: receiver -> stamp site/vrf/edge -> normal pipeline ]
```

The edge is the same binary as the server, started with `--role edge` (or `SESHAT_ROLE=edge`); the
`seshat-edge` package installs it under that name. It serves a small inline status page, not the web UI.

## Setting one up

1. **On the server**: Edges, *Add edge*. Give the **site** (the label the device inventory uses; it
   is stamped on everything the edge forwards), optionally a **VRF**, a name and an id. You get a
   **one-time enrolment token**, valid 24 hours, shown once.
2. **On the edge box**, once:
   ```
   install -m 600 /dev/null /etc/seshat/enrol.token && echo 'sht_enr_...' > /etc/seshat/enrol.token
   seshat edge enroll --server https://seshat.example.com --token-file /etc/seshat/enrol.token  [--ca server-ca.pem]
   ```
   Prefer `--token-file` (or `-` for standard input) over `--token`: command-line arguments are visible to
   every local user in the process list and end up in shell history.
   The edge generates a key, sends a certificate request, and receives a certificate signed by the
   server's edge CA, its site and VRF, a bearer token and its first configuration. They go to
   `$SESHAT_DATA_DIR/edge.json` (mode 0600). `--ca` is for a server whose web certificate comes from a
   private CA. `--insecure-skip-verify` exists for evaluation only; it is logged on every start, and it
   is the only way to enrol over plain `http://`.
3. **Start it**: `seshat --role edge` (the `seshat-edge` package and its unit
   `deploy/systemd/seshat-edge.service`, install guide `deploy/edge/README.md`; container file
   `compose.edge.yaml`). Containers can enrol on first start from `SESHAT_EDGE_SERVER` and
   `SESHAT_EDGE_ENROL_TOKEN` (or `SESHAT_EDGE_ENROL_TOKEN_FILE`, which reads the token from a file and keeps it
   out of the environment; use a mounted secret).
4. **Check**: the status page on `http://127.0.0.1:8082` (`SESHAT_LISTEN` changes it), `GET /api/health`,
   `GET /api/ready`, and the Edges page on the server.

Point the devices at the edge's address instead of the server's. Configure everything else on the
server: the edge pulls it.

## What runs on the edge

| Part | Behaviour |
|---|---|
| Inputs | SNMP traps/informs (v1, v2c), syslog (UDP, TCP), flows (NetFlow v5/v9, IPFIX, sFlow) and streaming telemetry ([dial-out listener and dial-in targets](#streaming-telemetry)), configured per edge on the server (`snmp`, `syslog`, `flow` and `telemetry` blocks of the edge configuration, the same settings as the server's Inputs pages). Their site and VRF are forced to the edge's. SNMPv3 users and TLS syslog are not distributed yet. GeoIP databases are read from the edge's own `SESHAT_GEOIP_*` files. |
| Enrichment | The edge holds a **read-only snapshot of the known devices of its own site**, pulled from the server (ETag, every few minutes, kept on disk so a restart works offline). Unknown senders get the same capped expiring stubs as on the server, kept in memory only. |
| Router | Exactly one built-in destination, `upstream`, receives everything. Server-configured local outputs (`raw_relay`, `syslog`, `file`) each get a route with their own match expression. |
| Queue | The same disk queue as every destination (`$SESHAT_DATA_DIR/queue/upstream`, 1 GiB by default, spill). Nothing is dropped because the server is away. |
| Rate limit | An edge-wide token bucket (events per second), set on the server; what it drops is counted. |
| Packs | The server's pack directories (tar.gz, ETag). A change restarts the edge's pipeline. Until the first sync it uses the packs shipped with the image. |
| Pollers | The Device Tracker pollers (FDB, ARP, ND, wireless, subscriber tables, per the packs) and the knowledge base's SNMP lookup, for the tracked devices an administrator assigned to this edge ([Polling on the edge](#polling-on-the-edge)). None until a device is assigned. Their results travel on the same stream as the events. |
| Relay | Off by default. When an administrator turns it on and lists the hosts it may reach, the edge opens TCP connections to them for authorised clients ([Relay](#relay)). It runs on its own connection to the server and goroutines, never on the event path. |
| State | Only `edge.json`, the queue, the packs and the KB snapshot. No database file is ever written; the components that expect a store get a private in-memory one. |

Changing the configuration, the packs or the listen addresses restarts the edge's pipeline inside the
process (a moment of socket re-binding; queued events stay on disk). KB snapshot updates apply live.

## The stream

`POST /api/edge/v1/stream` carries a batch as **chunked NDJSON, gzip-compressed**. One line is one
event: `{"s": sequence, "e": typed document, "x": extra fields, "r": original datagram (base64),
"a": sender ip:port}`. The datagram and sender travel as sidecar fields, so the server can still
raw-relay what an edge received.

- **Record types.** A line without a `t` field is an enriched event. `"t": "poll"` is a poll result (below). `"t": "passthrough"` marks a passthrough
  record, see [below](#the-passthrough-stream-through-an-edge). A server refuses (and skips for good) a type it does not
  know, so new types are additive.
- **Acknowledged.** The reply is `{"last_seq", "accepted", "duplicates", "rejected"}`; `last_seq` is the
  highest sequence the server holds for this edge. The edge's queue releases a batch only after its
  acknowledgement; a partial acknowledgement retries just the rest.
- **Resumable and idempotent.** Every event gets a strictly increasing sequence number when it is queued
  (reserved in blocks in `edge.json`, so numbers are never reused across restarts). The server keeps the
  highest sequence per edge (persisted, so a server restart does not forget it) and drops anything at or
  below it: a lost acknowledgement, a cut connection or a replayed queue never duplicates an event. If an
  edge loses its state file, the server's mark in the heartbeat reply lifts its numbering above it.
  Delivery is at-least-once on the wire and exactly-once at the server's cursor.
- **A bad record cannot wedge an edge.** If decoding or the pipeline panics on one record, that record is
  counted as `rejected` and skipped for good (the sequence moves past it), `seshat_input_panics_total{input="edge_stream"}`
  is incremented and one rate-limited error line names the edge id; the rest of the batch is delivered and
  acknowledged, so the edge never resends the same poison record forever.
- **Backoff.** Failed batches retry with exponential backoff and jitter (500 ms to 30 s by default; the
  upstream `retry_initial_ms` / `retry_max_ms` change it). `503` and `429` ask for at least 5 s.
- **Batching.** `batch_events` (500), `batch_bytes` (4 MiB), `flush_ms` (1000), `compress` (true).
  `low_latency` flushes every 200 ms.
- **Authentication.** Mutual TLS on the dedicated listener (`SESHAT_EDGE_LISTEN`): the client certificate's
  CN is the edge id and its serial must be the one issued. That listener accepts **only** the certificate; a
  bearer token presented there is refused (`client_certificate_required`). On any other listener, behind a
  proxy that ends TLS, the edge authenticates with its bearer token. When a request carries a verified
  certificate the token is not looked at. `SESHAT_EDGE_REQUIRE_MTLS=1` refuses bearer tokens everywhere.
  A deleted, rotated or revoked edge fails with `401`; the edge reports the link as `unauthorized`,
  **keeps buffering**, and retries. Enrol it again with a new token to resume (it keeps its queue).
- **Renewal needs the certificate.** `POST /renew` only answers a request that arrived with the edge's
  current, verified client certificate (proof of possession of its key). A leaked bearer token cannot
  re-key an edge, and an edge that reaches the server only through a TLS-terminating proxy does not renew
  (it has no use for the certificate there).
- **Token lifetime.** A bearer token is valid for `SESHAT_EDGE_TOKEN_MAX_AGE` (default `400d`; `0` = never)
  after it was issued. Edges of this release adopt a replacement token that the server hands out at half
  of that age (in the heartbeat reply, or at certificate renewal). The previous token keeps working for a
  day so the edge that adopts the new one is never cut off mid-request. A replaced token is accepted
  during that day but never trades itself for a new one (a leaked old token cannot evict the current
  one), so an edge whose replacement reply was lost must be rotated and enrolled again once the day is
  over; that is rare, because the edge stores the new token before it uses it. An edge enrolled with an
  earlier release (0.1.0) cannot adopt a new token: it keeps working until its token reaches the maximum age, then the server answers `401
  token_expired`, logs why, and the Edges page shows "the edge stream token has expired" for it. Rotate
  the edge (Edges page) and enrol it again, or upgrade it first. Set `SESHAT_EDGE_TOKEN_MAX_AGE=0` to keep
  tokens valid forever, as before.
- **Stamping.** The server decides everything that attributes or routes an event. `seshat.source.site`,
  `seshat.source.edge` and `seshat.source.vrf` are the registry's values (an edge cannot claim another
  site, edge or VRF, whatever its listeners say: set the VRF on the edge record), `seshat.device.*` and
  `seshat.enrichment.*` are written by the server's own stamper from its knowledge base, `data_stream.*`,
  `ecs.*` and `observer.*` are rebuilt from the server's branding and the edge's name, and `event.dataset`
  must be one of `seshat.trap`, `seshat.syslog`, `seshat.flow`, `seshat.flow_rollup` or `seshat.metric`
  (anything else is counted as rejected). `event.id`, `event.module`, `event.kind` and `event.created` are
  generated by the server when it receives the event (`event.created` is the receive time; the time the
  device reported stays in `@timestamp`), so an edge cannot choose an event's id.
- **Extra fields are all or nothing.** The fields a pack derived on the edge (`x`) are merged in. A record
  whose extras name any server-owned member (`data_stream`, `ecs`, `@timestamp`, `seshat.source/device/
  enrichment/route/tracker/schema_version`, `event.dataset/module/id/created/ingested`, `observer.vendor/
  product/version/name/type/ip`), however spelled (nested, dotted, any letter case), or write a scalar over
  `seshat`, `event`, `observer`, `data_stream` or `ecs`, or hold more than 4096 keys or nesting deeper than 8,
  is refused whole: it is counted as rejected (`seshat_edge_records_refused_total`), skipped for good, and
  logged once per ten minutes per edge. Nothing is truncated or silently dropped. Pack-derived `event.kind`
  and `observer.ingress/egress.*` pass (the server writes `event.kind` itself).
- **Sequence numbers.** A record numbered more than 200,000 above what the server holds is refused (counted
  in `seshat_edge_sequence_jumps_rejected_total` and the batch's `rejected`) so an edge cannot push its own
  dedup mark out of reach. The allowance grows by what the edge declares dropped: sequence numbers are
  assigned before the queue, so events discarded by a full queue or the rate limit still used numbers, and
  the edge's heartbeat reports that count (`dropped`; 0.1.0 edges report it too). After a long outage that
  overflowed the queue the first record after the gap is accepted as soon as a heartbeat has declared the
  drops (the edge retries until it has). The allowance is spent as it is used. The other honest case that
  looks like an attack is a server whose database was restored from an older backup: the edge's numbering is
  then far ahead of the restored mark. An administrator accepts it with `POST /api/edges/{id}/resync`
  (audit `edge.resync`): the next record, within ten minutes, becomes the new baseline.
- **Poll records.** The results of the edge's [pollers](#polling-on-the-edge) are records of a second type on the
  same stream: `{"s": sequence, "t": "poll", "p": {...}}` has no `e` (there is no event). They take their numbers from the same counter,
  wait in the same disk queue, are acknowledged in the same order and are dropped by the same cursor as events, so a
  link outage delays them and loses none. A record of a type the server does not know is counted as rejected and skipped,
  like a bad event. If the server cannot store a poll record just now (its database is away, or who owns the device
  cannot be told yet) it stops the batch before that record without moving the cursor, and the edge resends it with
  everything after it. That is bounded: a record asked for again for more than two minutes or forty times is rejected,
  counted (`seshat_edge_poll_records_dropped_total`) and skipped, so a record that can never be stored cannot hold the
  stream. Only a store that is unavailable, a lookup that has not answered or the per-edge rate bound ask for a retry;
  bad content is refused at once.
- **Raw relay.** The datagram and sender an edge reports are carried for raw relays, but a `raw_relay`
  destination with `preserve_source` never uses an edge-reported sender address: the packets would carry a
  source the server cannot vouch for. Such events fail that destination with a counted error; send them
  with a normal raw relay (from the server's own address), or relay at the edge.

Other endpoints (all under `/api/edge/v1`, edge credentials unless noted): `POST /enroll` (the token),
`POST /renew`, `POST /heartbeat` (every 30 s: version, link state, queue depth, lag, sequences, dropped;
the reply carries the dedup mark and a hint when a new configuration or a certificate renewal is due),
`GET /config`, `GET /packs`, `GET /kb/snapshot?site=` (an edge can only read its own site and VRF: the snapshot holds
exactly the devices its events are looked up in) and the
public `GET /ca`. `config`, `packs` and `kb/snapshot` honour `If-None-Match` and answer `304`.

## The passthrough stream through an edge

An input can ship the original message untouched beside the enriched event ([the passthrough
stream](outputs.md#the-passthrough-stream)). On an edge this is switched on in the edge's configuration on the server,
with `"passthrough": true` in the `syslog`, `snmp` or `flow` block (the same setting as the server's Inputs pages).
The edge then takes each message at its listener, before decoding, and sends it upstream on the same stream, with the
same queue, sequence numbers, acknowledgements and de-duplication as the events, as a record of type `passthrough`:

```
{"s": 42, "t": "passthrough", "e": {the minimal seshat.passthrough document}, "r": original bytes (base64), "a": "ip:port"}
```

The server does not run these records through enrichment. It rebuilds them (site, VRF, edge id, data stream and
observer are the registry's, the encoding and the length are recomputed from the bytes, any other field is dropped)
and hands them to its **passthrough routes**, so a remote site's raw stream reaches the server's destinations
(`raw_relay`, a `syslog` relay with `content: raw`, Elasticsearch, Kafka, a file...) with `seshat.source.edge` set.
The record keeps the id the edge gave it, so the enriched events the edge forwarded for the same messages join to
it through `seshat.source.passthrough_id`. A record whose type and dataset disagree, or of a type the server does not
know, is refused and counted as `rejected`.

- The passthrough stream has its own rate bucket on the edge, `rate_limit.passthrough_events_per_second` and
  `passthrough_burst` (0 = the same rate and burst as the edge-wide limit): the limit protects the link to the server,
  and neither stream spends the other's tokens.
- The edge has no passthrough route of its own: its built-in route sends the stream to `upstream`. Site-local
  outputs still receive the enriched stream only.
- Passthrough doubles the bytes sent upstream for the inputs that have it on (the original and the decoded event).
  Switch it on only where the server needs the raw stream.
- Versions. An edge only produces passthrough records when its configuration, pulled from the server, switches an
  input's `passthrough` on, which a server older than this feature has no way to do, and an older edge ignores the key.
  If a server is downgraded below its edges, or an edge keeps a newer configuration than the server it now talks to,
  the older server refuses the records (its dataset allow-list has no `seshat.passthrough` and it ignores the record
  type): they are counted as rejected, the sequence moves past them for good and the events around them are unaffected.
  The passthrough records sent in that window are lost; switch passthrough off in the edge's configuration before
  downgrading the server.
- Enable it in the Edges drawer (Passthrough), or by setting `"passthrough": true` in the edge's `syslog`, `snmp` and
  `flow` blocks.

## What an edge keeps on disk

`edge.json` (mode 0600, written atomically in a 0700 directory) holds the edge's private key, certificate,
bearer token and the last configuration the server sent, including the secrets of local outputs (a syslog
TLS key, for instance) in plain text: the edge has no stable key of its own to seal them with, and "keeps
no secrets at rest" is not true of it. Protect the data directory like a key store (dedicated user, disk
encryption), and prefer local outputs that need no secret. The queue directory is private as well.

Further files live next to it, all mode 0600:

- `snmp-seal.key`: the edge's X25519 key for sealed SNMP credentials ([SNMP reads](#snmp-reads)), made at first start
  (written and synced to disk before it is used). The edge refuses a key file that is empty, damaged or readable
  by group or others, and does not replace it: only the SNMP reads become unavailable (the status page and
  `seshat_edge_snmp_available 0` say why); traps, syslog, flows and the relay keep running. Fix the file or
  delete it to make a new key.
- `snmp-used.log`: the ids and expiry of the sealed credentials already used (no credential, no key), so that a restart
  does not reopen the replay window of a blob that leaked; at most 100,000 live entries, beyond which sealed reads are
  refused with `limit_exceeded` until some expire (a blob lives five minutes at most).
- `snmp-profiles.enc`: the SNMP credentials of the site's profiles (and the v2c communities of the tracked devices' VRF
  contexts), only on an edge that has the SNMP reads switched on or has tracked devices assigned to it.
  They are **not** in `edge.json`. The file is encrypted with XChaCha20-Poly1305 under a key derived (HKDF-SHA256)
  from `snmp-seal.key`, so the credentials are not readable in a copy of `edge.json`, a backup of the one file, or
  a support bundle. This is encryption at rest in the limited sense: the key sits in the same directory, so
  anyone who can read the whole data directory can read the credentials, exactly as they can already take the
  edge's private key. Protect the directory as above. The file is replaced whole at every configuration change,
  so a profile that is deleted, disabled or cleared on the server is gone from the edge at its next sync, and the file is
  removed when the reads are switched off.
- `telemetry-secrets.enc`: the TLS key of the dial-out listener and the dial-in targets with their credentials, only on
  an edge that has them ([Streaming telemetry](#secrets-on-the-edge)); encrypted like `snmp-profiles.enc`.
- `kb-snapshot.json.gz` and `packs/` (not secret).

## Streaming telemetry

An edge can collect streaming telemetry on a network the server cannot reach: it listens for devices that
dial out (Cisco MDT, Juniper `DialOutSubscriber`, gNMI dial-out, Dell OS10) and it dials the gNMI and Juniper JTI
targets an administrator assigns to it, with the same decoders and sessions as the server
([`inputs/telemetry.md`](inputs/telemetry.md)). The samples become `seshat.metric` events on the edge's
ordinary stream, so they take the path of every other event: the edge's rate limit, the site-scoped
knowledge-base stamp, the disk queue (a link outage delays them and loses none), and on the server the
site, VRF and edge stamp, the routes, and the Prometheus remote-write, InfluxDB and OTLP destinations.
Telemetry is read-only toward devices: a dial-in subscription only reads (no gNMI Set).

### Dial-out listener

The `telemetry` block of the edge configuration (Edges page, drawer, *Streaming telemetry*, or
`POST /api/edges/{id}/config`):

```json
{ "telemetry": {
    "dialout_listen": "192.0.2.5:57400",
    "allow_list": ["192.0.2.0/24"],
    "tls_cert": "-----BEGIN CERTIFICATE-----...", "tls_key": "-----BEGIN PRIVATE KEY-----...", "client_ca": "-----BEGIN CERTIFICATE-----...",
    "limits": { "max_streams": 100, "max_connections_per_source": 32 } } }
```

| Field | Meaning |
|---|---|
| `dialout_listen` | `host:port` of the one gRPC port for the three dial-out services. Empty or `off`: no listener. Devices are pointed at the edge. |
| `allow_list` | CIDRs or addresses that may open a stream; a refused stream is counted (`seshat_telemetry_dropped_total{reason="allow_list"}`). Empty accepts every sender that can reach the port. |
| `tls_cert`, `tls_key` | PEM; the listener then serves TLS. **Without them it is plaintext gRPC**; the Edges page warns about a plaintext listener on a non-loopback address. The key is stored sealed on the server, never returned by the API (`tls_key_set`; an empty `tls_key` keeps the stored one, `clear_tls_key` removes it). |
| `client_ca` | PEM bundle; devices must then present a certificate that chains to it. Needs a certificate and key. |
| `lease_minutes`, `max_events_per_second`, `queue_share_percent` | See *Fencing* and *Rate limit and queue share* below. |
| `limits` | `max_recv_mib`, `max_streams`, `max_streams_per_source`, `max_connections`, `max_connections_per_source`, `idle_timeout_seconds`, `reassembly_budget_mib`: the table in [`inputs/telemetry.md`](inputs/telemetry.md#ports-and-settings); 0 is the default. |

A change of the listener (address, allow-list, TLS material, limits) restarts the edge's pipeline like a
change of a trap or syslog listener; queued events stay on disk. Publish the port of a containerised edge
yourself (`compose.edge.yaml` has the line) and restrict it with the host firewall.

### Dial-in targets

Assign a target to an edge in Inputs, Telemetry (*Run on*), or with `run_on: "edge:<id>"` in
`PUT /api/inputs/telemetry`. **A target is dialled by exactly one collector, never both**: the server stops
at once, the edge starts. The edge's site and VRF stamp the samples (an edge cannot claim another); the
target's own address is reachable from the edge. The edge gets the targets in its configuration, with
the passwords and client keys, over the authenticated channel; they are not part of the stored edge
configuration and are never returned by an API. The targets apply live, without restarting the pipeline.

**Settings are the store's, not a replica's.** In a cluster the settings (`inputs.telemetry`) live in the
database. Who owns a target is worked out from the stored copy: every replica re-reads it on the change
notification and every 30 s, and an edge is served the targets straight from the store, whichever replica
it asks. A `PUT` is a compare-and-set against the copy the replica loaded, and holds are worked out from that
same copy, so a replica that is behind cannot overwrite what another stored: it answers `409
settings_changed`, refreshes, and the change is repeated on top of the new state. A store that cannot be read
is an error (`500` to the edge, which keeps what it has), never "this edge has no targets".

**Hand-over.** Moving a target sets a hold so the two sides never dial together. Server to edge: the server
stops at once and the edge waits 15 s. Edge to server (or to another edge): the old edge learns of it at
its next sync (its heartbeat asks for one within 30 s) and stops, so the new owner waits 2 minutes. A hold is
sent to the edge as the time that remains (`hold_secs`), never as a server timestamp, and counted on the
edge's own clock. The state `handover` shows while a target waits. Moving a target away from an edge that is
**offline** is refused (`409 edge_offline`) unless `?force=true`, because an edge keeps dialling on its last
configuration while it is cut off; a forced move holds the new owner for the edge's whole lease (below). The
server never takes a target over silently. If an assigned edge is deleted, the server dials its targets after
the hand-back hold (2 minutes from when it first saw the edge gone; a deleted edge is refused at its next
request and stops at once, but one that was cut off may dial until its lease ends); a target left on an
edge that has since vanished does not make an unrelated edit fail.

### Fencing: the lease

An edge that is cut off cannot learn that a target was moved, so it does not dial on a stale copy for ever:

* It dials its dial-in targets only **after the server answered a configuration check in this process** (an
  answer to its sync, or a heartbeat that says its configuration is the current one). A restart with the
  server unreachable dials nothing until the first answer; the dial-out listener is not affected.
* It keeps dialling for a **lease** after the last such answer: `telemetry.lease_minutes` (default 10, at
  most 1440, never less than three sync intervals). When the lease runs out the targets stop (samples
  already collected still go upstream from the disk queue) and they start again at the next answer.
* A refusal of the edge's credentials (revoked, deleted) stops them at once.

The status page, `/metrics` (`seshat_edge_telemetry_fence_open`) and the report to the server say whether the
fence is open and, if not, why. The cost is on the isolated side of a long server-link outage: no dial-in
telemetry for the part of it beyond the lease. Raise `lease_minutes` where that matters more than a clean
hand-over after a forced move.

### Rate limit and queue share

Telemetry has a token bucket of its own (`telemetry.max_events_per_second`, default 20000) and may fill a
share of the upstream disk queue (`telemetry.queue_share_percent`, default 50): beyond either, samples are
dropped and counted (`seshat_edge_telemetry_rate_limited_total`, `seshat_edge_telemetry_queue_shed_total`)
while traps, syslog and flows keep the edge-wide limit and the rest of the queue. A flood of samples (a
dial-out device gone wrong, a gNMI path that is too broad) therefore sheds samples first and never starves
the other inputs. On the server a record whose `seshat.metric` block is outside its bounds (path 2048 bytes,
name 256, 32 labels of at most 128/512 bytes, a value that does not have the shape its `value_type` says) is
refused whole and counted (`seshat_edge_metric_records_refused_total`), and one edge may send at most
100000 samples a second (`seshat_edge_metric_rate_limited_total`).

### Secrets on the edge

`telemetry-secrets.enc` (mode 0600) in the data directory holds the listener's TLS key and the targets with
their credentials, encrypted with XChaCha20-Poly1305 under a key derived (HKDF-SHA256, its own label) from
`snmp-seal.key`, like `snmp-profiles.enc`: they are not in `edge.json` (which keeps only markers), a copy
of it, or the logs. The file is replaced whole at each configuration change, so a target the server no
longer sends is gone, and it is removed when none is left. Anyone who can read the whole data directory can
read it, as for the SNMP credentials. If the file cannot be read (the key was lost) the edge clears its
configuration etag so the next sync fetches the secrets again, **never** falls back to a plaintext listener
for a configured TLS certificate (the listener stays off and `/api/ready` says why), and dials no target
until it has the credentials.

### State and counters

* **Server:** Telemetry page and `GET /api/inputs/telemetry` list the targets with `owner`, the state the
  edge last reported (`established`, `backoff`, `handover`, ...), last message, messages, last error and
  `reported_at`; `stale` is set when the edge is not connected (the numbers are then the last it told us),
  `pending` before it has reported the target. `status.edges` has the listener state and totals per edge;
  the Edges page shows the same in the drawer. The report rides the 30 s heartbeat and is stored in the database (`edge_telemetry`), so every replica shows
  the same; whether the edge is online is the database's `last_seen`, the same on every replica.
* **Edge:** the status page has a Telemetry row; `/metrics` carries `seshat_telemetry_messages_total`,
  `_updates_total`, `_dropped_total{reason}` and `seshat_telemetry_sessions{state}` (the server's names);
  `/api/ready` reports the listener as `telemetry-dialout` and, in `warnings`, a plaintext listener on a non-loopback
  address (the edge stays ready).

## The edge CA

Generated at first use (ECDSA P-256, ten years), kept in the server's settings with its key sealed under
`SESHAT_SECRET_KEY`. It signs one-year client certificates for edges, and the server certificate of the
dedicated listener. **Rotate CA** (Edges page, `POST /api/edges/ca/rotate`) creates a new CA cross-signed by
the old one: existing edges keep working, are told to renew at their next heartbeat, and a server
certificate from the new CA still verifies for an edge that has only seen the old one. Rotating a second
time before every edge has renewed drops the older CA and locks the stragglers out (enrol them again).

## Server settings

| Variable | Meaning |
|---|---|
| `SESHAT_EDGE_LISTEN` | A dedicated TLS listener (for example `:8443`) that requests client certificates from the edge CA and serves only the edge endpoints. Empty = off; edges then use the bearer token on the main listener. |
| `SESHAT_EDGE_PUBLIC_URL` | The stream URL given to edges at enrolment when it differs from the one they enrolled through (the dedicated listener). |
| `SESHAT_EDGE_HOSTS` | Names and addresses in that listener's certificate. |
| `SESHAT_EDGE_TLS_CERT`, `_KEY` | Use a public certificate on that listener instead of one from the edge CA. |
| `SESHAT_EDGE_REQUIRE_MTLS` | `1` refuses bearer tokens on every listener; edges must then use the dedicated listener. |
| `SESHAT_EDGE_TOKEN_MAX_AGE` | Lifetime of an edge bearer token, default `400d`, `0` = never (see Authentication). |

Roles: **admin** writes (create, configure, rotate, revoke, rotate CA), **operator** and **viewer** read, **user** gets `403`.
Every write is in the audit log (the token never is). The enrolment token is returned once, with
`Cache-Control: no-store`, and only its hash is stored.

## Edge settings

| Variable | Meaning |
|---|---|
| `SESHAT_ROLE=edge` | The role. |
| `SESHAT_DATA_DIR` | State, queue, packs, KB snapshot. |
| `SESHAT_LISTEN` | Status page, default `127.0.0.1:8082`. No login: keep it on loopback or a management VLAN. |
| `SESHAT_EDGE_SERVER`, `SESHAT_EDGE_ENROL_TOKEN` (or `SESHAT_EDGE_ENROL_TOKEN_FILE`) | Enrol on first start (ignored once enrolled). |
| `SESHAT_EDGE_CA_FILE` | Extra trust anchor for the server's web certificate. |
| `SESHAT_EDGE_INSECURE_SKIP_VERIFY` | Evaluation only. |
| `SESHAT_EDGE_RELAY_CEILING`, `SESHAT_EDGE_RELAY_CEILING_FILE`, `SESHAT_EDGE_RELAY_MAX_MODE` | The edge's own bound on the relay the server may configure ([Relay](#the-edge-local-ceiling)). |
| `SESHAT_EDGE_SNMP_CEILING`, `SESHAT_EDGE_SNMP_CEILING_FILE` | The edge's own bound on where SNMP reads may go ([SNMP reads](#the-edge-local-ceiling-for-snmp-reads)). |
| `SESHAT_EDGE_SNMP_SOURCE` | The address, or the name of the network interface, the edge sends SNMP to devices from (the reads and the pollers). Wins over the server's `snmp_read.source_address` ([Poll source address](#poll-source-address)). |
| `SESHAT_SNMP_TRAP_LISTEN`, `SESHAT_SYSLOG_UDP_LISTEN`, `SESHAT_SYSLOG_TCP_LISTEN`, `SESHAT_FLOW_*_LISTEN` | Local listen addresses, used when the server's configuration leaves them empty. |
| `SESHAT_PACKS_DIR` | Packs shipped with the install; the server's packs replace them. |
| `SESHAT_SECRET_KEY` | Not needed. |

Prometheus: `/metrics` on the status listener (`seshat_edge_link_up`, `_assigned_sequence`, `_acked_sequence`,
`_events_in_total`, `_events_sent_total`, `_events_rate_limited_total`, plus the usual input, queue and KB
families and process metrics); on the server `seshat_edge_up`, `_last_seen_timestamp_seconds`,
`_queue_depth`, `_lag_seconds`, `_events_received_total`, `_events_duplicate_total` per edge, plus
`seshat_edge_sequence_jumps_rejected_total` and `seshat_edge_auth_refused_total{reason}`.

## Health on the Edges page

`pending` (created, not enrolled), `expired` (token ran out), `enrolled` (never heard from), `online`,
`degraded` (online but its link is down or the queue is more than a minute old), `offline` (no heartbeat for
90 s). A configuration saved on the server shows `config pending` until the edge reports it.

## Relay

An edge can carry an authorised client's TCP session to a host on the edge's own network, without the
remote site accepting any inbound connection. The client asks the server, the server asks the edge over
the edge's existing outbound connection, and the edge opens the TCP connection locally. The edge never
listens.

```
client --HTTP/1.1 Upgrade--> [ server ] <==control request + one data request per session== [ edge ] --TCP--> target
          POST /api/edges/ID/relay                    (both opened by the edge, outbound)
```

**It is off on every edge until an administrator turns it on**, and what it may reach is a list the
administrator writes. The relay adds no confidentiality: the client runs TLS, SSH or WinRM inside the
stream, and Seshat sees only the ciphertext. A target that speaks a plain-text protocol is plain text on
the server and on the way to it; that is the client's risk to accept.

### Turning it on

Edges page, drawer, **Relay** (or `POST /api/edges/{id}/config` with a `relay` block):

```json
{ "relay": {
    "mode": "read+write",
    "allow": ["192.0.2.10:443", "198.51.100.0/24:8000", "[2001:db8::/48]:22", "dhcp.example.com@192.0.2.0/24:8000"],
    "limits": { "max_streams": 4, "max_bytes": 1073741824, "idle_secs": 300, "max_secs": 3600, "dial_secs": 10, "rate_kbps": 0 } } }
```

| Field | Meaning |
|---|---|
| `mode` | `off` (the default), `read` (accepts sessions that declare read intent only) or `read+write`. |
| `allow` | `address:port`, `cidr:port`, or `name@cidr:port` (a host name **pinned to the network its addresses must be in**); an IPv6 address or network goes in brackets. A bare `name:port` is refused: a name alone would let whatever DNS answers decide where the edge connects. **Empty list = relay disabled**, whatever the mode. The client can never add to it. The edge's own address is not excluded: a network that covers it (or loopback) lets a session reach the edge box's own services. The Edges page warns about entries broader than a /8 (IPv6: /16), entries covering loopback and the default status-page port. |
| `limits.max_streams` | Concurrent sessions on this edge (default 4, at most 64). |
| `limits.max_bytes` | Bytes in both directions together, per session (default 1 GiB). |
| `limits.idle_secs`, `max_secs` | A session with no traffic for `idle_secs` (default 300), or older than `max_secs` (default 3600), is closed. |
| `limits.dial_secs` | How long the edge waits for the TCP connection to the target (default 10). |
| `limits.rate_kbps` | Optional cap on all relay traffic of the edge together, in kilobits per second, so a busy session cannot crowd the telemetry off a thin uplink. 0 = no cap. |

The edge pulls the section with the rest of its configuration and applies it at once, without restarting
its pipeline. Sessions the new section no longer allows are closed.

### What the edge checks (the check that counts)

For every request the edge itself checks, in this order, and refuses with the code in brackets:

1. relay on and the allow-list not empty (`relay_disabled`);
2. the declared **intent** against the mode: a `write` session needs `read+write` (`write_not_allowed`);
3. the number of open sessions (`limit_exceeded`);
4. the **target**: an address must match an `address:port` or `cidr:port` entry. A name is resolved **by
   the edge**, and every address it resolves to must be allowed: by an address or network entry, or by an
   entry pinned to that name (`name@cidr:port`) whose network the address falls in. An answer outside the
   allowed networks refuses the whole name, so a poisoned or hijacked DNS answer, even one inside the same LAN
   but outside the pin, gets nothing. The edge connects to the addresses it checked, never to the name again,
   so a name that changes its answer between the check and the connection (DNS rebinding) gets nothing
   (`target_not_allowed`). The refusal tells the client only that the policy refused; the addresses involved
   are in the edge's own log;
5. the connection itself (`dial_failed`, with class `refused`, `timeout` or `unreachable`).

Policy changes apply to sessions already open: one whose rule is no longer in the configuration (including a
pinned name whose entry changed) is closed with reason `policy_revoked`, and a request being opened while the
configuration changes is checked against the new one.

The server makes the same mode and allow-list checks first, as a second line. Where the server cannot
judge (a name, which only the site's resolver can answer) it leaves the decision to the edge.

### API for clients

`POST /api/edges/{id}/relay` with `{"target": "host:port", "intent": "read" | "write"}`, an
token of an administrator, or of an [integration client](integrations/README.md) that holds the `edge.relay.tcp` capability and whose scope names the edge (`out_of_scope` otherwise; the client's rate limit answers `429 limit_exceeded`), and the headers `Connection: Upgrade` and `Upgrade: seshat-relay/1`. HTTP/1.1
only. On success the server answers `101 Switching Protocols` and the connection then carries the raw
bytes of the session both ways until either side closes it; there is no half-close. Anything else is an
ordinary JSON error `{"error":{"code","message"}}` before the upgrade:

| Code | Status | Meaning |
|---|---|---|
| `edge_offline` | 503 | The edge has no control connection to this server (it is down, or connected to a node that could not be reached). |
| `relay_disabled` | 403 | Mode `off` or an empty allow-list. |
| `target_not_allowed` | 403 | The target (or an address it resolves to) is not in the allow-list. |
| `write_not_allowed` | 403 | The session declared write intent and the edge's mode is `read`. |
| `dial_failed` | 502 | The edge could not connect; `error.fields.class` is `refused`, `timeout` or `unreachable`. |
| `limit_exceeded` | 429 | The edge is already relaying its maximum number of sessions. |
| `relay_timeout` | 504 | The edge did not answer in time. |
| `capability_missing`, `out_of_scope`, `limit_exceeded` (429, `Retry-After`) | 403, 403, 429 | An integration client without the capability, for an edge outside its scope, or over its rate limit. |
| `upgrade_required` | 426 | The request was not an HTTP/1.1 Upgrade. |
| `validation_failed` | 400 | Missing or malformed `target` or `intent`. |

Every attempt is audited (`edge.relay`), refusals included (`out_of_scope`, `upgrade_required`,
`validation_failed`, the relay codes): a refusal is one record; a session is a `start` record when it opens and an
`end` record when it closes, sharing one `session` id. A record names who asked (the account, or the
integration client and its token id), the edge, the target (at most 255 characters), the declared intent, start
and end, bytes in each direction and the outcome (`target_closed`, `server_closed`, `client_closed`,
`idle_timeout`, `max_duration`, `max_bytes`, `policy_revoked`, `edge_shutdown`, `edge_dropped`, `error`, or
`refused` with the code); a client that disconnects while the edge is still opening the relay is
`client_closed`. The payload is never logged.

An integration client may hold at most 2 relay sessions open at once unless its limits set another number
(`"limits": {"edge.relay.tcp": {"concurrent": 4}}`); beyond it, `429 limit_exceeded`.


### The edge-local ceiling

The allow-list comes from the server, so by itself it protects against a stolen client token but not against a
compromised server. An edge's own operator can bound what the server may ever allow, in the edge's environment
(not in anything the server sends):

| Variable | Meaning |
|---|---|
| `SESHAT_EDGE_RELAY_CEILING` | Comma-separated `address:port`, `cidr:port` or `name@cidr:port` entries (or `none`): the most the pushed allow-list may contain. |
| `SESHAT_EDGE_RELAY_CEILING_FILE` | The same, one entry per line (`#` comments), read at start. |
| `SESHAT_EDGE_RELAY_MAX_MODE` | `off`, `read` or `read+write`: the highest mode the server may set. |

The effective policy is the pushed one **narrowed** by the ceiling: the mode is the lower of the two, and each
pushed entry is cut down to what a ceiling entry also covers (a pinned name only by a plain ceiling entry or one
pinned to the same name); what is left of nothing is dropped. The server can never add to it. With no ceiling
variable set, the relay follows the pushed configuration alone, the edge logs a warning when it is enabled that way
and the status page says so. A ceiling that cannot be read keeps the relay off. The status page and `/api/status`
show the effective policy, what the server pushed and whether a ceiling is set.

### What Seshat cannot see or enforce

- **Intent is declared by the client.** `read` and `write` are labels the caller attaches to a session.
  Seshat records them, and an edge in mode `read` refuses sessions that declare `write`, but it cannot see
  inside the stream to know whether a `read` session writes. The only network-level control it has is the
  port in the allow-list.
- **Seshat's own read-only guarantee is unchanged** (Device Tracker, "The read-only guarantee"). It covers
  what Seshat itself sends to devices. A relayed session is a separate capability: Seshat originates no
  protocol traffic through it and cannot restrict what the client does inside it.
- The server and the edge see ciphertext when the client uses TLS or SSH, and plain bytes when it does not.

### Threats and what limits them

| Threat | What limits it |
|---|---|
| A stolen client token | The allow-list is fixed by an administrator on the server and enforced on the edge: a token opens only the listed targets, only while the mode allows its intent, within the session, byte, time and rate limits, and every use is audited. The token cannot change any of that. |
| A compromised server | **Without an edge-local ceiling the edge cannot defend against a compromised server**: the server distributes both the allow-list and the sessions, so whoever controls it can allow any target the edge can reach and open sessions to it. Set a ceiling on every edge that has the relay enabled (below): the pushed configuration can then only narrow what the edge's own operator allowed. |
| DNS rebinding and poisoning | Names are resolved at the edge, only into the network they are pinned to, and the checked addresses are the ones dialled. |
| Starving telemetry | Relay traffic uses its own connection to the server, its own goroutines and fixed-size buffers on the edge and never the event queue. Back-pressure goes to the client (a slow reader slows the sender, nothing accumulates), sessions and bytes are capped, and `rate_kbps` can cap the edge's relay bandwidth. |
| A client that never ends | Idle and maximum-duration limits close the session on the edge and on the server. |

### How it works

The edge keeps one long-lived request, `POST /api/edge/v1/control`, open on a second connection of its
own; the server streams newline-delimited JSON requests down its response, with a keepalive. A relay
request carries the target and the declared intent. When the edge accepts it, it dials the target and
opens two one-way requests: `POST /api/edge/v1/relay/{id}/up`, whose body carries the bytes from the
target to the server, and `POST /api/edge/v1/relay/{id}/down`, whose response carries the bytes from the
server to the target. The session exists when the server has attached both. A refusal or a failure is
reported on the control channel instead. When the edge ends a session it first tells the server why
(`POST .../relay/{id}/end`), so the server's record names the real reason.

- Two one-way requests instead of one request carrying both directions: a stream that carries data in both
  directions can deadlock inside an HTTP/2 implementation when one direction stalls while the other waits for
  flow-control credit that is queued behind the stalled data. One-way streams cannot. It also means no proxy
  has to stream a request and its response at the same time.
- The dedicated edge listener (`SESHAT_EDGE_LISTEN`) speaks HTTP/2 and HTTP/1.1. HTTP/2 multiplexes the
  sessions of an edge on one connection and gives each stream its own flow control; over HTTP/1.1 each leg
  has a connection of its own.
- The edge uses a connection of its own for the control channel and the relay, separate from the one that
  carries events and heartbeats.
- Through a TLS-terminating proxy the proxy must stream request and response bodies without buffering them
  (HTTP/2 end to end, or HTTP/1.1 with request buffering off). If it buffers the control channel's streamed
  response, the edge notices (no hello within ten seconds) and falls back to long-polling the control
  channel (never faster than once a second); a relay session still needs the streaming data path.
- Control replies, end notices and the control channel use a connection of their own, separate from the relay
  legs, and the servers advertise large HTTP/2 flow-control windows: a client that stops reading its session
  fills its own stream window and nothing else, so other sessions, the answers the server is waiting for and the
  telemetry carry on.
- An edge handles at most 64 relay requests at once whatever the session limit; a panic in a request or session
  is contained to it (the session ends with reason `error`).
- The same channel carries other kinds of request from the server to the edge; it is not specific to TCP.
  An edge that does not know a kind answers `unsupported_kind`.

With several server nodes the node that receives the client's request finds the node that holds the edge's
control connection and passes the request to it; see [High availability](ha.md#the-edge-relay-across-nodes).
If no node holds the edge's connection the client gets `edge_offline`.

### Metrics and status

On the edge (`/metrics` and the status page): `seshat_edge_relay_enabled`, `_active`, `_sessions_total`,
`_refused_total{reason}`, `_bytes_total{direction="to_server|to_target"}`, `_closed_total{reason}`. On the
server: `seshat_edge_relay_server_active`, `_sessions_total`, `_refused_total{reason}`, `_closed_total{outcome}`,
`_bytes_total{direction}`. The Edges page shows whether an edge's control connection is up and how many
sessions are open.

## SNMP reads

An authorised client can run **on-demand SNMP reads on a device at the edge's site, through the edge**: get,
getnext, getbulk and walk, for the apps that need the optics levels, error counters or a forwarding table of one
switch right now, at a rate a cutover window needs and a scheduled poller does not give. The edge sends the SNMP
from its own network, with the site's own credentials, so the server needs no route to the device and a
community never crosses the relay in clear.

It is **off on every edge** until an administrator turns it on in the edge's `snmp_read` section (Edges page,
SNMP reads; `POST /api/edges/{id}/config`). It applies live. Like the TCP relay it uses the edge's control channel,
so an edge that is not connected answers `edge_offline`.

### What the edge guarantees

- **Reads only.** The request has four operations, `get`, `getnext`, `getbulk` and `walk` (a GETBULK loop), and a
  schema that rejects any other operation or field with `400`. The edge runs them with the Device Tracker's
  read-only session (Get, GetNext, GetBulk and nothing else), and the code that carries a request does not even
  import the SNMP library. Build-time tests scan it, and every file of the edge and
  API code that can reach a device, for write calls (method values included).
- **Safety rules on the edge, before a datagram leaves**, each named in the refusal (`target_not_allowed`):
  1. `never_poll`: loopback, link-local (including the cloud metadata addresses), multicast, the unspecified and
     reserved addresses, and every IPv6 form that embeds one of them (the list of
     [Where polling is allowed to go](device-kb.md#where-polling-is-allowed-to-go)). Whatever the profile says.
  2. `edge_ceiling`: outside the edge's own operator's [ceiling](#the-edge-local-ceiling-for-snmp-reads), when one is set.
  3. `edge_allow_list`: when the edge's `snmp_read.allow` lists networks, a target outside them.
  4. `profile_allowed_cidrs`: when the profile lists *Allowed networks*, a target outside them.
  5. `profile_without_networks`: a profile credential is only sent where a network was named. A profile that lists
     no *Allowed networks* of its own is usable only when the edge's allow-list or the edge operator's ceiling names
     the target; with none of the three, the profile cannot be used for on-demand reads and nothing is sent. (Without
     this a client could name any address and receive the site's community.) The Edges drawer warns when the reads
     are on and the allow-list is empty.
  6. `sealed_without_networks`: a client-supplied (sealed) credential is only used inside the edge's allow-list or ceiling,
     or else the allowed networks of the site's profile. With neither it goes nowhere. `sealed_port`: it may name
     another UDP port than 161 only where the allow-list entry for the target names that port
     (`198.51.100.0/24:1161`, IPv6 `[2001:db8::/32]:1161`).
- **Credentials stay on the site.** A profile is named by reference and the client never holds it. The edge
  receives only the enabled profiles of **its own site** (the profile stored under the site's name and the default
  profile `*`), with their SNMPv2c community or SNMPv3 user (authentication and privacy keys). Other sites'
  profiles never reach it. The rules of Settings still hold: a blank community keeps the stored one, *Clear*
  removes it, and a changed or removed profile reaches the edge at its next sync. Storage on the edge is described
  under [What an edge keeps on disk](#what-an-edge-keeps-on-disk).
- **Device budget.** At most `device_rate` SNMP requests per second (default 20) are sent to one device, whoever
  asks; a walk spends one request per GETBULK, and a request the device does not answer is repeated at most twice
  (a credential's retries are capped at 2 and its timeout at 10 s), each repeat taking its own slot. Reads wait for
  their turn rather than failing. The table of devices is bounded; past its cap reads fail with `limit_exceeded`.
  The budget is a single object on the edge and the scheduled [pollers](#polling-on-the-edge) take from it too: a
  window of reads plus scheduled polls stays under what the switch is given.
- **Telemetry first.** SNMP work has its own bounded worker pool (`max_concurrent`, default 4); the control
  channel is a separate connection from the event stream and the disk queue, so a busy walk never delays events.

### The edge-local ceiling for SNMP reads

The networks the reads may reach, the profiles' allowed networks and the credentials all come from the server, so
by themselves they protect against a stolen client token but not against a compromised server (which could push
an empty list and every credential). An edge's own operator can bound the reads in the edge's environment, in
something the server does not send:

| Variable | Meaning |
|---|---|
| `SESHAT_EDGE_SNMP_CEILING` | Comma-separated CIDRs or addresses (or `none`): the only networks SNMP reads may ever be sent to. |
| `SESHAT_EDGE_SNMP_CEILING_FILE` | The same, one entry per line (`#` comments), read at start. |

A target outside the ceiling is refused with `target_not_allowed` naming the rule `edge_ceiling`, whatever the
server pushed; the pushed `allow` list and the profiles' networks
can only narrow it further, never widen it, and `none` turns the reads off. With a ceiling set, a sealed credential
may be used inside the ceiling even when the server pushed no list (the ceiling is the edge operator's own
statement of where credentials may go). With no ceiling the reads follow the pushed configuration alone, the edge
logs a warning when they are enabled that way and the status page says so. A ceiling that cannot be parsed keeps the
reads off.

### The API

All three routes need an administrator token, or an [integration client](integrations/README.md) token that holds
`edge.snmp.read` and whose scope names the edge (`out_of_scope` otherwise; the client's rate limit answers
`429 limit_exceeded`).

**`POST /api/edges/{id}/snmp`**

```json
{"target": "192.0.2.10",
 "credential": {"profile": "default"},
 "ops": [
   {"op": "get", "oids": ["1.3.6.1.2.1.31.1.1.1.6.12", "1.3.6.1.2.1.1.5.0"]},
   {"op": "getnext", "oids": ["1.3.6.1.2.1.2.2.1.1"]},
   {"op": "getbulk", "oids": ["1.3.6.1.2.1.31.1.1.1.6"], "max_repetitions": 10},
   {"op": "walk", "oid": "1.3.6.1.2.1.17.7.1.2.2", "max_rows": 5000, "vlan": 10}],
 "window_id": "w1...."}
```

- `target`: the device's IP address (not a name).
- `credential`: exactly one of `{"profile": "<name>"}`, where the name is the profile's key (the site's name, or
  `*`; `default` means the site's own profile, else `*`), and `{"sealed": "<base64>"}` ([below](#sealed-one-shot-credentials)).
- `ops`: `get`, `getnext` and `getbulk` take `oids`; `walk` takes one `oid` (the subtree) and optionally `max_rows`
  (default 1000, hard cap 10,000). `getbulk` and `walk` take `max_repetitions` (default 20, at most 50).
  `vlan` reads `community@vlan` on SNMPv2c (per-VLAN forwarding tables); `context` names the SNMPv3 context.
- Limits: 16 operations and 64 OIDs per request (a walk counts as one), 20,000 rows per request, a `getbulk` of
  at most 500 varbinds (OIDs times repetitions), a request timeout of 20 s by default (`timeout_secs`, at most 120),
  and an answer of about 12 MiB at most (a walk is cut short and marked `truncated`; a get that would pass it fails for
  that operation with `limit_exceeded`). A 10,000-row walk is a couple of MiB of JSON; the control channel carries
  answers up to 16 MiB (the server logs a rejected answer at warning level, and the edge logs one it could not
  deliver), and the peer protocol between server nodes carries signed bodies up to 20 MiB.

The answer:

```json
{"target": "192.0.2.10", "elapsed_ms": 41,
 "ops": [{"op": "get", "elapsed_ms": 6, "rows": 2,
          "varbinds": [{"oid": "1.3.6.1.2.1.31.1.1.1.6.12", "type": "Counter32", "value": 5000},
                       {"oid": "1.3.6.1.2.1.1.5.0", "type": "OctetString", "value": "Example Switch 3", "hex": "4578..."}]},
         {"op": "walk", "elapsed_ms": 30, "rows": 5000, "truncated": true, "varbinds": ["..."]}]}
```

`type` is the SNMP type: `Integer`, `OctetString`, `ObjectIdentifier`, `IPAddress`, `Counter32`, `Gauge32`, `TimeTicks`,
`Counter64`, `Opaque`, `Null`, and the three exceptions **`noSuchObject`, `noSuchInstance`, `endOfMibView`, which are
values, not errors**. `value` is a number for the integer types (a decimal string for `Counter64`), the text of an
`OctetString` when it is printable UTF-8, the dotted OID or address; `hex` is the raw bytes of an `OctetString`. A
walk that stopped at `max_rows` says `truncated`. Each operation has its own `error` (`{code, message}`) with the varbinds
it had before it failed; when the device did not answer at all, or did not accept the credential, no operation has
anything to report and the whole request fails with `snmp_timeout` or `snmp_auth_failed` instead.

| Code | Status | Meaning |
|---|---|---|
| `validation_failed` | 400 | Unknown operation or field, a malformed OID or target, a limit exceeded. |
| `capability_missing`, `out_of_scope` | 403 | The client lacks `edge.snmp.read`, or the edge is outside its scope. |
| `snmp_disabled` | 403 | The reads are off on the edge. |
| `target_not_allowed` | 403 | A safety rule refused the target; the message names the rule. |
| `credential_unavailable` | 422 | The profile is not on the edge, or the sealed credential cannot be used. |
| `limit_exceeded` | 429 | Over the spacing outside or inside a window (`Retry-After`), or the edge is at its concurrent limit. |
| `window_expired` | 409 | The window is unknown, someone else's, altered or over. |
| `edge_offline` | 503 | The edge is not connected. |
| `snmp_timeout` | 504 | The device did not answer in time, or the request ran out of time. |
| `snmp_auth_failed` | 502 | The device did not accept the SNMPv3 credential. |
| `snmp_error` | 502 | Another failure of the SNMP exchange. |

A v2c device that does not know the community does not answer, so it reads as `snmp_timeout`.

Every request writes one audit entry (`edge.snmp.read`): who asked, the edge, the target, the credential kind
(and the profile's name), the operations (`get:2,walk:1`), the OID count, the rows returned, the outcome
(`ok`, `partial`, `refused`, `invalid`, `denied`) and the code; what a caller typed is cut to 255 characters. A
request refused at the door (an edge outside the client's scope, a body that is too large or not valid) is audited as
`denied` with its code. **Never the values, a credential or a sealed blob.** The text of a failure inside the SNMP
library is not sent to the client (fixed messages per class); it is in the edge's log.

**`GET /api/edges/{id}/snmp/key`** returns `{"alg", "public_key", "edge_id"}`: the key to seal a credential to. The
server asks the edge itself, so any node can answer. The Edges page and the edge's status page show the same key
(the edge reports it in its heartbeat), with a **fingerprint** (SHA-256 of the key, 16 bytes in hex groups). The key
comes through the server, so a compromised server could offer its own: **read the fingerprint from the edge's status
page once and pin it** in the client (`snmpclient.Client.PinFingerprint`, or compare it yourself); a client that
pins refuses any other key. To rotate the key, stop the edge, delete `snmp-seal.key`, start it, read the new
fingerprint and update the pins; blobs sealed to the old key stop working at once, and the stored credentials file
(encrypted under a key derived from the seal key) is fetched from the server again at the next sync.

**`POST /api/edges/{id}/snmp/windows`**: see below.

### Windows and rates

Reads on a cutover day come every 10 to 30 seconds, not every few minutes. A client opens a **window**:
`{"targets": ["192.0.2.10", ...], "min_interval_s": 10, "expires_in_s": 14400}` (at least 10 s, or the edge's own floor `snmp_read.limits.min_window_secs`, at most 8 hours, at most
256 targets) and gets an id to pass as `window_id`. The edge then allows that client one request per
`min_interval_s` to each of those targets. **Outside a window the rate is stricter: one request per 60 seconds
per client and device** (`outside_gap_secs`, per edge). A request that comes too soon gets `429 limit_exceeded` with
`Retry-After`. The id is the window itself, sealed with a key the servers share, so any node of a cluster checks it
without storing anything; it is bound to the client that opened it, the edge and the caller's *window epoch*.
An administrator ends every window a caller has open, on every edge, with
`POST /api/edges/snmp-windows/revoke` `{"client": "client:<name>"}` (the name the audit trail shows): that bumps the
caller's epoch, and its older windows answer `window_expired` at once, on every node. New windows work. The edge's
floor stops a client from promising a rate the administrator does not want to see (it is the shortest
`min_interval_s` a window may name, default and lowest 10 s). and a window that has ended, or
that someone altered, answers `window_expired`. A target the window does not list is a `400`. The edge does the
counting, because it is the one place that sees every request to its devices whichever node they came in by.

### Sealed one-shot credentials

A client that does not want to use the site's stored profile can send its own credential for one request, sealed
so that **only the edge can open it**. The server forwards the blob and never sees the credential; the edge uses
it for that request and never stores it, logs it or sends it upstream.

1. Fetch the edge's public key (`GET .../snmp/key`).
2. Seal `{"version": "2c", "community": "..."}` or `{"version": "3", "user": "...", "auth_proto": "SHA",
   "auth_pass": "...", "priv_proto": "AES", "priv_pass": "..."}` (optionally `port`, `timeout_seconds`, `retries`),
   with the edge's id, the target and an expiry of at most five minutes inside it.
3. Send it as `credential.sealed`.

Seal for **at most four minutes** (the helpers do; the edge accepts up to five): the clocks of the client and the edge
both count, and a short life leaves little to replay if a blob leaks. A blob from a client whose clock is more than a
minute ahead of the edge's is refused as not valid yet, an old one as expired, and the refusal says to check the
clocks.

The scheme is an anonymous sealed box: an ephemeral X25519 key pair, a key from HKDF-SHA256 over the shared secret
(salted with both public keys), and XChaCha20-Poly1305, laid out as `0x01 | ephemeral public key (32) | nonce (24) |
ciphertext`, base64. The sealed payload names the edge, the target and the expiry, so another edge, another
target, a late replay or a second use of the same blob is `credential_unavailable`. The edge keeps only the blob's
nonce, until it would have expired anyway.


### The edge's section

```json
"snmp_read": {"enabled": true, "allow": ["192.0.2.0/24", "198.51.100.0/24:1161"],
              "limits": {"max_concurrent": 4, "timeout_secs": 20, "device_rate": 20, "outside_gap_secs": 60, "min_window_secs": 10}}
```

`allow` is the list of networks the reads, and the edge's pollers, may reach (rule 3 above; an entry may name a UDP port for sealed credentials,
rule 6). `limits.device_rate` is the per-device budget of both. `source_address` and `poll_workers` are described under
[Polling on the edge](#polling-on-the-edge); the section also governs the pollers when `enabled` is off. Leave it empty only if every profile lists its own allowed networks or the edge has a ceiling: otherwise no
profile can be used (rule 5). Credentials are not part of what you
set: the server adds the site's profiles to the document it serves to an edge that has `enabled` on, and they
never appear in the registry's view of the edge.

### Metrics and status

On the edge (`/metrics` and the status page): `seshat_edge_snmp_available` (0 when the seal key could not be used),
`seshat_edge_snmp_enabled`, `_active`, `_requests_total`, `_ok_total`,
`_refused_total{rule}` (the safety rule that refused, or the error code), `_timeouts_total`, `_rows_total`, `_pdus_total`
(requests sent to devices) and `_ops_total{op}`.

## Polling on the edge

An edge on a network the server cannot route to can run the **Device Tracker pollers and the knowledge base's SNMP
lookup** for the devices of its own site and VRF. The server polls from its own network, so on a management VLAN with
no gateway nothing is tracked; the edge sits on that network and polls from there, with the packs, the intervals, the
spreading and the backoff of the server (they are the same code), and sends the results upstream.

Nothing changes for whoever reads the data: the results are stored in the same interval tables, stamped like
server-polled results, so lookups, history and the [portal contract](schema/tracker.md) are the same. Polling on the
edge is read-only like polling from the server: the pollers offer Get, GetNext and GetBulk and nothing else, and the
build-time scan for SNMP write calls reads this code as well.

### Who polls a device

**One poller per device: the server, or one edge. Never both.** It is a setting:

- **Per site**: *Polled by* `server` (the default) or `edge:<id>`, on the Tracked devices page (*Who polls the devices*, shown once an edge exists) or
  `PUT /api/tracker/polling/sites/{site}` with `{"polled_by": "edge:<id>"}`. The edge must collect that site. It owns the
  devices of the site that are in **its VRF**; devices of the site in other VRFs stay with the server.
- **Per device**, overriding the site: `PUT /api/tracker/devices/{id}/polled-by` with `""` (follow the site), `"server"`
  or `"edge:<id>"`. The edge must hold the device's site and VRF (`400 validation_failed`, field `polled_by`).

Both are for administrators and operators and are audited (`tracker.polling.site`, `tracker.device.polled_by`).
`GET /api/tracker/polling` lists the sites, who polls each, how many of their devices an edge polls, and the edges with
the health of their pollers. `GET /api/tracker/devices` shows the **owner** of every device: `owner.polled_by`
(`server` or `edge:<id>`), where it comes from (`device`, `site`, `default`), the edge's name and state, and the
device's own setting in `tracker.polled_by`. Only devices that are *enabled* for tracking are polled, as on the server.

What keeps the two apart:

- The server's scheduler leaves a device an edge owns alone: no timer polls, no trap-triggered port polls, no poll-now.
  Pollers sharded with `SESHAT_TRACKER_SHARD` all read the same setting, so every shard skips the device.
- The edge polls exactly the devices its configuration lists, and nothing else.
- The server stores a poll result only from the edge that owns the device **now**, for a device in that edge's scope. A
  result from a former owner (a poll that was queued during an outage, or that finished after a hand-back) is refused and
  counted (`seshat_tracker_edge_poll_refused_total{reason="not_owner"}`).

### Changing the poller

| Change | What happens |
|---|---|
| server to edge | The server's pollers stop at once (their replicas look at the setting every few seconds), also for a device that was queued for a worker. The edge learns of the device at its next configuration sync (its heartbeat asks for it within 30 s), adopts the schedule the server had (the same next poll, the same count of failures in a row, so no gap and no restart of the backoff), and does not poll it for 15 s after it became the edge's. |
| edge to server | The server waits **two minutes** before it polls the device (`hold_until` in the owner). The edge stops at its next sync, within a minute. A result the edge sends after that is refused. |
| edge to another edge | The same two-minute wait protects the new edge (it is told how long to wait). |
| the edge is deleted | What it polled goes back to the server, held off for the same two minutes, before the edge is deleted (an edge that is offline never hears that it is gone). |
| away from an edge that is **offline** | Refused with `409 edge_offline`: an edge that cannot reach the server keeps polling on the configuration it has, so moving its devices would have both poll until it is back. Repeat the request with `"force": true` to accept that; the edge stops as soon as it reconnects and its late results are refused. |

Nothing about a handover compares the server's clock with the edge's: the edge is sent *durations* (how long to wait,
how long until the next poll was due), and the times in its records are corrected by the offset the heartbeat reply gives
(to the second). Poll-now of a device still inside its hold or grace answers `409 handover_in_progress` with `Retry-After`.

### When the edge is offline

**The server does not take over a device from an edge that is offline, and says so.** An edge that cannot reach the server
goes on polling and buffers the results on disk; they arrive, in order, when the link is back
([the stream](#the-stream)), and none is lost. Meanwhile the device's tracker status shows what the edge last reported,
and its owner shows the edge in state `offline`. Poll-now answers `503 edge_offline`. Polling the device from the server
instead would double-poll it as soon as the edge returns and hides that the network behind the edge is cut off; to hand it
back, move it to the server (with `force`).

**The lease.** So that an edge that cannot hear about a handover does not poll for ever on a stale list, scheduled polls run
only on a configuration the server confirmed in this process (a configuration sync, or a heartbeat that says it is current),
and for **ten minutes** after the last confirmation. After that an offline edge goes on collecting and buffering its events
and relay, but stops its scheduled polls until it reaches the server again; a restart does not poll until the first sync.
The trade-off: a link outage longer than ten minutes leaves a gap in the polls (the results are not buffered because they
were never taken), in exchange for never double-polling a device the server gave to someone else while the edge was away. A
poll already running finishes, and its result is refused if the device is no longer the edge's. The Edges page shows the pollers' health and warns when an offline edge
polls devices; an alert on `seshat_edge_up == 0` covers the rest.

### Credentials, and the reads switch

The pollers use the profiles of the edge's site that the on-demand reads use, kept as described under
[What an edge keeps on disk](#what-an-edge-keeps-on-disk) (`snmp-profiles.enc`), with the same rules: a blank community
keeps the stored one, *Clear* removes it, a changed profile reaches the edge at its next sync. SNMPv3 users and the
per-VRF communities of a device (tracker settings) come the same way.

**The switch.** The credentials are sent to an edge when its `snmp_read.enabled` is on **or** when it owns at least one
device. `snmp_read.enabled` alone decides whether clients may run [on-demand reads](#snmp-reads) through the edge: an edge
that only polls has them off, and refuses reads with `snmp_disabled`. The rest of the `snmp_read` section (the
`allow` list, the `limits`, `source_address`, `poll_workers`) applies to the pollers whether the reads are on or not.

The edge enforces the same safety rules before a datagram leaves, and counts a refusal under its rule
(`seshat_edge_poll_refused_total{rule}`): `never_poll`, `edge_ceiling` (`SESHAT_EDGE_SNMP_CEILING`), `edge_allow_list`
(`snmp_read.allow`) and `profile_allowed_cidrs`. A scheduled poll goes to a device of the inventory, so unlike a
client-named target it does not need the profile to list networks of its own (the server's pollers do not either). An edge
that polls and has no ceiling says so in its log: it then trusts the server's configuration alone.

### The budget

Every SNMP request of a scheduled poll takes a slot of the **same per-device budget** as the on-demand reads
(`snmp_read.limits.device_rate`, 20 requests per second by default): a repeat of a request the device did not answer
takes its own slot too (the retries of the profile are capped at two). A window of reads plus a scheduled poll stays under
what the switch's CPU is given. `snmp_read.poll_workers` (default 4, at most 32) bounds the device polls running at
once; they run on their own goroutines and never delay the event path.

### Results upstream

A poll produces *poll records* ([the stream](#the-stream)): the observations of the poll (in records of at most 2,000, a
bigger poll is split) and one result record with the outcome (status, error, duration, the next poll, the failures in a
row) and the port state of a full poll. The server decides what attributes them: the **site and tenant are those of the
device in the server's knowledge base**, exactly what a server poll stores, never what the edge says. Each observation is
rebuilt from the fields the pollers set for its kind (a location, an L3 binding, a wireless client or a user), nothing else
rides along; its MAC and IP must be valid, an L3 VRF must be one the device is set up to be polled in, numbers are in range,
text is valid UTF-8 without NUL and at most 512 bytes (cut on a character), a timestamp more than 5 s in the future is
clamped and one from before the edge owned the device is refused. One bad observation is dropped and counted
(`seshat_tracker_edge_poll_refused_total{reason="obs_*"}`); the rest of the batch is stored. Results for a disabled device
are refused. Per edge the server takes at most 200 poll records a second (burst 1,000), and stores one poll of a device
a second; over that the edge is asked to retry. A MAC's identity site and tenant can only be set to those of a device the
edge owns. As for a server
poll, the VRF column of an L3 binding is the VRF context of the ARP table the device reported (`default` when it names
none). The edge's own site and VRF decide which devices it can own, not a stamp on the rows.

The result record is the device's row on the Tracked devices page: last poll, status, error, duration, MACs, the failures
in a row and the next poll are the server's own columns, written by whoever polled. The port state of the last full poll
is kept in the memory of the server node that received it (as the state of a poll is on the node that ran it), so the
trap handling and the ports view of an edge-polled device work on that node.

### Poll now and status

`POST /api/tracker/devices/{id}/poll` is unchanged for the caller (and for the `tracker.poll` capability and the
`tracker:read` token, with their limits): for a device an edge owns the server forwards it to the edge over the control
channel, the edge polls and answers with the same report, and the response adds `owner` and `results_stored`
(`true` once the edge's results have reached the server, which the call waits for up to 20 s; `false` means they are on
the stream and arrive in order). Errors: `503 edge_offline`, `409 not_polled_here` (the edge has not received the device yet:
its configuration syncs within a minute), `409 handover_in_progress` (a hand-back is settling). A link-up trap that reaches
the server on the edge's stream is forwarded to the edge as a single-port poll.

### Knowledge base lookups

The knowledge base's [active SNMP lookup](device-kb.md#opt-in-snmp-polling) of an address in a scope an edge owns (a site
setting naming the edge, or a device whose own setting does) is made **by the edge**, from its network, with the same
OIDs, the same facts and the same safety rules and budget as the pollers; the server stores what comes back. The profile
that enables it is still Settings, Connectors, Active SNMP polling.

### Poll source address

A dual-homed edge should poll from its management-network address. `snmp_read.source_address` (Edges page, SNMP reads) is an
IP address or the name of a network interface of the edge host; SNMP to devices, the reads and the pollers, leaves from
it. With an interface the edge uses its address of the target's family, preferring one in the target's own network. An
address of the other family, or an interface with none, is logged and the host's routing decides.
`SESHAT_EDGE_SNMP_SOURCE` on the edge host overrides the server's setting (the edge's operator knows its interfaces). Empty:
the host's routing.

### The upstream queue

Poll results share the edge's upstream disk queue with its events. They are only queued while the queue is below 80% of its
size (`upstream.queue_max_mb`); past that the poll fails visibly (`seshat_edge_poll_send_failures_total`, the device's
status) and is repeated, which leaves the rest of the queue for events; a flood of poll results cannot take the room the
events need, and a flood of events cannot silently swallow results.

### Health and metrics

The edge's status page shows its pollers (devices, polls running, in backoff, results, SNMP requests, observations sent, and
a line per device with its status and next poll). On the edge `/metrics`: `seshat_edge_poll_devices`, `_running`,
`_paused_devices`, `_polls_total{status}`, `_requests_total`, `_records_total`, `_observations_total`, `_send_failures_total`
(a result the upstream queue did not take: the poll is reported as failed), `_refused_total{rule}` and
`_last_poll_timestamp_seconds`. The heartbeat carries a summary, shown on the Edges page. On the server:
`seshat_tracker_edge_poll_results_total{status}`, `_observations_total` and `_refused_total{reason}` (`not_owner`,
`out_of_scope`, `kind`, `malformed`).

### What differs from polling from the server

- An edge knows the devices of its own site and VRF only. When it decides whether the neighbour on a port is
  infrastructure (and so the port an uplink) it uses its capabilities and what it knows of its own scope; a switch of
  another site on a trunk is recognised by its LLDP or CDP capabilities, not by the server's inventory.
- The server must be of a release that accepts poll records: upgrade the servers first (the documented order). An older
  server never lists devices for an edge, so the edge polls nothing; during a rolling upgrade of a cluster a replica that
  does not yet know the record type rejects it (counted, skipped) while a newer replica stores it, so a few results of an
  edge can be lost until every replica is upgraded. Assign devices to an edge after the upgrade is complete.
- Whether an edge is online is read from the database (when it was last heard from, by any replica), so every replica
  of a cluster agrees on it and on whether moving devices away from it needs `force`.

## Footprint

Measured on one 16-core development host, with the edge enrolled against a server on the same box,
syslog over UDP (RFC 5424 messages from `seshat-gen`), the pack set as shipped (34 MIB modules, 9 grammars):

| | RSS |
|---|---|
| idle, after start | about 41 to 43 MB |
| 10,000 events/s for 30 s (300,000 events) | 58 to 62 MB peak, queue empty, 0 dropped, 0 duplicates at the server |

Target from the specification: under 100 MB.

## Limits of this release

SNMPv3 trap users and TLS syslog listeners are not distributed to edges (the SNMP polling profiles are, but only to an edge that has the [SNMP reads](#snmp-reads) switched on or [polls devices](#polling-on-the-edge)); the Edges drawer edits the SNMP and syslog listeners but the `flow` block is API/JSON only; a changed packs set or
configuration restarts the pipeline instead of reloading it; one batch in flight per edge (the measurement above kept up
with 9,000 events/s; the ceiling was not measured).
