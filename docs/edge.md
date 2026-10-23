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
| Inputs | SNMP traps/informs (v1, v2c), syslog (UDP, TCP) and flows (NetFlow v5/v9, IPFIX, sFlow), configured per edge on the server (`snmp`, `syslog`, `flow` blocks of the edge configuration, the same settings as the server's Inputs pages). Their site and VRF are forced to the edge's. SNMPv3 users and TLS syslog are not distributed yet. GeoIP databases are read from the edge's own `SESHAT_GEOIP_*` files. |
| Enrichment | The edge holds a **read-only snapshot of the known devices of its own site**, pulled from the server (ETag, every few minutes, kept on disk so a restart works offline). Unknown senders get the same capped expiring stubs as on the server, kept in memory only. |
| Router | Exactly one built-in destination, `upstream`, receives everything. Server-configured local outputs (`raw_relay`, `syslog`, `file`) each get a route with their own match expression. |
| Queue | The same disk queue as every destination (`$SESHAT_DATA_DIR/queue/upstream`, 1 GiB by default, spill). Nothing is dropped because the server is away. |
| Rate limit | An edge-wide token bucket (events per second), set on the server; what it drops is counted. |
| Packs | The server's pack directories (tar.gz, ETag). A change restarts the edge's pipeline. Until the first sync it uses the packs shipped with the image. |
| State | Only `edge.json`, the queue, the packs and the KB snapshot. No database file is ever written; the components that expect a store get a private in-memory one. |

Changing the configuration, the packs or the listen addresses restarts the edge's pipeline inside the
process (a moment of socket re-binding; queued events stay on disk). KB snapshot updates apply live.

## The stream

`POST /api/edge/v1/stream` carries a batch as **chunked NDJSON, gzip-compressed**. One line is one
event: `{"s": sequence, "e": typed document, "x": extra fields, "r": original datagram (base64),
"a": sender ip:port}`. The datagram and sender travel as sidecar fields, so the server can still
raw-relay what an edge received.

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

## What an edge keeps on disk

`edge.json` (mode 0600, written atomically in a 0700 directory) holds the edge's private key, certificate,
bearer token and the last configuration the server sent, including the secrets of local outputs (a syslog
TLS key, for instance) in plain text: the edge has no stable key of its own to seal them with, and "keeps
no secrets at rest" is not true of it. Protect the data directory like a key store (dedicated user, disk
encryption), and prefer local outputs that need no secret. The queue directory is private as well.

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

Roles: **admin** writes (create, configure, rotate, revoke, rotate CA), **operator** reads, **user** gets `403`.
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

## Footprint

Measured on one 16-core development host, with the edge enrolled against a server on the same box,
syslog over UDP (RFC 5424 messages from `seshat-gen`), the pack set as shipped (34 MIB modules, 9 grammars):

| | RSS |
|---|---|
| idle, after start | about 41 to 43 MB |
| 10,000 events/s for 30 s (300,000 events) | 58 to 62 MB peak, queue empty, 0 dropped, 0 duplicates at the server |

Target from the specification: under 100 MB.

## Limits of this release

SNMPv3 users and TLS syslog listeners are not distributed to edges; the Edges drawer edits the SNMP and syslog listeners but the `flow` block is API/JSON only; local
Device Tracker polling at the edge is not available yet; a changed packs set or
configuration restarts the pipeline instead of reloading it; one batch in flight per edge (the measurement above kept up
with 9,000 events/s; the ceiling was not measured).
