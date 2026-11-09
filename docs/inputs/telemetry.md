# Streaming telemetry input

Seshat collects model-driven streaming telemetry and turns every leaf value into one
`seshat.metric` event. Four ways in, one event shape out:

| Source (`seshat.metric.source`) | Direction | Protocol | Configured in |
|---|---|---|---|
| `gnmi` | dial-in: Seshat connects to the device | gNMI `Subscribe` (JSON_IETF, PROTO or JSON encoding) | Inputs, Telemetry: a target with protocol *gNMI* |
| `jti` | dial-in | Juniper `OpenConfigTelemetry.telemetrySubscribe` (`OpenConfigData` key/value) | a target with protocol *JTI* |
| `mdt` | dial-out: the device connects to Seshat | Cisco `mdt_dialout.gRPCMdtDialout/MdtDialout`, self-describing GPB key/value or JSON | the device; Seshat only needs the listener |
| `os10` | dial-out | Dell OS10 `/ta_stats.DellNetTelemetryService/SendTelemetryStats` and `/telemetry.OpenconfigTelemetry/SendTelemetryStats`, client streams of the switch's own protobuf messages, decoded by Seshat's own wire decoder | the device |
| `jti` / `gnmi` | dial-out | `/Subscriber/DialOutSubscriber` (Juniper, reported as `jti`) and `/gnmi_dialout.gNMIDialOut/Publish` (reported as `gnmi`), both streams of gNMI `SubscribeResponse` | the device |

Seshat is read-only toward devices: a dial-in subscription only reads. The roles `all` and
`collector` run the input; the console role does not. An **edge collector** runs it too, for devices on
a network the server cannot reach: it can listen for dial-out telemetry and dial the dial-in targets
that an administrator assigns to it, and forwards the samples to the server as ordinary `seshat.metric`
events over its disk-buffered stream ([Streaming telemetry on an edge](#streaming-telemetry-on-an-edge)).

## Ports and settings

| Setting | Where | Default | Notes |
|---|---|---|---|
| Dial-out listener | `SESHAT_TELEMETRY_GNMI_DIALOUT_LISTEN` | `:57400` | One gRPC port for all three dial-out services. `off` disables. Applies at the next start. |
| Dial-out TLS | `SESHAT_TELEMETRY_TLS_CERT`, `SESHAT_TELEMETRY_TLS_KEY` | off | Without them the listener is plaintext gRPC, which is what many devices default to. |
| Capture of unknown services | `SESHAT_TELEMETRY_DIALOUT_CAPTURE_DIR` (edge: `telemetry.dialout_capture_dir`) | off | A diagnostic that writes the first raw messages of gRPC methods Seshat does not serve to files. It stores device data on disk: see [Unknown services](#unknown-services-and-the-capture-diagnostic). |
| Device certificates | `SESHAT_TELEMETRY_TLS_CLIENT_CA` | off | PEM bundle; with it, a device must present a certificate that chains to it. |
| Largest message | `SESHAT_TELEMETRY_MAX_RECV_MIB` | `4` | One gRPC message, and the size an MDT chunked message may announce. Larger is refused (`ResourceExhausted`). |
| Streams per connection | `SESHAT_TELEMETRY_MAX_STREAMS` | `100` | Concurrent gRPC streams on one connection; more wait. |
| Streams per source | `SESHAT_TELEMETRY_MAX_STREAMS_PER_SOURCE` | `256` | Open dial-out streams from one source address (IPv6 by /64), so one source cannot take the 5000-stream session budget; extras are refused (`ResourceExhausted`) and counted (`stream_limit_source`). |
| Connections, total | `SESHAT_TELEMETRY_MAX_CONNECTIONS` | `2000` | TCP connections to the dial-out port; extras are closed at accept and counted (`conn_limit`). |
| Connections per source | `SESHAT_TELEMETRY_MAX_CONNECTIONS_PER_SOURCE` | `32` | Per source address (IPv6 by /64); extras are closed and counted (`conn_limit_source`). |
| Idle connections | `SESHAT_TELEMETRY_IDLE_TIMEOUT_SECONDS` | `300` | A connection with no open stream is closed after this. |
| Partial-message budget | `SESHAT_TELEMETRY_REASSEMBLY_BUDGET_MIB` | `64` | Bytes all MDT streams together may hold in chunked messages that are not complete yet. A chunked message must complete within 30 s of its **first** chunk (an absolute deadline, later chunks do not extend it); otherwise it is dropped, its budget released at once and its stream closed. |

The limits apply when the listener starts. Seshat also pings quiet peers (every 2 minutes, 20 s to
answer), allows 20 s for the HTTP/2 and TLS handshake, and caps request headers at 64 KiB.

**The dial-out listener is plaintext and unauthenticated unless you configure TLS.** Without
`SESHAT_TELEMETRY_TLS_CERT`/`_KEY` it serves plaintext gRPC, which is what many devices default to;
when it is bound to anything but a loopback address Seshat logs a warning at start. Anyone who can
reach the port can then feed it metrics. Use TLS (and a client CA to require device certificates), the
allow-list, and a firewall; bind it to `127.0.0.1` when only a local relay talks to it.
| Targets, subscriptions, allow-list, site, VRF | Inputs, Telemetry; `GET/PUT /api/inputs/telemetry` | none | Admin changes, operator and viewer read. All of it applies immediately. |

Publishing the port: `compose.yaml` maps `57400:57400` (tcp), the Helm chart exposes it as
`intake.ports.telemetryDialout` (`{enabled: true, port: 57400}`, a TCP port on the intake Service
and the StatefulSet), and `deploy/k8s/examples/networkpolicy.yaml` allows it. An edge that
runs a dial-out listener publishes its own port (`compose.edge.yaml` has the line, commented out).

The settings live in the store (key `inputs.telemetry`); no migration is involved. Target
passwords and client keys are sealed with `SESHAT_SECRET_KEY` (the facility SNMPv3 passphrases use),
never returned by the API (`password_set` / `tls_key_set` say that one exists) and never written to
the audit log. On update an empty password keeps the stored one; `clear_password` removes it.

## Dial-in targets

A target is `name`, `address` (`host:port`, a bare host gets 9339), `protocol` (`gnmi` or `jti`),
`encoding` (gNMI: `json_ietf` default, `proto`, `json`), `username` and password, TLS (off, or on
with server name, CA, client certificate and key) and a list of subscriptions:

| Subscription field | Meaning |
|---|---|
| `path` | gNMI path with optional list keys: `/interfaces/interface[name=Ethernet1/1]/state/counters`. Slashes inside `[...]` belong to the key value. Leave the key out to get every entry. For JTI, the sensor path (`/interfaces/`). |
| `mode` | `sample` (default) or `on_change` (gNMI only; a JTI sensor samples at its own frequency) |
| `sample_interval` | `sample` mode: `1s` to `1h`; empty lets the device choose. JTI: sent as `sample_frequency` in milliseconds. |

One `Subscribe` stream carries all subscriptions of a gNMI target. Credentials travel as the
`username` / `password` gRPC metadata, which is what the gNMI authentication convention uses.
**A target that has credentials but TLS off is not dialled**: the status shows `refusing to send
credentials without TLS` and a warning is logged. Turn TLS on for the target, or, for a lab or a
trusted link, set `insecure: true` on the target ("Allow sending the username and password without
TLS" in the UI); Seshat then connects and logs a warning that the credentials travel in clear text.

**Run on.** A target is dialled by exactly one collector: `run_on` is `server` (the default),
`edge:<id>` or `group:<id>`. The edge gets the target, its credentials and TLS material sealed in its configuration
(see below); the server stops dialling at once and shows the target with its owner. Moving a target is a
hand-over without overlap, see [Streaming telemetry on an edge](#streaming-telemetry-on-an-edge). With `group:<id>` the
server assigns the target to one healthy member of that [edge group](../edge.md#edge-groups) and moves it to another when
the member stays away; the status shows the group as the owner and the member. A target is named in its group by its name,
so a rename is a delete and a create, and a target new to a group waits a lease before it is dialled.

A session that ends (network, device reboot, reset) is retried with exponential backoff, 1 s
doubling to 60 s with jitter, reset once a session has delivered data. The Telemetry page shows per
target the session state (`connecting`, `established`, `backoff`, `disabled`), the connected
address, the last error, the age of the last message, the message count and the smoothed messages
per second.

## Dial-out

Devices connect to the listener and push. The allow-list (CIDRs or addresses, empty accepts every
sender) is applied when the stream opens; a refused stream is counted as
`seshat_telemetry_dropped_total{reason="allow_list"}`. At most 5000 dial-out streams are open at
once (`too_many_sessions`).

A panic in a decoder or the pipeline is contained: the message (or, if the handler itself failed, that
one stream) is dropped, `seshat_input_panics_total{input="telemetry_dialout"}` (dial-in:
`telemetry_dialin`) is incremented, one rate-limited error line names the peer (the line carries the panic text, at most 200 bytes, but never the message),
and the listener and every other stream keep running.

| Service | Message formats decoded | Not decoded |
|---|---|---|
| Cisco `MdtDialout` | `Telemetry` with `data_gpbkv` (key/value GPB, keys/content rows, nested lists) and the JSON encoding (`data_json` rows); chunked messages (`totalSize`) are reassembled | compact GPB (`data_gpb`): it needs a `.proto` per sensor path from the device. Such rows are counted (`unsupported_value`) and the stream goes on. Use key/value GPB or JSON on the device. |
| Juniper `Subscriber/DialOutSubscriber`, `gnmi_dialout.gNMIDialOut/Publish` | gNMI `SubscribeResponse` updates: every TypedValue, JSON and JSON_IETF (flattened), deletes | the Juniper header extension is ignored |

| Dell OS10 `ta_stats.DellNetTelemetryService` and `telemetry.OpenconfigTelemetry` `SendTelemetryStats` | the sensor groups `interface`, `lag`, `system`, `device`, `environment`, `buffer`, `bgp` and `bgp-peer`, with their wrapped values, keyed lists and Decimal64 numbers; the other groups of the newer service (vxlan, lacp, lldp, bfd, stp, ufd, vlan, vrrp, relay agent) too | `config` subtrees, the non-BGP parts of network instances, the per-prefix BGP route lists and the BGP `rib` (cardinality), and user, password and key leaves |

A message that does not decode at all is counted as `decode_error`; a value that cannot be
represented (an `Any`, proto bytes, malformed JSON) as `unsupported_value`. Neither stops the
stream and neither loses the other values of the same message.

The device's own name (MDT `node_id_str`, gNMI `prefix.target`) becomes `host.name` unless it is an
IP address, and is offered to the device knowledge base as a hostname hint.

### Unknown services and the capture diagnostic

A device that calls a gRPC method Seshat does not serve (a vendor whose dial-out service and `.proto`
files Seshat does not have) used to look "connected" on the device while Seshat showed nothing. Now,
on the server and on an edge alike, after the allow-list and the connection and stream limits:

* the stream is counted, one per stream, as `seshat_telemetry_dropped_total{reason="unknown_service"}`;
* a warning names the source address and the full method (for example `/example.vendor.DialOut/Publish`),
  once per source and method (the last 1024 pairs are remembered, so a pair that comes back after a very
  long time is logged again);
* the Telemetry page lists the last unknown methods with their sources and counts (`unknown_services` in
  `GET /api/inputs/telemetry`; the ones an edge saw are in its entry under `edges`);
* the stream is answered with gRPC `Unimplemented`, after Seshat has read and discarded up to 8
  messages or waited up to 30 seconds, whichever comes first. Many dial-out clients show the collector
  as connected only while it takes their data, and never open a session if it hangs up at once. The
  reading is bounded (at most 256 such streams are read at a time; beyond that the stream is answered
  at once) and never touches the event pipeline.

**Capture (opt-in, off by default).** To analyse an undocumented vendor format from your own system, set
`SESHAT_TELEMETRY_DIALOUT_CAPTURE_DIR` on the server, or `telemetry.dialout_capture_dir` in an edge's
telemetry section. Seshat then writes the first 5 messages of every (source, method) pair, as the raw
protobuf bytes of the gRPC message, to

```
<dir>/<method>/<source>-<n>.bin          e.g. captures/example.vendor.DialOut_Publish/192.0.2.30-1.bin
```

(names are made of letters, digits, `.`, `-` and `_`; anything else, including the `/` of the method,
becomes `_`). Files are mode `0600` in directories of mode `0700`, never overwritten, at most 1 MiB each
(a longer message is cut) and at most 200 files in all; the writes are done off the stream and a message
that finds the writer busy is dropped. On an edge the value is a relative directory name under the edge's
data directory (an absolute path or `..` is refused). Read a file with

```
protoc --decode_raw < captures/example.vendor.DialOut_Publish/192.0.2.30-1.bin
```

This is a diagnostic. **The files hold device data** (interface names, addresses, counters, possibly
hostnames), so keep the directory private, delete the files when you are done, and **turn the setting
off after use** (a restart applies it; an edge applies a change by restarting its pipeline, which
the edge does itself). Seshat logs a warning at start while it is on.

## Streaming telemetry on an edge

An edge on a network the server cannot route to (a dual-homed host between a management network and the
server network, say) runs the same decoders and the same sessions as the server, and sends the result
upstream. Full operator guide: [`../edge.md`](../edge.md#streaming-telemetry).

* **Dial-out on the edge.** The edge's configuration has a `telemetry` section (Edges page, drawer,
  *Streaming telemetry*): `dialout_listen`, an allow-list, the limits of the table above, and optional
  TLS (`tls_cert`, `tls_key`, `client_ca`). Point the devices at the edge's address. The Cisco MDT,
  Juniper `DialOutSubscriber`, gNMI dial-out and Dell OS10 services are served on that one port. Streams that call
  any other method are counted and logged as described under
  [Unknown services](#unknown-services-and-the-capture-diagnostic); `dialout_capture_dir` turns on the
  capture diagnostic on the edge.
* **Dial-in from the edge.** In Inputs, Telemetry, give the target *Run on* an edge (`run_on`:
  `edge:<id>`), or an edge group (`group:<id>`, one of the group's healthy members dials it; the target form shows which). The edge dials
  it from its own network. Passwords and client keys are sent to that edge
  only, are never written to `edge.json` and are kept encrypted on the edge.
* **The events.** Samples are `seshat.metric` events stamped with the edge's site, VRF and id
  (`seshat.source.edge`), queued on the edge's disk while the link is down, and handled on the server
  exactly like locally collected ones: routes, the device knowledge base, and the Prometheus
  remote-write, InfluxDB and OTLP destinations. 64-bit integers keep every digit across the stream. Telemetry
  has a rate limit and a queue share of its own on the edge, so a flood of samples is shed first and never
  starves traps and syslog; an edge dials its targets only on a configuration the server confirmed lately
  (the lease).
* **State.** The Telemetry page shows each target with its owner and what the edge last reported (state,
  last message, messages, last error). The edge's status page and `/metrics` carry the same counters
  (`seshat_telemetry_*`).

## The metric event

One notification gives one event per leaf (`event.kind` `metric`, `event.dataset` `seshat.metric`,
data stream `logs-seshat.metric-<ns>`). The fields are in `docs/schema/fields.md` and a synthetic
document in `docs/schema/examples/metric.json`.

* `@timestamp` is the notification time from the device (gNMI nanoseconds, MDT and JTI
  milliseconds; OS10's unit is told apart by magnitude: seconds, milliseconds, microseconds or
  nanoseconds, the timestamp of the sensor message first and the stream header second); a missing or implausible one (more than 7 days from now) is replaced by the
  receive time. `event.created` is the receive time.
* `host.ip` is the address of the connection, `host.name` the target name (dial-in) or the device's
  own name (dial-out). The KB stamps `seshat.device.*` like for any other event.
* `seshat.metric.path` is the full path with list keys in gNMI syntax,
  `seshat.metric.name` the last element, `seshat.metric.source` the adapter.
  Module prefixes (`openconfig-interfaces:`, `Cisco-IOS-XE-interfaces-oper:`) are dropped from path
  elements so the same leaf looks the same whichever way it arrived.
* `seshat.metric.labels` flattens the list keys: a single-key element contributes its element name
  (`interface[name=Ethernet1/1]` gives `interface: Ethernet1/1`,
  `neighbor[neighbor-address=192.0.2.1]` gives `neighbor`), a multi-key element contributes
  `<element>` for its `name` key and `<element>_<key>` for the others
  (`protocol[identifier=BGP][name=bgp]` gives `protocol_identifier` and `protocol`). Names are made
  Prometheus-safe.
* `seshat.metric.value` is a JSON number for `int64`, `uint64` and `double`, a string for `string`
  and a boolean for `bool`, with `seshat.metric.value_type` naming which. `value_string` repeats
  string and boolean values as keywords. A path deleted on the device gives `value_type: delete`
  and `event.action: delete`. Leaf lists become one string holding the JSON array.
  **JSON_IETF numbers:** RFC 7951 encodes 64-bit integers and decimal64 as strings. In JSON and
  JSON_IETF values, a string that is a canonical decimal number (`"1843200"`, `"-5"`, `"1.5"`, no
  leading zeros) is turned into a number; any other string stays a string. Use the PROTO encoding
  when you need exact device types.
* **Interface-centric paths.** A list element called `interface` with key `name` (OpenConfig
  `/interfaces/interface[name=...]/state/counters/*`, Cisco `interfaces/interface[name=...]/statistics/*`)
  also sets `seshat.device.interface.name`; when the KB knows the device and the interface name, the
  stamper adds `seshat.device.interface.index` and `.alias`.
* A JSON value is expanded into one event per leaf, at most 20,000 per update. A list of objects
  becomes list elements keyed by the entry's `name`, `id`, `index`, `address`, `neighbor-address`
  or `identifier` member, else by position.

Because `seshat.metric` events are ordinary events, a route can send them to any destination
(Elasticsearch, a file, Kafka, ...) as JSON documents. The three metric destination types read
them numerically: see "Metric destinations" in [`../outputs.md`](../outputs.md).

## Device-side examples

> These snippets are **illustrative**: they were written from vendor documentation and not run
> against hardware for this release. Check your platform release; commands and defaults change.
> Addresses are documentation addresses (`192.0.2.0/24`): replace them.

**Cisco IOS-XE, gNMI dial-in** (Seshat connects to the router):

```
aaa new-model
gnmi-yang
gnmi-yang server
gnmi-yang secure-server
gnmi-yang secure-trustpoint EXAMPLE-TP
gnmi-yang secure-port 9339
username monitor privilege 15 secret <password>
```

Then in Seshat: protocol gNMI, address `192.0.2.11:9339`, TLS on, username `monitor`, subscription
`/interfaces/interface/state/counters` (sample, `10s`).

**Cisco IOS-XE, MDT dial-out** (the router connects to Seshat; no Seshat target is needed):

```
telemetry ietf subscription 101
 encoding encode-kvgpb
 filter xpath /interfaces-ios-xe-oper:interfaces/interface/statistics
 source-address 192.0.2.11
 stream yang-push
 update-policy periodic 1000
 receiver ip address 192.0.2.50 57400 protocol grpc-tcp
```

`periodic 1000` is in centiseconds (10 s). `encode-kvgpb` is the self-describing key/value encoding
Seshat decodes.

**Cisco NX-OS, gNMI dial-in and MDT dial-out:**

```
feature grpc
grpc port 9339
grpc certificate EXAMPLE-CERT

feature telemetry
telemetry
  destination-group 1
    ip address 192.0.2.50 port 57400 protocol gRPC encoding GPB
  sensor-group 1
    path sys/intf depth unbounded
  subscription 1
    dst-grp 1
    snsr-grp 1 sample-interval 10000
```

NX-OS GPB dial-out can arrive as key/value or as compact GPB depending on the release and the
sensor path. Compact rows are counted in `seshat_telemetry_dropped_total{reason="unsupported_value"}`
and produce no events; if you see that counter climb, switch the sensor to a key/value-capable
path or use gNMI dial-in for it.

**Juniper Junos, gNMI and JTI dial-in:**

```
set system services extension-service request-response grpc clear-text port 32767
set system login user monitor class read-only authentication encrypted-password "<hash>"
```

In Seshat, for gNMI use protocol gNMI with the paths you want (`/interfaces/interface/state/counters`).
For JTI use protocol JTI with a sensor path such as `/interfaces/` and a sample interval; no sensor
configuration is needed on the device for a dial-in subscription. Junos also supports gRPC
dial-out toward the `/Subscriber/DialOutSubscriber` service (see Juniper's JTI documentation for
the export profile of your release); point it at `192.0.2.50:57400`.

**Arista EOS, gNMI dial-in:**

```
management api gnmi
   transport grpc default
   provider eos-native
```

EOS listens on its gNMI port (6030 by default; the Seshat target address must name it) and uses
the local user database for the `username` / `password` metadata. Add `ssl profile <name>` under
the transport for TLS.

**Dell SmartFabric OS10, gRPC dial-out:**

```
telemetry
 enable
 destination-group seshat
  destination 192.0.2.50 57400
 subscription-profile seshat
  sensor-group interface 30000
  destination-group seshat
  encoding gpb
  transport grpc no-tls
  source-interface mgmt1/1/1
```

* One destination group, with **one destination per switch**: the switch dials the address and port it is
  given. Point it at the server or at an edge.
* TLS is **on by default** on OS10. `transport grpc no-tls` selects plaintext, which is what a Seshat
  dial-out listener without `SESHAT_TELEMETRY_TLS_CERT` / `_KEY` serves. For TLS, give the listener a
  certificate the switch trusts.
* On the OS10 10.5.4 releases (seen on build 7) a **source interface is mandatory** for gRPC. Without it the profile stays
  `Active: false, Reason: Missing mandatory configurations: source_interface`, although the 10.5.5
  user guide calls it optional. The form is `source-interface mgmt1/1/1`; the manual's
  `management 1/1/1` is rejected.
* `show telemetry` on the switch reports the connection, not what was decoded: check
  `seshat_telemetry_messages_total{source="os10"}` and the Telemetry page on the Seshat side.

**What is decoded.** OS10 sends its own protobuf messages to one of two gRPC services, both served on
the dial-out port: `/ta_stats.DellNetTelemetryService/SendTelemetryStats` and
`/telemetry.OpenconfigTelemetry/SendTelemetryStats` (whichever the switch's build uses). Seshat decodes
them with its own wire decoder and a compact table of the field names, not with Dell's service
definition, and acknowledges each stream with one response message when the switch ends it. The events
are `seshat.metric` with source `os10`, matched to the device by the address the switch connects from;
the switch's service tag is not used as a label.

* **Sensor groups** (the `sensor-group` names of the switch): `interface`, `lag`, `system`, `device`,
  `environment`, `buffer`, `bgp` and `bgp-peer`. The newer service also carries vxlan, lacp, lldp, bfd,
  stp, ufd, vlan, vrrp and relay-agent groups, which are decoded too.
* **Paths** follow the model of the group, with underscores written as hyphens and list keys in
  brackets, for example `/interfaces-state/interface[name=ethernet1/1/1]/statistics/in-octets` or
  `/interfaces/interface[name=ethernet1/1/1]/state/counters/in-octets`; the metric name is the last
  element and the keys become labels. When the message carries its own sensor path it is the
  `subscription` of the samples, otherwise the group name is.
* **Values.** Wrapped values become numbers, strings and booleans (a Decimal64 becomes a number, a
  leaf-list one comma-separated string). **Enumerated leaves are numeric**, except `oper-status` and
  `admin-status`, which are their names (`up`, `down`, `testing`, ...) where the table has them.
* **Left out**, to keep the data useful and bounded: `config` subtrees, the non-BGP parts of network
  instances, per-prefix BGP route lists, and user, password and key leaves. A message is bounded in
  depth and in leaves; one that does not parse is counted as `decode_error` and the stream goes on.

This decoder has been validated against synthetic streams only; check it against your own switch. If
a group shows nothing, the [capture diagnostic](#unknown-services-and-the-capture-diagnostic) records
raw messages of the methods Seshat does not serve, so you can compare what the switch sends.

## Monitoring

| Metric | Meaning |
|---|---|
| `seshat_telemetry_messages_total{source}` | messages received (`gnmi`, `mdt`, `jti`, `os10`) |
| `seshat_telemetry_updates_total{source}` | metric events produced |
| `seshat_telemetry_dropped_total{reason}` | `allow_list`, `decode_error`, `unsupported_value`, `too_many_sessions`, `stream_limit_source`, `conn_limit`, `conn_limit_source`, `unknown_service` (a stream called a gRPC method Seshat does not serve) |
| `seshat_telemetry_sessions{state}` | sessions by state (`connecting`, `established`, `backoff`, `disabled`); dial-out streams count as `established` |

`/api/ready` reports the dial-out listener as `telemetry-dialout` (to an administrator, an operator, a viewer or the metrics token; anonymous callers get only the verdict).


## What was tested, and what was not

Tested with synthetic data only (in-process targets and senders built from
the published protos): gNMI client against a target in sample and on_change modes, JSON_IETF and
PROTO encodings, credentials, reconnect with backoff; MDT dial-out with key/value GPB (nested
lists, deletes, every scalar type), JSON and chunked messages; the Juniper and gNMI dial-out
services; JTI dial-in with `__prefix__` / `__timestamp__` key/values and Junos-style quoted keys;
bad input (garbage, compact GPB, wrong types, truncated messages); 100,000 updates per second
through one session over loopback.

Not tested: any real device. In particular the exact field layout of Cisco's NX-OS and IOS-XR
sensors, Juniper's per-sensor extension messages (`telemetry_top` with vendor extensions), and the
Junos dial-out export profile are unverified; the decoders follow the published `.proto` files.
