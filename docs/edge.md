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
| Shared address | For a member of an [edge group](#edge-groups) whose group has a VRRP configuration, the built-in VRRP engine, so that the members share one receiving address ([VRRP on the edges of a group](#vrrp-on-the-edges-of-a-group)). None for an edge in no group and for a group without one. |
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
- `vrrp-key.enc`: the advertisement key of the edge's group ([VRRP on the edges of a group](#vrrp-on-the-edges-of-a-group)),
  only on a member whose group has a VRRP configuration. Not in `edge.json` (which keeps the rest of the section and says
  the key is in this file); encrypted like `snmp-profiles.enc`, with the same limits of what that protects. It is what lets a
  restarted member run VRRP on its last configuration while the server is unreachable. It is removed when the
  configuration is.
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

**A target can name an edge group** (`run_on: "group:<id>"`, [Edge groups](#edge-groups)): the placement reconciler
assigns it to one healthy member, the member dials it on the group's lease instead of `telemetry.lease_minutes`, and the
server never dials it. The group needs a member first; a target that names a group that does not exist is refused.

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

The targets an **edge group** assigned to the edge (they carry `group` in the configuration) have a fence of their own:
the group's lease (`lease_secs`, 60 s by default), counted from before the request that got the server's answer was sent,
on a monotonic clock and the wall clock. When it ends the sessions of those targets are closed, a dial in progress
included, and they start again at the next answer. The targets the edge owns by its own id keep `lease_minutes`, also on
a member of a group. `seshat_edge_telemetry_group_fence_open` says whether the group's targets may run.

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
| `SESHAT_EDGE_VRRP_CEILING`, `SESHAT_EDGE_VRRP_CEILING_FILE` | The edge's own bound on the addresses its group's VRRP configuration may make it hold ([the edge-local ceiling for VRRP](#the-edge-local-ceiling-for-vrrp)). |
| `SESHAT_EDGE_SNMP_SOURCE` | The address, or the name of the network interface, the edge sends SNMP to devices from (the reads and the pollers). Wins over the server's `snmp_read.source_address` ([Poll source address](#poll-source-address)). |
| `SESHAT_SNMP_TRAP_LISTEN`, `SESHAT_SYSLOG_UDP_LISTEN`, `SESHAT_SYSLOG_TCP_LISTEN`, `SESHAT_FLOW_*_LISTEN` | Local listen addresses, used when the server's configuration leaves them empty. |
| `SESHAT_PACKS_DIR` | Packs shipped with the install; the server's packs replace them. |
| `SESHAT_SECRET_KEY` | Not needed. |

Prometheus: `/metrics` on the status listener (`seshat_edge_link_up`, `_assigned_sequence`, `_acked_sequence`,
`_events_in_total`, `_events_sent_total`, `_events_rate_limited_total`, plus the usual input, queue and KB
families and process metrics); on the server `seshat_edge_up`, `_last_seen_timestamp_seconds`,
`_queue_depth`, `_lag_seconds`, `_events_received_total`, `_events_duplicate_total` per edge, plus
`seshat_edge_sequence_jumps_rejected_total` and `seshat_edge_auth_refused_total{reason}`. A member of a group with VRRP
also exports `seshat_edge_vrrp_*` on the edge and the server `seshat_edge_group_vip_holder{group,instance,edge}`
([Status and metrics](#vrrp-status-and-metrics)).

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

**To an edge group.** `POST /api/edge-groups/{id}/relay` takes the same body, headers, errors and audit records and opens the
session through one member of the group that has a control connection to a server node ([Edge groups](#relay-and-snmp-reads-through-a-group)).
An integration client needs `edge.relay.tcp` and the entry `group:<id>` in the `edges` list of its scope (or `*`): a scope
that lists the members does not reach the group, and one that lists the group does not reach its members by
`POST /api/edges/{id}/relay`. Two more errors: `404 not_found` for a group that is not there, and `409
group_policy_differs` while the members' relay sections differ. The audit records have the `group`, the
member the session ran through as `edge` and `members_tried`.

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

The same ceiling bounds the scheduled polls and the ICMP echoes of the [reachability probes](#reachability-probes): an address
outside it is never pinged.

### The API

All three routes need an administrator token, or an [integration client](integrations/README.md) token that holds
`edge.snmp.read` and whose scope names the edge (`out_of_scope` otherwise; the client's rate limit answers
`429 limit_exceeded`).

**`POST /api/edges/{id}/snmp`** (and `POST /api/edge-groups/{id}/snmp`, [below](#relay-and-snmp-reads-through-a-group))

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
Through an edge group the server keeps the same account for the whole group, so that a client does not get more by
going through the group ([Edge groups](#relay-and-snmp-reads-through-a-group)).

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

**One poller at a time per device: the server, one edge, or the one member of an [edge group](#edge-groups) the group assigned it to. Never two.** It is a setting:

- **Per site**: *Polled by* `server` (the default), `edge:<id>` or `group:<id>`, on the Tracked devices page (*Who polls the devices*, shown once an edge exists) or
  `PUT /api/tracker/polling/sites/{site}` with `{"polled_by": "edge:<id>"}`. The edge must collect that site. It owns the
  devices of the site that are in **its VRF**; devices of the site in other VRFs stay with the server.
- **Per device**, overriding the site: `PUT /api/tracker/devices/{id}/polled-by` with `""` (follow the site), `"server"`,
  `"edge:<id>"` or `"group:<id>"`. The edge (or the group) must hold the device's site and VRF (`400 validation_failed`, field `polled_by`).

Both are for administrators and operators and are audited (`tracker.polling.site`, `tracker.device.polled_by`).
`GET /api/tracker/polling` lists the sites, who polls each, how many of their devices an edge polls, and the edges with
the health of their pollers, and the edge groups. `GET /api/tracker/devices` shows the **owner** of every device: `owner.polled_by`
(`server`, `edge:<id>` or `group:<id>`), where it comes from (`device`, `site`, `default`), the edge's name and state (for a
group, the member it assigned, in `edge_id`, and `group_id`), and the device's own setting in `tracker.polled_by`. Only devices that are *enabled* for tracking are polled, as on the server.

What keeps the two apart:

- The server's scheduler leaves a device an edge owns alone: no timer polls, no trap-triggered port polls, no poll-now.
  Pollers sharded with `SESHAT_TRACKER_SHARD` all read the same setting, so every shard skips the device.
- The edge polls exactly the devices its configuration lists, and nothing else.
- The server stores a poll result only from the edge that owns the device **now**, for a device in that edge's scope. A
  result from a former owner (a poll that was queued during an outage, or that finished after a hand-back) is refused and
  counted (`seshat_tracker_edge_poll_refused_total{reason="not_owner"}`). For a device an edge group owns the assignment is
  read from the database for every result, so a member that lost the device is refused at once on every node.

### Changing the poller

| Change | What happens |
|---|---|
| server to edge | The server's pollers stop at once (their replicas look at the setting every few seconds), also for a device that was queued for a worker. The edge learns of the device at its next configuration sync (its heartbeat asks for it within 30 s; a member of an edge group heartbeats every 10 s), adopts the schedule the server had (the same next poll, the same count of failures in a row, so no gap and no restart of the backoff), and does not poll it for 15 s after it became the edge's. |
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
poll already running finishes, and its result is refused if the device is no longer the edge's; for the devices an
[edge group](#edge-groups) assigned to the edge the lease is shorter and a running poll is cancelled when it ends. The Edges page shows the pollers' health and warns when an offline edge
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

For an [edge group](#edge-groups) the lookup of an address whose device the group assigned is made by the member that has the
device and by no other, on the group's lease (it ends with it). While the device is being handed to that member, that is
inside the hold and the short wait after the assignment, the lookup is **refused** with `handover_in_progress` (the member
refuses it too, and `not_polled_here` for a device it does not list yet), as poll-now is; the knowledge base treats it as any
failed lookup and asks again on its own schedule, so the lookup is not made to wait. An address that no member holds (no
device record, or a device not yet placed) is looked up by the connected members in turn, lowest-numbered first, and the
next is tried when one fails; it is not held.

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

### Reachability probes

With [reachability probes](device-tracker.md#reachability) on (the default; the tracker settings, with a per-site override, and
`SESHAT_TRACKER_REACH=0` on a server node to turn them off there), the server sends the settings of the edge's site to every edge that polls devices (the `reach` part of the tracker section of the configuration: interval, echo
count, timeout, failures before down, which checks), and the edge probes the devices it owns: an ICMP echo and a
`sysUpTime.0` GET with the device's profile. The probe is the server's own prober, run under
the edge's rules:

- **One poller.** A device is probed by the edge that owns it, under exactly the conditions of a scheduled poll: the edge
  lists it, the hand-over wait the server set is over (`not_before_s`: the previous poller may still be probing), and the edge
  holds a valid lease. For a device of an [edge group](#edge-groups) the lease is the group's short lease, counted from before
  the request that confirmed it, and **a probe that is running when the lease ends is cancelled and sends nothing**; a probe
  that finishes after the device was handed to another member is dropped too. The server checks the same thing again when the
  result arrives: a result is taken only from the edge (and, for a group, the member) that the database says owns the device
  *now*, so a hand-over never has two members probing the device or two sets of results. Nothing is probed by the edge
  after the settings go (the server turned the probes off, or the edge left the device list).
- **The never-poll list and the ceiling.** An echo goes only where an SNMP request may go. Before a packet leaves, the edge
  applies the never-poll addresses (loopback, link-local, multicast, unspecified), the edge-local
  [ceiling](#the-edge-local-ceiling-for-snmp-reads) (`SESHAT_EDGE_SNMP_CEILING`) and the pushed allow-list, the checks
  the polls use; a refused target is not pinged and its result names the rule (`never_poll`, `edge_ceiling`, `edge_allow_list`),
  counted with the polls' refusals in `seshat_edge_poll_refused_total{rule}`. The SNMP read goes through the poller's session
  and takes its slots from the same per-device budget as the polls.
- **ICMP sockets.** The edge opens an unprivileged ICMP datagram socket when the host's `net.ipv4.ping_group_range` includes
  the edge's group, else a raw socket when it has `CAP_NET_RAW`. With neither, ICMP is unavailable on that edge: its status page
  shows `icmp unavailable: <reason>`, `seshat_edge_poll_reach_icmp_available` is 0, each result carries the reason and the
  server shows it on the device and in the status; the SNMP check carries on, and no device is called down because of it.
  How to grant either (the default `seshat-edge` unit and `compose.edge.yaml` grant none and are unchanged):
  [Device Tracker, Reachability](device-tracker.md#reachability), the compose override
  [`deploy/compose/reach-icmp.example.yaml`](../deploy/compose/reach-icmp.example.yaml) and the `CAP_NET_RAW` drop-in
  ([packaging](packaging.md#capabilities)). The echo leaves from the host's routing address (the poll source address
  setting applies to SNMP only).
- **Results upstream.** Each probe is one poll record of the kind `reach` on the stream, in the same disk queue (it is
  counted in the 80 % share of poll results). The edge sends what it measured and nothing else; **the state, the metric
  samples and the `seshat.reachability` events are made by the server**, which keeps the state in its database, so a device that
  changes hands, or an edge that is replaced, continues the same state without a spurious "up". The server bounds every
  value (statuses, counts, times, strings), refuses a result for a device the edge does not own now, a result measured
  before the edge owned it, results while its own probes are off, and a result for a device that follows another one by less than
  half the probe interval (an edge that probes faster than it was told is flooding); these are counted as refused and never
  retried. Over its own rate (200 records a second per edge with the poll records) the edge is asked to retry. A result that is
  not newer than the last one taken for the device is dropped by the state.
- **Status and metrics.** The edge's status page shows the reachability probes (settings, the ICMP socket, probes by
  check and result, refusals, cancellations). On the edge `/metrics`: `seshat_edge_poll_reach_probes_total{check,result}`,
  `_refused_total{rule}`, `_probes_cancelled_total`, `_send_failures_total`, `_icmp_available` and `_running`.

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

### Metrics polls on the edge

The metrics class (docs/device-tracker.md, "SNMP metric polling") runs on the edge that owns the device, by the same
ownership as the tracker polls: the server leaves the device alone, the edge is served the metrics settings with it
(interval, interface filters, series cap), and a group member polls it only inside the group's lease. The samples enter
the edge's pipeline as `seshat.metric` events, under the telemetry rate limit (`telemetry.max_events_per_second`) and its
share of the upstream queue, and travel on the event stream; the server marks them with the edge and the site. A poll the
limit cut short is reported `partial` with the number dropped. The status of each metrics poll is a record of its own on the
same stream (`metrics`: status, error, series, next poll), so the Tracked devices page shows it whoever polls.

When the group lease ends, the metrics poll running on a member is cancelled before it emits anything: its requests stop,
no samples and no status record are sent, and the member that takes the device over waits out the hand-over hold before its
first metrics poll, as it does for the tracker poll. The metrics class has its own schedule (60 s spread inside the
interval), so a device handed over starts its metrics cadence at a spread time after the hold rather than inheriting the
previous poller's.

## Edge HA

Edge HA keeps an edge's work going when one edge host stops. It has two halves, set up independently on the server for a
**group** of edges:

- **Receiving.** Syslog, traps, flows and telemetry dial-out reach one shared address, held by one member at a time. If the
  holder stops, another member takes the address within seconds ([VRRP on the edges of a group](#vrrp-on-the-edges-of-a-group)).
- **Pulling.** Device polling, the knowledge base's SNMP lookups, telemetry dial-in targets, the TCP relay and on-demand SNMP reads
  are done by one member at a time. If that member stays away for the group's grace time, the server gives its share to the others
  ([Edge groups](#edge-groups)).

The server hosts of a cluster have their own, separate high availability ([`ha.md`](ha.md)). This chapter is about the edges.

### What a group is, and when to use one

A group is a named set of edges of **one site and one VRF**. An edge is in one group at most. The group has timing (grace,
lease, damping), an optional shared address, and the work that names it: a site or device whose *Polled by* is `group:<id>`,
a telemetry target whose *Run on* is `group:<id>`, and relay and SNMP-read requests addressed to the group. Every device and
target still has exactly one poller at any moment: the server picks one healthy member for it.

Use a group when the network behind an edge can only be reached through edges and one edge host is a single point of failure
for it: two or three edge hosts on that network, one of them dying should not stop the polling, the telemetry or the events.
The pulling half works with members on any network the devices can be reached from. The shared address needs all members on
one layer-2 segment that forwards multicast `224.0.0.18`.

Do not use a group when a single edge is enough, when the edges are on different networks (a group's members share a site and
VRF, and the devices must be reachable from each of them), or on SQLite nodes that sync as cluster peers (refused,
[Edge groups](#edge-groups)). A group without a shared address still shares the pulling; the devices then send
to a member's own address, or to an address kept by something else such as keepalived.

### What moves, and how fast

| What | Moves when | How long (defaults) | Set by |
|---|---|---|---|
| Receiving address | the holder stops cleanly (SIGTERM, `docker stop`, `systemctl stop`) | under a second: 0.69 s measured | `advert_interval_ms` |
| Receiving address | the holder is killed, dies, or is cut off from the segment | 3.2 to 4 s predicted; 3.6 s measured | `advert_interval_ms` |
| Receiving address | the holder is cut off from the server but still on the segment | its priority drops after `link_down_secs`, then a healthy member takes the address after the preempt delay: 26.4 s measured with `link_down_secs` 10 and a preempt delay of 15 s | `health`, `preempt_delay_ms` |
| Devices and telemetry targets | the server has not confirmed the member for the grace | 120 s after the last confirmation. The member's own lease (60 s) ended before that, so it has stopped | `grace_secs`, `lease_secs` |
| Relay and SNMP reads | per request, the next healthy member is asked | at once, but only if the request was proved not sent | none |
| A member that returns: devices and targets | it has been healthy for the damping time | 300 s, then a tenth of the devices at a time (1 to 50), each waiting out a hold | `rebalance_damping_secs` |
| A member that returns: the address | the member has a higher priority than the holder | after the preempt delay (30 s by default); 18.6 s measured with a delay of 15 s | `preempt_delay_ms` |

The measured times are from a run with three edges, priorities 120, 100 and 80, an advertisement interval of 1 s and
`link_down_secs` 10, on two Docker bridges. The moves of devices and targets follow from the settings; they are covered by
tests with shortened timing and have not been timed on a live group.

**Grace, lease and damping.**
The **lease** is how long a member keeps polling after the server last answered it. The server asks group members for a
heartbeat every 10 s, so a lease of 60 s is six chances to renew. When the lease ends, the member cancels the polls and the
dial-in sessions that are running; it does not let them finish. The **grace** is how long the server waits, counted from the
last answer it gave the member, before it moves that member's share. It must be at least the lease plus 30 s, so the member has
stopped before anything moves and nothing is polled twice. The **damping** is how long a member that came back must stay
healthy before it is given devices again.

**Holds.** A device or target that moves away from a member that may still be running (a rebalance, a removal, a deleted
group, a setting changed to another owner) is held: the new owner waits at least two minutes, and at least the lease of the
member it came from, before it starts. A move away from a member that has been silent for the whole grace needs no hold,
because its lease ended 30 s before the grace did. While a device is in a hold, poll-now answers `409 handover_in_progress`
and knowledge-base lookups for it are refused, because nobody is allowed to poll it yet.

### Worked example: three edges, one address

Three edges `edge-a`, `edge-b` and `edge-c` sit on one layer-2 segment, `192.0.2.0/24`, at site `site-1`. They have the
addresses `192.0.2.21`, `192.0.2.22` and `192.0.2.23`. The devices send syslog, traps and flows to one address,
`192.0.2.10`. The server polls nothing here; the group does: `Example Switch 1` to `Example Switch 3` are polled by SNMP, a
router at `192.0.2.101` is read by JTI dial-in, and an operator uses the relay to reach a host at `192.0.2.150:22`. Polling,
the JTI target and the relay should all survive the loss of one member.

1. **Enrol the edges.** On the server, Edges, *Add edge* three times: site `site-1`, the ids `edge-a`, `edge-b`, `edge-c`.
   On each box run `seshat edge enroll` with its token and start the edge ([Setting one up](#setting-one-up)). All three must
   run this release, and the server nodes must be upgraded first. Check that each shows `online`.

2. **Create the group and add the members.** Edges, *Edge groups*, *New group*: site `site-1`, the name `Segment 1`, the id
   `seg1`. Open it (*Manage*) and add the three edges with *Add a member*. The same by API:

   ```
   POST /api/edge-groups
   {"id": "seg1", "name": "Segment 1", "site": "site-1"}

   POST /api/edge-groups/seg1/members
   {"edge_id": "edge-a"}
   ```

   (again for `edge-b` and `edge-c`). Only enrolled edges of the group's site and VRF that are in no group can join.

3. **Name the group where an owner is chosen.**
   - Polling: Device Tracker, *Who polls the devices*, site `site-1`, *Polled by* the group; or
     `PUT /api/tracker/polling/sites/site-1` with `{"polled_by": "group:seg1"}`. A single device can override the site
     (`PUT /api/tracker/devices/{id}/polled-by`). The server now assigns the devices evenly to healthy members, within
     10 s.
   - JTI dial-in: Inputs, Telemetry, the target for `192.0.2.101`, *Run on* the group; or `"run_on": "group:seg1"` in the
     target. The same applies to gNMI targets.
   - Relay and SNMP reads: nothing to set on the group. Give the three members the **same** `relay` and `snmp_read` sections
     (Edges, *Configure*), with `192.0.2.150:22` in the relay's allow-list, and address requests to
     `POST /api/edge-groups/seg1/relay` (and `/snmp`). While the members' sections differ the group's routes answer
     `409 group_policy_differs`, and the group view says which sections differ.

4. **Configure the shared address.** In the group, *Shared receiving address*, *Set up*; or:

   ```
   PUT /api/edge-groups/seg1/vrrp
   {"instances": [{"name": "receive", "vrid": 51, "vips": ["192.0.2.10"],
                   "priorities": {"edge-a": 120, "edge-b": 100, "edge-c": 80}}]}
   ```

   The VRID must not be used by another VRRP speaker on the segment, including the server cluster's own. The first save makes
   the group's advertisement key. The server refuses a configuration whose penalties cannot work with these priorities
   ([Health penalties](#vrrp-on-the-edges-of-a-group)); the status may still show advisory warnings about them.

5. **Grant the capabilities** on each member. VRRP needs `CAP_NET_ADMIN` and `CAP_NET_RAW`, which the default unit does not grant:

   ```
   install -D -m 0644 /usr/share/seshat-edge/systemd/drop-ins/edge-vrrp.conf /etc/systemd/system/seshat-edge.service.d/edge-vrrp.conf
   systemctl daemon-reload && systemctl restart seshat-edge
   ```

   For containers use [`deploy/compose/edge-vrrp.example.yaml`](../deploy/compose/edge-vrrp.example.yaml). Without them the
   member reports VRRP `unavailable` and names the missing capabilities; it tries again every 5 s. If you want an
   edge-local limit on the addresses a member may hold, set `SESHAT_EDGE_VRRP_CEILING=192.0.2.10` on it
   ([The edge-local ceiling for VRRP](#the-edge-local-ceiling-for-vrrp)).

6. **Point the devices at the address.** Syslog, trap and flow destinations: `192.0.2.10`. For dial-out telemetry, the
   collector address `192.0.2.10` and the port of the members' dial-out listener. Give the three members the same listener
   settings (Edges, *Configure*): the group does not copy them from one member to another. Events keep the sending device's own
   source address whichever member receives them.

7. **Allow every member's address on the devices.** Polling, SNMP reads, JTI and gNMI dial-in and the relay's connections leave
   from the member that has the work, from the member's **own** address (or the one set in `snmp_read.source_address`), never
   from `192.0.2.10`. So in each device's SNMP access list, in the management-plane access list for the dial-in port, and on
   any firewall between, allow `192.0.2.21`, `192.0.2.22` and `192.0.2.23`, not only one of them. A member that is not
   allowed shows up only when the work first lands on it.

8. **Check.** The group's row on the Edges page should read `3 of 3 healthy`. Open it: exactly one member says *Holds the
   address* for `receive`, with the others *Standing by*; the three members share the devices and the target (for example
   `3 of 7 devices`); *Unassigned* counts are 0; the last move reads *none yet*. `GET /api/edge-groups/seg1` has the same, and
   the metric `seshat_edge_group_vip_holder{group="seg1"}` is 1 for one member only. Send a syslog message to `192.0.2.10`
   and see it arrive stamped with the edge that held the address. On a fresh start expect the first holder about half a
   minute after the first save: the members get the new section at their next 10 s heartbeat, and the member with the highest
   priority takes the address after the preempt delay.

### When a member stops, and when it returns

`edge-a` holds `192.0.2.10`, polls part of the devices and dials the JTI target. Stop it.

- **At once.** A clean stop releases the address and sends a priority-0 advertisement: `edge-b` holds it within a second
  (0.69 s measured). A kill, a crash or a pulled cable takes 3.2 to 4 s (3.6 s measured). The group view shows the new holder and
  the reason of the transition (`master_down`, `peer`), and `seshat_edge_group_failovers_total{reason}` counts it. The devices
  keep sending to the same address and need no change.
- **Within the lease.** `edge-a` stops heartbeating. If it is running but cut off from the server, its lease ends 60 s after the
  server's last answer and it cancels its polls and its dial-in session. Its share is still `edge-a`'s in the server's records.
- **At the grace.** 120 s after the server's last answer from `edge-a` the member is `gone`. The server moves its devices and its JTI
  target to `edge-b` and `edge-c`, the least loaded first, in one batch with one audit record (`edge.group.move`, reason
  `member_offline`), and no hold, because the lease is over. The *Last move* line reads `member_offline`. Until then, for up to two
  minutes, those devices are not polled. Events are not affected: they went to the new holder from the first second.
- **Relay and SNMP reads.** A new request goes to a healthy member. A request that went to `edge-a` before it stopped is not
  repeated on another member unless it was proved not sent; a relay session that was open through `edge-a` ends and is not
  reopened by itself.

Start `edge-a` again.

- **The address.** `edge-a` has the highest priority, so it takes the address back after the preempt delay: 30 s by default, 18.6 s
  measured with a delay of 15 s. The address moves a second time, briefly. If you would rather it stayed where it is, give
  the members equal priorities or turn `preempt` off (health-driven failover needs it).
- **The share.** Nothing moves for 300 s (the damping). Then the group gives `edge-a` a tenth of its devices at a time (at least
  one, at most 50), each through a hold of at least two minutes, so no device is polled by two members. It ends evenly spread again.

If the whole server side is unreachable, see the first trade-off below: members stop polling after their lease, while receiving
and the address carry on.

### Trade-offs

Edge HA trades some things for others. These are the ones to know before you rely on it.

- **A server outage longer than the lease stops polling and dial-in.** A member cannot tell "I am cut off" from "the server is
  down". If the whole server side is unreachable for longer than the lease (60 s by default), every member stops polling the
  devices of the group and closes its dial-in sessions until it hears from the server again. Events keep buffering and
  receiving, and the shared address does not depend on the server link. To ride out longer outages raise `grace_secs` and
  `lease_secs` together; the price is a slower failover.
- **Knowledge-base lookups are refused during a hold.** A lookup of a device that is in a hold answers `handover_in_progress`
  (on the server and on the edge). The knowledge base treats it as "ask again later".
- **SQLite with peers is refused.** On SQLite nodes that sync as cluster peers, creating a group answers `409 groups_unavailable`
  and an existing group is not rebalanced, because no one place could decide who polls a device. A single SQLite node and
  PostgreSQL work.
- **A member with a broken poller keeps its share.** Health is the server's confirmation of the member and nothing else. A member
  whose link works but whose poller cannot reach the devices (no route, a full queue, a crashed worker) stays healthy and keeps
  its devices; the poll health it reports on the Edges page is not used for placement.
- **Two holders of the address are possible.** If the segment splits so that two parts of the group cannot hear each other, each
  part elects a holder. The same happens to a member that stays cut off from the server through a key rotation (the two minutes in
  [Rotating the key](#rotating-the-key)): it keeps the old key, hears nobody it can trust and claims the address itself. A member
  that was removed from the group while offline, and is still running on the segment, does the same until it hears the server
  (which tells it to stop). Take such an edge off the segment, or stop it.
- **Sealed SNMP credentials do not work on a group.** A sealed credential is sealed to one edge's key, and the group route does not
  know which member will take the request. Group SNMP routes take profile credentials only; a sealed credential is refused with
  `400 validation_failed`.
- **The SNMP spacing gate is per server node.** The group's per-client, per-device spacing is counted in memory on each server
  node and is not shared. A read that arrives on another node has that node's account, so a client's budget is one per node until
  the edge's own spacing answers. Across a failover on one node the account holds.
- **Group requests are refused while the members' sections differ.** The relay route answers `409 group_policy_differs` while the
  members' `relay` sections differ, and the SNMP routes while their `snmp_read` sections differ. Every member counts, whether or
  not it is up. The edge-local ceilings (`SESHAT_EDGE_RELAY_CEILING`, `SESHAT_EDGE_SNMP_CEILING`) are in each edge's environment,
  which the server cannot see: set them alike.
- **Holds compare addresses, not names.** A telemetry target given by DNS name and the same device given by IP address are not
  matched when holds are checked: that would need a lookup a settings change does not make. Use one form for a device.
- **The hold list is capped.** The telemetry settings keep at most 4000 records of targets that left their owner (the ones that end
  last are kept).
- **Upgrade order.** Upgrade every server node before the first group is created or used, then the edges. A server node that does not
  know `group:<id>` reads such a setting as unset and polls the device itself, next to the group. An edge of an older release is
  never confirmed, so it is never healthy and is given no work, and it takes no part in the address election.
- **Server clocks.** Server nodes of one cluster must keep their clocks within a few seconds; the 30 s between lease and grace is meant to cover it.

### Groups on the Edges page

Edges, *Edge groups*. Each group is a row: name, id, site and VRF, its devices and targets, who holds the address, how many members
are healthy, and a count of warnings. *Manage* (administrators) or *Details* (everyone else) opens the group:

- **Warnings**, from what the server reports: members that are old or have never been confirmed, no healthy member, devices and
  targets without a member, relay or SNMP-read sections that differ, a VRID the server cluster also uses, penalties that cannot do
  their job, more than one holder.
- **Members**, with their state (`healthy`, `not answering` for suspect, `gone`), when the server last answered them, and their
  share of the devices and targets. Administrators add enrolled edges of the group's site and VRF and remove members; a removal
  says that the share moves with holds and that the key is rotated.
- **Shared receiving address**: per address, who holds it, and for each member its VRRP state, its priority now and as set, and
  the last change with its reason. Administrators edit the configuration (addresses, interface and a per-member interface, priorities,
  preempt, delays, health penalties), rotate the key after a confirmation that says what a rotation does, or remove the address.
  The key itself is never shown (`auth_key_set` only). A refusal from the server appears on the field it names.
- **Settings**: name, lease, grace and damping. Site and VRF are fixed once the group exists.

Wherever an owner is chosen the list offers the groups of the right site: *Who polls the devices* (site and device), and *Run on* for
a telemetry target. The page shows the member a group has assigned, and moving away from a member that is offline keeps the
confirmation step it had. Viewers and operators see all of this and change none of it: group changes are for administrators; choosing
who polls a site or device stays with administrators and operators.

The sections that follow are the reference for each part: [Edge groups](#edge-groups) (placement, the lease, telemetry targets, the relay and SNMP
reads) and [VRRP on the edges of a group](#vrrp-on-the-edges-of-a-group) (the shared address, its key, penalties and capabilities).

### Edge groups

An **edge group** is a named set of edges of one site and VRF that share the polling of the devices that name the group.
Where one edge polls a network and it is the only way in, that edge is a single point of failure for the polling: its
devices stay `edge_offline` until an operator moves them. In a group the server assigns every device to one healthy
member, and moves a member's devices to the others when it stays away. The same holds for telemetry dial-in targets, and a
relay or an SNMP read can be addressed to the group. This is the part of edge high availability that moves the pulling:
polling, telemetry targets, the relay and the reads. The members can also share one receiving address
([VRRP on the edges of a group](#vrrp-on-the-edges-of-a-group)).

**Setting one up.** On the Edges page, *Edge groups* (see [Groups on the Edges page](#groups-on-the-edges-page)), or `POST /api/edge-groups` with `{"id": "...", "name": "...", "site": "...", "vrf": "..."}` and the timing
below; `POST /api/edge-groups/{id}/members` with `{"edge_id": "..."}` for each enrolled edge (`DELETE
/api/edge-groups/{id}/members/{edge}` takes one out). Every member collects the group's site and VRF, and an edge is in one
group at most. Then set *Polled by* of the site, or of single devices, to `group:<id>` (the group needs a member first).
Administrators change groups; everyone who may read the edges can read them (`GET /api/edge-groups`, `GET
/api/edge-groups/{id}`: members with their state and share, the devices of the group and how many have no member, the last
failover and its reason). Changes are audited (`edge.group.create`, `.update`, `.delete`, `.member.add`, `.member.remove`).
An `edge:<id>` setting works as before, also for a member.

| Setting | Default | Meaning |
|---|---|---|
| `grace_secs` | 120 | A member counts as gone, and its devices move, this long after the server last confirmed it. |
| `lease_secs` | 60 | A member polls this long after the server last confirmed it (30 to 3600). |
| `rebalance_damping_secs` | 300 | A member that came back must be healthy this long before it gets devices again. |

The server refuses a `grace_secs` shorter than `lease_secs + 30`: the margin is what makes a move safe (below).

**The lease of a member.** The server asks the members of a group for a heartbeat every 10 s instead of every 30 s (the
heartbeat reply says so; an edge in no group, and an older server, mean 30 s). Whatever the server answers to a heartbeat or a
request for the configuration renews the member's lease, and the answer is built in one database transaction: the server
advances the member's `confirmed_at`, reads the group and the devices assigned to the member in the same transaction (no
cache in between), and builds the etag and the device list of the answer from that read. A move of a member's devices
locks the same row and is made only if `confirmed_at` is still the value it judged the member by, so either the
confirmation comes first and the move is not made (`seshat_edge_group_moves_aborted_total`), or the move comes first and the
confirmation reads the list after it: the etag the member presents no longer matches and nothing renews. If the
transaction fails, or the owners cannot be read now, the answer renews nothing. The member counts its lease from the moment
**before it sent** the request that was answered, on a monotonic clock, so a slow answer shortens the lease and the member's
lease never ends later than the server's own reading (the server read the request after it was sent), with no comparison of
the two clocks. The latest confirmation decides: a lease the server shortened applies from the first confirmation under it, and a
confirmation whose request was sent earlier is ignored. The lease also ends when the wall clock says so (a host that was
suspended, whose monotonic clock stood still); a wall clock set back does not extend it. A member renews only on a
configuration it has fully applied: the etag in its heartbeat advances after the new device list is in force. For the
devices the group assigned to it the member polls only while that lease runs; **when it ends, the polls that are running are
cancelled** (the request in flight is not waited for, no further request is sent, nothing is sent or recorded for the poll),
and so is a knowledge-base lookup of the group. A member's devices that it owns by its own id (`edge:<id>`) keep the
ten-minute lease and are not cancelled.

**Placement.** One reconciler, on the leader of a cluster (PostgreSQL) or on the one node, every 10 s:

- A device that names the group and has no member goes to the least-loaded healthy member. Assignments are stored
  (`edge_group_assign`) and stay where they are; devices that already have a member do not move for balance's sake.
- A member is **healthy** when the server confirmed it in the last 30 s, **suspect** until the grace has passed since its last
  confirmation (nothing moves), and **gone** after that. Only then are its devices moved, to the healthy members, least-loaded
  first, in one batch with one audit record (`edge.group.move`: group, from, where to, reason `member_offline`, a sample of the
  devices). The new member waits no more than the edge's usual 15 s: the old one's lease ended at least 30 s before the grace
  did, so it has stopped, and a confirmation that lands before the write stops the move. For as long as the server has a record
  of the member (its edge row), the member's grace is never less than the longest lease the server has served it plus 30 s: the
  server raises that record before it serves a longer lease and lowers it only when the member presents the etag of a
  configuration that carries the shorter lease (the etag covers `lease_secs`), and a lowering is written only if the record
  still has the value it was decided on, so a shortened lease does not shorten the grace of a member that has not adopted it.
  A member whose credentials were rotated is judged by its last real confirmation; one never confirmed, from its newest
  assignment plus the grace. The hold of a device that leaves a member (a move, a release, a removal) is one lease of that
  member: the longest it may be holding, or the group's if that is longer, counted from the moment the move is written. When
  a member leaves the group or is deleted, that hold is stamped on its assignments in the same transaction, because its edge row
  may be gone before the devices are moved.
- **Health is the server's confirmation and nothing else.** A member whose heartbeats and configuration checks are
  answered is healthy, whatever its pollers are doing: a member with a broken poller (no route to the devices, a full
  queue, a crashed worker) but a working link keeps its share. The poll health it reports on the Edges page is not
  used for placement.
- After the server starts it judges nobody for one grace (a server that was down has heard from no one, which says nothing
  about them), and with **no healthy member it moves nothing**.
- A member that was gone and is back gets a share again only after it has been healthy, without a break, for
  `rebalance_damping_secs`, and then a few devices at a time (a tenth of the group's devices, at least one and at most 50 per step) through the normal
  hand-over: the new member is held off for the group's lease (at least the two minutes of a hand-back), the old one stops at
  its next sync, and no further step starts while one is settling. A member that comes and goes inside the grace changes
  nothing; one that is gone for longer loses its share once and does not get it back by being seen now and then.
- A device that stops naming the group (its setting is changed) is released, not forgotten: its row keeps the member and the
  hold of a hand-back until the hold has passed, so a device that names the group again waits for the member that may still be
  polling it. A hold of the settings is never shortened by a later change either (a device that goes from a group to the
  server and on to an edge waits out the group's lease).
- A member taken out of the group, or a deleted edge, has its devices moved to the others with the same hold; the last member
  cannot leave, or be deleted, while devices or telemetry targets name the group (`409 group_in_use`). Deleting the group hands the site and device settings and the telemetry targets that
  name it back to the server, which is held off for the lease before it polls; nothing is left unowned or owned twice.
- Metrics on the node that leads: `seshat_edge_group_members{state}` and `seshat_edge_group_failovers_total{reason}`
  (`member_offline`, `member_removed`, `rebalance`; a batch counts once; `vip_master_down`, `vip_preempt`, `vip_started`
  and `vip_other` count the times a member took over the shared address, on whichever node received the member's
  heartbeat).

**The cost.** A member cannot tell "I am cut off" from "the server is down". If the whole server side is unreachable for longer
than the lease, every member stops polling the devices of its group until it hears from the server again; events keep
buffering. Raise `grace_secs` and `lease_secs` together to ride out longer outages.

**Where it works.** PostgreSQL (the leader runs the placement) and a single SQLite node. A SQLite node that syncs with
peers is refused (`409 groups_unavailable`) and an existing group is not rebalanced there: each such node has its own
database and takes itself for the leader, and the edge registry and the placement are not among what the peer protocol
replicates, so no one place could decide who polls a device. Two server nodes must keep their clocks within a few seconds
(the 30 s margin is meant to cover it). **Upgrade every server node before the first group is used**: a node that does not
know `group:<id>` reads such a setting as unset and would poll the device itself. Upgrade the servers first, then the edges,
as always. An edge of an older release does not say (in the `X-Seshat-Edge-Caps` header it sends) that it honours the group lease: it is
served the devices it owns by its own id only, the server never confirms it, so it is never healthy and is assigned none.

#### Telemetry targets on a group

A dial-in target names a group with `run_on: "group:<id>"` in `PUT /api/inputs/telemetry`, as it names an edge with
`edge:<id>`. The settings are the store's and a target has no row of its own, so the placement keys it by its **name**, in
the table that holds the devices (`edge_group_assign`, key `target:<name>`; device ids start with `dev-`, so the two
cannot meet). A target and a device are then one kind of work for the reconciler: the same guarded moves, holds,
releases, audit records and metrics, and the same rules of the section above. The differences:

- **Each kind is spread evenly by itself**, and the least loaded member gets the next item of a kind, ties broken by the
  member with the fewest items of both kinds. A member that has the most targets is not also given the most devices, and
  the rebalance evens out each kind on its own.
- **The edge's fence is the group's lease** ([Fencing](#fencing-the-lease)). The server serves a member the group
  targets the database assigns to it at its confirmation, read in the same transaction as for devices (the telemetry
  input is given that share and serves no group target outside it), with the group's lease (`group_lease_secs` in the
  telemetry section) and each target's hold. The etag covers when each target was assigned, its hold and the lease, so a
  target that goes from one member to another and back is a different list and the member has to fetch it before it
  renews. The longest lease an edge may hold is recorded for a member that has only targets as it is for one that has
  devices. The edge stores a new list (the encrypted file and edge.json) and applies it, and stops the targets it no longer
  lists, with their sessions closed (it waits up to 5 s for that), before the etag in its heartbeat moves to the new list;
  a list it cannot store, or a session that will not close, is applied as far as it can be but not claimed: the etag in
  its heartbeat is blank (not the previous one, so a server that goes back to that list cannot renew a list that is not
  running) and the next check fetches the list again. When it could not store a part of it, edge.json is written with no
  etag either, so an edge that is restarted before it succeeds fetches the whole configuration at its first check, and
  does not renew its lease on the list the files still hold. A session that will not close does not stop the pollers from being renewed
  by the answer: their list of devices was applied whole. The same holds for the group's VRRP key: a key file that cannot be
  written leaves the section running but unclaimed (blank etag in the heartbeat and in edge.json), and the etag moves to a
  list only after its VRRP section is running. A hold arrives as the time that remains and
  the edge counts it on its own clock from the moment the configuration arrived, and remembers the end by the target's
  name, so a link that opens and closes the fence does not start the hold again; a restart holds for the whole hold of the
  configuration it starts with, counted from the start.
- **Failover and return** are those of the devices: a member's targets move one grace after its last confirmation, with
  no hold; a member that returns gets targets back after the damping time, a step at a time, each through a hold of the
  lease of the member it is taken from. An individually assigned target (`edge:<id>`) on the same member keeps its own
  lease and works alongside.
- **The hold follows the device that is dialled, not the name of the setting.** A target that leaves its owner (it is
  deleted, renamed, given another address, switched off, or moved away) is recorded in the telemetry settings
  (`holds`, in the same compare-and-set write as the change, so every node has it and there is nothing to migrate) with
  its address (host:port, lower case) and the time its owner may go on dialling it: one lease of the group's members (the
  longest any holds, a member that was taken out of the group included while its lease runs), the edge's own
  `telemetry.lease_minutes` for an edge (and not less than the hand-back hold), the hand-back hold or an hour for an owner that
  is gone, the take-over hold for the server. A target that is created or changed afterwards with that name **or** that
  address waits for the record, whoever owns it (the server, an edge, the same group or another): deleting a target
  and creating the name again for the server, renaming a group target to a server one, `group:X` to `group:Y` or
  `edge:Y` to `group:X` in one change, and giving the address to another name all wait for the former owner's
  lease. A server target that the server runs again waits only for the server's own take-over hold, not for a hold it got
  from a group or an edge: a target moved to the server inside the lease of the group's member (or the edge), then
  renamed, or deleted and created again, waits for the rest of that lease, and so does one of a group that was deleted.
  A record is dropped when it has run out, and at most 4000 are kept (the ones that end last). Addresses are compared
  after normalising them: host in lower case without a trailing dot, an IP address in its canonical form, the port
  without leading zeros, a bare host with the gNMI port, and `localhost`, `127.0.0.1` and `::1` as one. A name and an IP
  address that name the same device are **not** matched: that would take a lookup, which a settings change does not
  make. Holds on the same target set by a move are never shortened. An edit of the target during a hold does not change it. The
  placement also holds a target for a lease when it first assigns it to a member, and keeps a released target's row (the
  member and its hold) until the hold has passed, so one that comes back under the same name in that time returns to the
  same member with the hold it had.
- **Holds are counted from the moment they are worked out**, which is before the write commits: a hold cannot be stamped
  inside the store's write. Every hold therefore carries a margin of 5 s, and the write is given no longer than that (the
  context of the change ends then). A write the store reports as failed at the deadline might in principle still commit
  a moment later; the hold of such a write is short by the time it took past the deadline. A hold that another node reads as an
  absolute time is read 3 s later for the difference of the clocks of the nodes (the margin the groups ask for): in the
  records kept in the settings (also when they are dropped), in the hold served to an edge, in the server's own wait, and
  in the rows of the placement (a released row is dropped, and a group counts as settled, only after the margin). Deleting a
  group (`ReleaseGroup`) is a settings write like the others: its holds carry the 5 s margin and it is given no longer than that.
  The margins are not applied to the holds of devices.
- **Moving a target out of a group** holds the next dialler for the longest lease a member may hold, never less than the
  hand-back hold, whether or not the member is online (nobody can be asked); into a group it is held as a hand-over is. The
  change is not refused for an offline member and `?force` has no part in it.
- **Nothing is left with nobody.** A change that takes a target out of a group needs the group's lease: if the server
  node has never been able to read the groups the change is refused (`telemetry: the edge groups could not be read`),
  and one that has had an answer goes on with the last. Deleting a group hands its targets back to the server (`run_on` empty, held for the
  lease), as it does the devices, before the group goes; the last member cannot leave while a target names the group. A
  target whose group is gone anyway (a failed delete) is dialled by the server after an hour, the longest a lease can
  be, and the status says why. With no healthy member nothing moves: the targets stay with their members, and a target
  nobody has yet shows `unassigned_targets` in the group view. If the telemetry settings cannot be read the targets are left
  as they are for that pass and the devices go on. The answer to a member is built from the settings as the store has
  them at that moment, not from the copy a node keeps for a few seconds, so a node does not serve, and renew, a target that
  another node has just taken out of the group.
- **Status.** `GET /api/edge-groups/{id}` has `targets` and `unassigned_targets` for the group and `targets` per member;
  the telemetry status shows `owner: "group:<id>"` and the `member`. An audit record `edge.group.move` for a batch with
  targets has `targets` and `target_sample` besides `devices` and `sample`. An older edge (no `group-lease` capability) is
  served no group target.

#### Relay and SNMP reads through a group

`POST /api/edge-groups/{id}/relay` has the contract of `POST /api/edges/{id}/relay` and `POST /api/edge-groups/{id}/snmp` (and
`/snmp/windows`) that of the edge routes. The members that may take a request are the healthy ones, then the suspect
ones; a member that is gone is not asked (an edge of an older release is never confirmed, so it is gone to the group and is not used).
Among them a member the server confirmed within the last two heartbeat intervals (20 s) is asked before one it did not: a
member whose link to the server was cut without a close keeps a control connection the server cannot tell is dead, so a
request offered to it waits for an answer that does not come, and its confirmations stop at once. Such a request is still
never repeated on another member (it may have been sent); the stale member is only asked last.

- **Relay.** The member with the fewest relay sessions open through this node goes first (the count is of this node's
  sessions; another node does not know them). The server asks the member through the peer mesh, from any node, as it does
  for an edge. The next member is asked in two cases only, both of which leave nothing on the first edge: the request was
  **proved not sent** (the edge has no control connection on any node, the connection took no more requests, or the peer
  that holds it refused the offer), or the member is **at its limit of sessions** (`limit_exceeded`, which is said before a
  session exists; the counts the order was made from were read before the opens of concurrent requests). A request that
  may have been sent is not asked of another member: the control connection took it and then ended, or the call to the
  peer failed after it may have written it. The edge's agent runs an open under its own context, so the first edge may
  still dial the target, and a second member would open a second connection to it. The client is still told `edge_offline`
  then. Nothing is repeated either once a session is open, or when a member answered anything else (`target_not_allowed`,
  `write_not_allowed`, `relay_disabled`, `dial_failed`, `relay_timeout`): the answer stands, and an error of a member's
  own (its policy, its ceiling) names the member in `error.fields.member`. With every member offline the answer is
  `edge_offline`, with every member at its limit `limit_exceeded`. A session that loses its member ends; it is not opened
  again on another. The audit records name the `group`, the member as `edge` and `members_tried`.
- **SNMP reads.** The target decides the member: the members are ordered by a stable weight of the target address, so the same
  device goes to the same member from any node, as long as the set of healthy members is the same, and the edge that gets
  the requests counts the spacing. A member for which the request is proved not sent (the relay's rule above) is passed over. A read that may have been
  sent is not repeated on another member (the first may have asked the device, and a second member would double the
  client's reads), and its spacing slot is not given back. An error of the device (a timeout,
  an SNMP error in an operation) and a refusal of the edge's policy are the answer and are not retried; an error of a
  member's own names it in `error.fields.member`. The credential is a
  **profile only**: a sealed credential is sealed to the key of one edge, and the group route does not know which member
  will take the request, so `credential.sealed` is refused with `400 validation_failed`; a client whose scope names a member can
  use that member's own route for a sealed credential.
- **Windows and rates hold across the members.** The server keeps its own account for the group, per client and device
  (one request per `outside_gap_secs`, or the window's `min_interval_s`), and refuses with `429 limit_exceeded` and
  `Retry-After` before it asks any member. A failover, or a request that lands on another node's member, then does not give a
  client a second budget. **The account is kept in memory on each node and is not shared between nodes, as the edge route's is not:** a read that
  lands on another server node has that node's account, and the budget of a client is then one per node
  until the edge's own account (its `outside_gap_secs`) answers. The stable choice of the member makes the edge that gets
  the reads the same one from every node, and it keeps the spacing, but a failover or a change of the set of healthy
  members that sends the same device to another member in the meantime also gives that member no account of the earlier
  read. On one node, and across a failover on that node, the group's account holds. A slot is spent only by a request that reached a device (an answer or an error of
  the device), not by one refused at the door or that found no member. A window of the group (`POST
  /api/edge-groups/{id}/snmp/windows`, `group` in its answer) is bound to the group: it does not work on a member's route
  and a member's window does not work on the group's. Its floor is the members' `min_window_secs`. The edge's per-device request rate
  (`device_rate`) and the polling budget are the edge's own: a member that polls a device and another that reads it each
  keep their own.
- **Scope.** An integration client names a group in the `edges` list of its scope as `group:<id>`. That entry is the whole
  grant: the group route is the way in, and the members' own routes stay closed to the client unless it also names them.
  A scope that names every member does not name the group.
- **Policy of the group.** The members may have different `relay` and `snmp_read` sections, and a request would behave
  differently depending on the member it reached. The group does not carry these sections and push them to the members
  (an edge keeps its own configuration, with its own ceiling, and the sections are per edge everywhere else); instead
  **the group route refuses, with `409 group_policy_differs`, while the members' sections that the route uses differ in
  what decides a request**: the relay route compares the `relay` sections and the SNMP routes the `snmp_read` sections (a
  difference in the one does not stop the other), and the group's status says which differ. Compared, as stored: the whole
  `relay` section (its allow-list as a set) and, of `snmp_read`, whether it is on, the allow-list (as a set) and the limits. A member whose
  document cannot be read makes both differ. Not compared, because they belong to the host: `source_address` and
  `poll_workers`. Every member counts, whether or not it is up, so which member takes a request never changes what the
  request does. `GET /api/edge-groups/{id}` has `policy` (`relay` and `snmp_read`, each `consistent` or `differs`) and, per
  member, a short digest of each section (`relay_policy`, `snmp_read_policy`; `off` for a section that does nothing), so the
  odd one out stands out. Two limits: an edge applies a changed section at its next sync (within seconds for a member of a
  group), and enforces the old one until then, while the group's status compares what is stored; and the edge's own ceiling
  (`SESHAT_EDGE_RELAY_CEILING`, `SESHAT_EDGE_SNMP_CEILING`) is in its environment, which the server cannot see, so a ceiling
  that differs between members still shows as a refusal from one of them. Set them alike.

### VRRP on the edges of a group

The members of a group can share one receiving address, so that devices send their syslog, traps and flows to a
single address and a member that fails hands it to another within seconds. The server pushes the configuration to the
members; the members run the same VRRPv3 engine as the server's HA ([`ha.md`](ha.md)) between themselves, on their own
network segment. Nothing about it travels to the server except the status in the heartbeat, and the edges stay
outbound-only toward the server.

**What it needs.** The members on one layer-2 segment that forwards multicast `224.0.0.18` (IP protocol 112), a free
address in the segment's subnet, `CAP_NET_ADMIN` and `CAP_NET_RAW` in each member's effective capability set
([Capabilities](#vrrp-capabilities)), and members that send the `vrrp` capability (this release of the edge; an older
edge is served no VRRP section and reports none). A group without a VRRP configuration, and an edge in no group, run
no VRRP and are unchanged.

**Configuring it.** `PUT /api/edge-groups/{id}/vrrp` replaces the group's whole VRRP configuration (admin), `GET` reads it
with the status, `DELETE` removes it and the members release the address. Every change is audited
(`edge.group.vrrp.update`, `.delete`; the key is in no record). The members apply a change at their next heartbeat
(10 s) without restarting their pipeline.

```json
{
  "instances": [
    {
      "name": "syslog",
      "vrid": 51,
      "vips": ["192.0.2.10"],
      "priorities": { "edge-a": 120, "edge-b": 100, "edge-c": 80 },
      "preempt_delay_ms": 30000
    }
  ],
  "health": { "link_down_secs": 30, "link_down_penalty": 40, "queue_age_secs": 300, "queue_age_penalty": 20, "listener_penalty": 60 }
}
```

| Field | Meaning |
|---|---|
| `instances` | 1 to 8 virtual routers. One is active/standby (mode 1). Several, each with a different best member, are multi-address active/active (mode 2): split the devices between the addresses, as in [`ha.md`](ha.md#mode-2-multi-vip-activeactive). |
| `name`, `vrid` | A label, and the VRID 1 to 255: unique in the group, and not used by another group of the same site and VRF (the advertisements of a VRID reach every router on the segment). |
| `vips` | 1 to 8 usable unicast addresses of one family: not unspecified, loopback, link-local, multicast, broadcast (255.255.255.255) or reserved (0.0.0.0/8, 240.0.0.0/4). Not an address another group of the same site and VRF holds. |
| `interface`, `interfaces` | The interface name on the members; empty is the interface whose directly connected subnet holds the first address (right for nearly everyone). `interfaces` overrides it for single members, keyed by edge id. A member refuses (`fault`) an address its interface has no connected subnet for. |
| `priorities`, `default_priority` | Base priority 1 to 254 per edge, keyed by edge id: a member, or any edge of the group's site and VRF (set the priority of an edge before it joins and joining does not break the configuration); a member not listed has `default_priority` (100). |
| `preempt` (default true), `preempt_delay_ms` (default 30000) | A higher-priority member takes the address back, and a backup takes it from a master whose priority has dropped (health-driven failover needs it). The delay is how long a backup tolerates a lower-priority master that is still advertising first. With the link-down penalty on it must be at least 15000: see the next section. |
| `advert_interval_ms` | 100 to 40950 in steps of 10; default 1000. A backup takes over after three intervals plus a skew when it hears nothing (3.2 to 4 s at the default). |
| `health` | The penalties, in priority points; 0 turns a signal off. Below. |

The server refuses what cannot work, naming the field: a VRID or an address another group of the same site and VRF uses, a
priority or interface for an edge that is not of the group's site and VRF, an address that is not a usable
unicast one, mixed families, and penalties that cannot do their job (below), also when a member joins (a join that would
leave the configuration unable to work is a `409 vrrp_unworkable` whose message names the fix). The group's site and VRF are the segment's
identity as far as the server knows: it has no list of the subnets of a site, so whether an address is in the members'
subnet is decided on each member, which refuses an address its interface has no connected subnet for and says so in its
status.

**The key.** The first save makes a random 32-byte key for the group, seals it with the server's secret key and keeps it
until the configuration is deleted or the key is rotated ([Rotating the key](#rotating-the-key); saving again does not change
it). Advertisements are signed with an HMAC keyed from it,
so another host on the segment cannot take the address or knock it over; as in [`ha.md`](ha.md), the signature is not
bound to a counter and VRRP belongs on a segment you control. The key is the group's own: it is not the server's cluster
secret, nothing derives it from that, and it is served only to the members of that group, in the configuration the
edge fetches over its authenticated connection. It is in no API response and no audit record (`auth_key_set` says it
exists). On the edge it is kept in `vrrp-key.enc` ([What an edge keeps on disk](#what-an-edge-keeps-on-disk)).

#### Rotating the key

`POST /api/edge-groups/{id}/vrrp/rotate-key` (admin, audited as `edge.group.vrrp.rotate_key`) makes a new key. The server
also rotates it by itself, audited as the system's, when a member is removed from the group and when an edge that is in the
group is deleted (revoked) or has its credentials rotated: the edge that left may be offline and keep the key it had, and
the key it holds must stop being the group's. An edge that is no longer a member is also served no VRRP section, and
deletes its key and stops its instances when it hears the server.

A new key is introduced in two steps so that the address does not move. The server serves the section with both keys. For
the first 60 s the members fetch the new key (at their next heartbeat, at most 10 s) and sign with the **old** one; every
advertisement carries one signature and a member accepts either key. Then, for another 60 s, they sign with the new
key and still accept the old one. After two minutes only the new key is served. A key change on a running instance does not
restart it, so no address is released. Rotations after the first are refused (`409 rotation_in_progress`) while one is being
taken up, except the automatic one after a member left.

An edge the server refuses on every request, at least three times over 30 s with no answer in between (it was revoked or
deleted, or its credentials rotated), stops its instances, releases the address, deletes its key file and takes the
section out of `edge.json`, and goes on receiving and buffering. One refusal, or a few in a row for a moment (a proxy, a
restart), does not: an edge that lost VRRP over that would drop the address of its group.

The limits, stated plainly:

- A member must reach the server within the two minutes. One that cannot (it is cut off from the server but on the segment)
  keeps the old key, is not heard once the old key is no longer accepted by the others, and, hearing nobody it can trust,
  claims the address itself: two holders until it reaches the server. The same happens to a member that was removed
  while offline and is still running: after a rotation it is no longer part of the election, and if it is still on the
  segment it will hold the address too until it hears the server (which tells it to stop). Take such an edge off the segment,
  or stop it, before it matters.
- Rotating while members are cut off from the server is best avoided; the group status shows `key_rotated_at`.
- The server nodes each cache the section for up to 3 s, so a change made on one node may reach members through
  another a moment later.

**While the server is unreachable.** VRRP does not depend on the link: it uses the last configuration, kept on disk, and a
restarted member does too. A change takes effect only when the server can be reached.

**Health penalties.** Every 2 s the member looks at itself and subtracts a penalty from each of its priorities (never below 1);
the lower value is advertised at once, so a healthy peer with a higher priority takes the address after the preempt
delay. A signal counts after failing 2 probes in a row (the link signal at once, it is a duration already) and clears
after 3 good ones.

| Signal | Counts as failing when | Default penalty |
|---|---|---|
| `server_link` | the server has answered nothing (heartbeat, configuration check, stream acknowledgement) for `link_down_secs` (default 30) | 40 |
| `queue_age` | the oldest event in the upstream disk queue is older than `queue_age_secs` (default 300) **while the server link is up** (a queue that grows because the server is away is the link's doing and is not counted twice) | 20 |
| `listeners` | an input listener (traps, syslog, flows, telemetry dial-out) is not bound, or the pipeline is not running | 60 |

A member that lost the server can still receive and buffer, but it is penalised, and a healthy peer takes the address.
The server enforces what makes that work: `link_down_penalty` must be larger than the gap between the two highest
priorities of each instance (otherwise a master cut off from the server keeps the address) and lower than every member's
priority and than `default_priority` (otherwise the penalty alone takes members to the floor, where they tie). With 120, 100
and 80 the default 40 satisfies both. It checks this on every save (the priorities of the members and of the edges that
have been given one count) and whenever a member joins; removing a member is never refused, so an operator with a dead member
can always take it out, and a configuration that no longer works with the members left shows in the VRRP status as a warning.

The other penalties are not enforced, because they are advice about what the operator wants: `listener_penalty` and
`queue_age_penalty` move the address only if they exceed the gap between the two highest priorities (with 120 and 100 a
listener penalty of 60 does, with 200 and 100 it does not, and a master whose listeners are down keeps the address), and
the penalties together can take a member to priority 1 (when they reach its priority), where members tie. The VRRP status
(`warnings`) says so for the configuration as it stands. The default penalties 40, 20 and 60 add up to 120, so they
raise the second warning for members with priorities under 120: use priorities above that, or lower the penalties.

**If every member lost the server.** All are penalised by the same amount, so the order of their priorities is unchanged and the
current holder keeps the address: receiving and buffering carry on at one member. The members may cross the
threshold a few seconds apart (their last contacts differ by up to one heartbeat), and for that interval one has the penalty and
the others not. This is what the preempt delay is for: a backup that preempts sooner would take the address from a master that
is about to be penalised just as much, and give it back. The delay is honoured exactly (a backup that hears a lower-priority
master keeps its master-down timer running from every advertisement, so the delay, not the master-down interval, decides),
and the server will not accept one under 15 s while the link-down penalty is on. When the link returns, a penalty clears
only after 3 good probes and the member then gets the address back after the delay; the edge reports every transition, with
its reason, in the group view.

**Failover times.** A holder that stops cleanly (SIGTERM, `docker stop`, systemd stop) releases the address first and sends a
priority 0 advertisement, so a backup takes it within the skew time (about 0.6 s at the defaults); a holder that dies or is cut
off from the segment is replaced after three advertisement intervals plus the skew (3.2 to 4 s). A penalised holder is
replaced after the penalty is in force plus the preempt delay. The new holder announces the address with gratuitous ARP
(IPv4) or an unsolicited neighbour advertisement (IPv6), three times. A hard kill on a host network leaves the address on
the interface until the edge starts again; see the drop-in below.

#### The edge-local ceiling for VRRP

The addresses come from the server, so by themselves they protect against nothing if the server is compromised or
misconfigured. An edge's own operator can bound them in the edge's environment, in something the server does not send:

| Variable | Meaning |
|---|---|
| `SESHAT_EDGE_VRRP_CEILING` | Comma-separated CIDRs or addresses (or `none`): the only addresses the edge will hold. |
| `SESHAT_EDGE_VRRP_CEILING_FILE` | The same, one entry per line (`#` comments), read at start. |

A virtual address outside the ceiling is refused on the edge: the instance is not started, the address is never
programmed, the member reports it as `refused` with the reason (status page, `/api/status`, the group view,
`seshat_edge_vrrp_refused`), and the instance's other addresses are not claimed either. `none` forbids VRRP on the edge (`none` together with addresses is a mistake and an
error). With no ceiling the edge follows the pushed configuration and logs a warning when VRRP is configured that way (the status page says
so). A ceiling that cannot be parsed, a ceiling file that cannot be read, and a ceiling file that holds no entry (empty or only
comments, a truncated write) keep VRRP off (the edge starts and does everything else) and say why.

#### VRRP capabilities

VRRP needs `CAP_NET_ADMIN` (the address) and `CAP_NET_RAW` (protocol 112 and gratuitous ARP) in the process's effective set;
the default unit and the default image grant neither, and the default is not widened. Without them the edge starts, receives,
buffers and delivers as usual, logs the missing capabilities once, and reports `unavailable` with the capability names in its
status and in the group view; it retries every 5 s, so granting them needs no new configuration.

- systemd: the drop-in [`deploy/systemd/drop-ins/edge-vrrp.conf`](../deploy/systemd/drop-ins/edge-vrrp.conf) (installed with
  the `seshat-edge` package as `/usr/share/seshat-edge/systemd/drop-ins/edge-vrrp.conf`) adds both capabilities to the ambient
  and bounding sets and `AF_NETLINK` and `AF_PACKET` to the unit's address families (the edge unit allows neither). It carries
  a commented `ExecStopPost=` line that removes the address after a kill.

  ```
  install -D -m 0644 /usr/share/seshat-edge/systemd/drop-ins/edge-vrrp.conf /etc/systemd/system/seshat-edge.service.d/edge-vrrp.conf
  systemctl daemon-reload && systemctl restart seshat-edge
  ```

- Docker: run as root on the host network with the two capabilities added, as in
  [`deploy/compose/edge-vrrp.example.yaml`](../deploy/compose/edge-vrrp.example.yaml) (`network_mode: host`, `user: "0:0"`,
  `cap_add: [NET_ADMIN, NET_RAW, ...]`). Without host networking the address would be programmed onto the container's own
  interface, where nothing outside can reach it.

#### VRRP status and metrics

`GET /api/edge-groups/{id}` and `GET /api/edge-groups/{id}/vrrp` show, per instance, the holder (the member that reports itself
master within the last 25 s; `conflict` when more than one does), and for each member its state (`master`, `backup`, `init`,
`fault`, `refused`, or `unknown` when it has not reported lately or is an edge of a release that does not report VRRP), its
base and effective priority, its interface, the time of its last transition with a reason code (`started`, `master_down`,
`preempt`, `peer`, `health`, `released`, `fault`) and the engine's own words for it, and, for the member as a whole, whether
VRRP runs (`running`, `partial`, `unavailable` with the detail such as missing capabilities), whether it has a ceiling and
the penalties in force. Members send their report in every heartbeat, at once when an instance changes state, and once more when they stop, so
the view follows a move within about a second of the move. A holder that dies without stopping (a kill, a power loss)
still shows as master until its last report is 25 s old, and `conflict` shows for that time beside the new holder.

| Metric | Where | Meaning |
|---|---|---|
| `seshat_edge_group_vip_holder{group,instance,edge}` | server | 1 for the member that reports itself master, 0 for the others |
| `seshat_edge_group_failovers_total{reason}` | server | gains `vip_master_down`, `vip_preempt`, `vip_started`, `vip_other`: the times a member took over an address |
| `seshat_edge_vrrp_state{instance,vrid}` | edge | 0 init, 1 backup, 2 master |
| `seshat_edge_vrrp_priority`, `_base_priority` | edge | the priority advertised now and the configured one |
| `seshat_edge_vrrp_transitions_total`, `_advertisements_total{direction}`, `_dropped_total{reason}` | edge | as the server's `seshat_vrrp_*` |
| `seshat_edge_vrrp_health_penalty{signal}` | edge | the priority points each signal costs now |
| `seshat_edge_vrrp_available`, `seshat_edge_vrrp_refused{instance}` | edge | whether VRRP can run here, and whether this instance is refused |

**Upgrading.** Upgrade the servers first, then the edges. A server that has this feature serves an edge that does not send the
`vrrp` capability no VRRP section, so an older member keeps working and takes no part in the election: give such a
group's address to members that all run this release. An edge of this release on an older server receives no VRRP section and runs none.

**Limits of this release.** VRRP is IPv4 or IPv6 per instance, with no virtual MAC (as in [`ha.md`](ha.md#what-differs-from-rfc-5798-and-why)). Changing the key
(delete and save) is a short split of the group, so do it when a brief second master matters least.

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

Edge HA ([the chapter](#edge-ha)):

- The trade-offs of the chapter stand: a server outage longer than the lease stops polling and dial-in, health is the server's
  confirmation only, two holders of the address are possible when the segment splits or a member misses a key rotation, sealed
  SNMP credentials do not work on a group, the SNMP spacing gate is per server node, SQLite nodes with peers are refused.
- The members of a group do not copy their `relay`, `snmp_read`, listener or telemetry sections from the group: set them alike on
  each member. The group's relay and SNMP routes refuse requests while the first two differ.
- A group belongs to one site and VRF, and a member to one group. A VRRP instance is IPv4 or IPv6 and has no virtual MAC.
- The group view and its changes are on the Edges page and in the API; changes are for administrators. Viewers and operators read.
- Measured: the moves of the shared address (above). Not timed on a live group: the moves of devices and targets, which the
  tests check with shortened timing. Not tested: two server nodes with a leader change in the middle of a placement pass, clock
  skew between server nodes beyond the 3 s margin, VRRP on a physical switch, IPv6 on the edge, and a group relay session whose
  data legs reach a server node other than the one that holds it.
- Changing the key by deleting and saving the VRRP configuration is a short split of the group: rotate it instead.
