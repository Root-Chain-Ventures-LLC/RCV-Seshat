# Syslog input

Seshat receives syslog over UDP, TCP and TLS, decodes it permissively, runs the vendor grammars
from the installed packs, and clusters everything no grammar understood into the **Syslog
templates** inbox. Nothing is ever refused because it does not parse: the raw line is always kept in
`event.original` and `message`.

## Ports and settings

| Listener | Environment variable | Default | Notes |
|---|---|---|---|
| UDP | `SESHAT_SYSLOG_UDP_LISTEN` | `:1514` | Compose maps host 514 to 1514. `off` disables. |
| TCP | `SESHAT_SYSLOG_TCP_LISTEN` | `:1514` | Newline and octet-counted framing, detected per frame. `off` disables. |
| TLS (RFC 5425) | `SESHAT_SYSLOG_TLS_LISTEN` | empty (off) | Conventionally `:6514`. Needs `SESHAT_SYSLOG_TLS_CERT` and `SESHAT_SYSLOG_TLS_KEY`. |

Other variables: `SESHAT_SYSLOG_TLS_CLIENT_CA`, `SESHAT_SYSLOG_TLS_REQUIRE_CLIENT_CERT`,
`SESHAT_SYSLOG_ASSUME_TZ` (default `UTC`), `SESHAT_PACKS_DIR` (`/packs` in the image, `./packs` in
development).

The roles `all`, `collector` and `edge` start the listeners; `console` does not.

The operator-editable part (allow-list, rate limits, connection limits, idle timeout, time zone,
client-certificate policy and the listen addresses) lives in **Inputs, Syslog input** and in
`GET/PUT /api/inputs/syslog` (admin to change, operator to read). Everything applies immediately
except the three listen addresses, which apply at the next start (`restart_required` is shown
meanwhile). Environment values are the defaults until the settings are saved once.

`/api/ready` reports each enabled listener to an administrator, an operator or the metrics token (anonymous callers get only the verdict); it answers 503 while one is down (for example the TLS
listener without a readable certificate; the bind is retried every 10 s).

## Framing

TCP and TLS connections may mix both framings of RFC 6587:

* **octet counting**: `<length> <message>`, where the message starts with `<` (its PRI);
* **newline**: one message per line (CRLF accepted).

A line that starts with digits and a space but is not followed by `<` is an ordinary line, not a
length. Lines or counted frames longer than **64 KiB** are truncated, counted
(`seshat_syslog_truncated_total`) and the connection stays in sync. Connections have an idle
deadline (default 300 s), a connection that sends nothing at all is closed after the first-byte
timeout (default 30 s), and a started frame must finish within 30 s.

Connection limits (TCP and TLS together, applied at accept; IPv6 sources are grouped by /64):

| Setting | Default | Meaning |
|---|---|---|
| `max_connections` | 1000 | open connections in total; extras are closed and counted (`conn_limit`) |
| `max_connections_per_source` | 50 | open connections from one source; extras are closed and counted (`conn_limit_source`). 0 = no per-source cap |
| `idle_timeout_seconds` | 300 | a connection that has sent nothing for this long is closed |
| `first_byte_timeout_seconds` | 30 | a connection that has not sent a single byte this long after it was accepted (after the TLS handshake for TLS) is closed. 0 = use the idle timeout |

A device that opens many parallel connections (a log relay with a large pool) needs a higher
per-source cap; the refusal counter shows when it is hit.

A panic while parsing one message drops that message (`seshat_input_panics_total{input="syslog_tcp"}`
or `syslog_udp`), logs one rate-limited error line with the sender address (the line carries the panic text, at most 200 bytes, but never the message) and
leaves the connection, the other connections and the listeners running.

## What is decoded

1. RFC 5424: PRI, version, timestamp with offset, hostname, app-name, procid, msgid, structured
   data (`seshat.syslog.sd`, flattened to `<sd-id>.<param>`), message with optional BOM.
2. RFC 3164: PRI, `Mmm dd hh:mm:ss` timestamp (also ISO 8601), hostname, `tag[pid]:`. When there is
   no timestamp the whole text after the PRI is the message (vendors such as FortiOS or Cisco IOS
   put their own timestamp there); a leading `tag:` is still honoured.
3. No PRI: the line is kept as is, treated as `user.notice` (13) and tagged `seshat-no-pri`.
4. CEF and LEEF (1.0 tab-delimited, 2.0 with a delimiter field), inside any of the above. The header
   fields and extension go to `seshat.syslog.extension` (`DeviceVendor`, `DeviceProduct`,
   `DeviceVersion`, `SignatureID`, `Name`, `Severity` for CEF; `Vendor`, `Product`, `Version`,
   `EventID` for LEEF, plus every extension key). Common keys map to ECS (`src`, `dst`, `spt`,
   `dpt`, `smac`, `dmac`, `shost`, `dhost`, `suser`/`usrName`, `act`, `proto`; `msg` becomes
   `message`, the signature id `event.code`). The CEF/LEEF severity is mapped to the syslog scale
   (0-3 informational, 4-6 warning, 7-8 error, 9-10 critical) into `event.severity` and `log.level`;
   the PRI severity stays in `log.syslog.severity.*`.

`event.created` is the receive time. `@timestamp` is the device time when present and plausible
(not more than a day ahead and not older than a year), otherwise the receive time.

### Time zone assumption

RFC 3164 timestamps carry neither zone nor year. The year is inferred from the receive time (a
date more than a day in the future belongs to the previous year). The zone is `UTC` unless
`SESHAT_SYSLOG_ASSUME_TZ` (or the setting of the same name in the UI) names an IANA zone such as
`Europe/Berlin` or a fixed offset such as `+02:00`. RFC 5424 and ISO 8601 timestamps carry their own
offset and ignore this setting.

## Vendor grammars

On start Seshat reads `<packs dir>/<pack>/syslog/*.yaml` (and the pack's `mappings/*.yaml` sets),
compiles every grammar once and, per message, tries them by priority then id: first whose `select`
passes and one of whose messages matches wins. The format is the vendor pack grammar format. A match sets `seshat.syslog.parser` (`<pack>/<grammar>`), `seshat.syslog.template_id`
(`<pack>/<grammar>/<message id>`) and the mapped fields; the vendor severity updates
`seshat.syslog.severity`, `log.syslog.severity`, `log.level` and `event.severity` (the PRI itself
is not rewritten). A grammar that fails to compile is skipped and listed under *Vendor grammars* in
the UI; the rest load.

## Template inbox

A message that no grammar (and neither CEF nor LEEF) parsed is tagged `seshat-unparsed` and clustered
by *template*: UUIDs, MACs, IP addresses (with `/prefix` or `:port`), hex strings and numbers become
`<UUID>`, `<MAC>`, `<IP>`, `<HEX>`, `<NUM>`, prefixed with the application name. The template id is
`t-` plus eight hex digits of its SHA-256, stable across restarts, and is stored in
`seshat.syslog.template_id`.

The table keeps at most **10 000** templates (least recently seen evicted) with count, first and
last seen and one example, and is written to the store every 60 s (table `syslog_templates`), so
counts survive restarts. It is bounded in every dimension, because senders choose the messages:

| Setting | Default | Meaning |
|---|---|---|
| `max_templates` | 10 000 | entries in memory (100 to 200 000) |
| `max_template_text` | 1024 | bytes of masked text kept per template (64 to 8192); the template id is still derived from the whole masked message, only the stored text is clipped. The example is clipped to 512 bytes |
| `new_templates_per_minute` | 2000 | creation rate; new shapes beyond it are counted into one `overflow` template instead of evicting useful ones |

The stored rows are bounded the same way (text clipped on write, at most 50 000 rows, least recently
seen unmuted rows trimmed first, muted rows never trimmed). Rows written by earlier versions that
held a whole message are clipped by a migration. Counters:
`seshat_syslog_template_table_total{event}` (`evicted`, `overflow`, `truncated`) and
`seshat_store_rows_capped_total{table}`. **Inbox, Syslog templates** lists them (`GET
/api/inbox/syslog-templates?matched=false`); **Mark as noise** sets a `muted` flag that hides the
template from the default view. Muting never drops events.

## Limits and metrics

Per-source and global token buckets (messages per second plus burst). Over the limit a message is
dropped, except that every Nth over-limit message passes (`drop_sample_every`, default 100) so a
storm stays visible. Both are off (0) by default; Seshat accepts everything unless told otherwise.
The allow-list takes CIDRs or addresses; empty allows all.

* `seshat_syslog_messages_received_total{transport}`
* `seshat_syslog_messages_dropped_total{reason}` (`allow_list`, `rate_source`, `rate_global`,
  `queue_full`, `conn_limit`, `conn_limit_source`, `tls_handshake`, `empty`)
* `seshat_syslog_parse_total{format}` (`rfc5424`, `rfc3164`, `cef`, `leef`, `other`)
* `seshat_syslog_truncated_total`, `seshat_syslog_grammar_total{result}`, `seshat_syslog_connections`

`GET /api/events/tail?dataset=seshat.syslog&limit=500` returns the last events held in memory (at
most 500 per dataset; a syslog flood never pushes traps out of their own ring).

## Where events go

Every event is built like any other Seshat event (the `seshat.syslog.*`
and `log.syslog.*` blocks; fields a grammar derives, such as `source.*`, `user.*` or `cisco.*`, are
merged in as given). It passes the device stamper (`seshat.device.*`, `seshat.enrichment.*`), then
the router, exactly like a trap. The sender's HOSTNAME is also handed to the device knowledge base
as a learning signal, so a new sender shows up under Devices, Unknown with that name. The input
has its own **Site** and **VRF** settings (Inputs, Syslog), which scope the knowledge-base lookup
the same way the SNMP listener's do.

## TLS setup

A throwaway CA, a server certificate and a client certificate for testing:

```sh
# CA
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 365 \
  -subj "/CN=Example Syslog CA" -keyout ca.key -out ca.pem
# server certificate (replace the names with what devices connect to)
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
  -subj "/CN=syslog.example.com" -keyout server.key -out server.csr
printf "subjectAltName=DNS:syslog.example.com,IP:192.0.2.10\n" > san.cnf
openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 365 -extfile san.cnf -out server.pem
# optional: a client certificate for a device
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
  -subj "/CN=device1.example.com" -keyout client.key -out client.csr
openssl x509 -req -in client.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 365 -out client.pem
```

Mount `server.pem`, `server.key` (and `ca.pem` for client certificates) into the container and set:

```sh
SESHAT_SYSLOG_TLS_LISTEN=:6514
SESHAT_SYSLOG_TLS_CERT=/data/tls/server.pem
SESHAT_SYSLOG_TLS_KEY=/data/tls/server.key
SESHAT_SYSLOG_TLS_CLIENT_CA=/data/tls/ca.pem     # optional
SESHAT_SYSLOG_TLS_REQUIRE_CLIENT_CERT=1          # optional; also switchable in the UI
```

Publish `6514/tcp` in compose. TLS 1.2 or newer. The certificate and key are re-read when the files
change; replacing them needs no restart. Check from a shell:

```sh
openssl s_client -connect syslog.example.com:6514 -CAfile ca.pem -cert client.pem -key client.key
```

## Trying it

```sh
logger -n seshat.example.com -P 514 -d -t demo "hello over udp"           # UDP
logger -n seshat.example.com -P 514 -T -t demo "hello over tcp"           # TCP
logger -n seshat.example.com -P 514 --rfc5424 --sd-id 'ex@32473' --sd-param 'k="v"' "with sd"
seshat-gen syslog --target seshat.example.com:514 --format cef --rate 500 --count 5000
```

`seshat-gen syslog` flags: `--target host:port`, `--proto udp|tcp`, `--format 3164|5424|cef`,
`--rate` (messages per second, 0 = unpaced), `--count`. A throughput check (`make load`) sends 50 000
UDP messages over loopback and requires at least 95 % within 10 s.
