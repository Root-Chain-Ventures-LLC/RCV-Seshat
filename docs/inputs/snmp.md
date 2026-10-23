# SNMP trap and inform input

Seshat receives SNMP v1, v2c and v3 **traps** and **informs** on a UDP listener, turns each into a
`seshat.trap` event (see `docs/schema/fields.md`, block `seshat.trap.*`) and hands it to the
pipeline. It is read-only toward devices: it never sends an SNMP SET or GET, and answers only
informs (with the acknowledgement the protocol requires) and v3 engine discovery.

## Ports

| Setting | Default | Notes |
|---|---|---|
| `SESHAT_SNMP_TRAP_LISTEN` | `:1162` | UDP address of the listener. The container listens on 1162 so it needs no privileges; `compose.yaml` publishes it as host port **162**. Bare-metal installs may bind 162 directly (grant `CAP_NET_BIND_SERVICE`). |
| `SESHAT_SNMP_ENGINE_ID` | generated | This listener's SNMPv3 engine ID (hex, 5 to 32 octets). Empty: generated on first start and stored in the settings table, so every node sharing the database uses the same one. When set, the environment wins and the UI shows the field as read-only. |
| `SESHAT_DEBUG_NDJSON_PATH` | empty | Optional. Appends every event as one JSON line to this file (a debugging aid; the real outputs are described in `docs/outputs.md`). |

The listener runs when `--role` is `all`, `collector` or `edge`. `GET /api/ready` includes an
`snmp_trap` check on those roles (visible to an administrator, an operator or the metrics token; anonymous callers get only the verdict).

## What is decoded

* **v1** traps are normalised to v2 notifications as RFC 3584 section 3.1 describes:
  `snmpTrapOID.0` is synthesised (`1.3.6.1.6.3.1.1.5.<generic+1>` for generic traps 0 to 5,
  `<enterprise>.0.<specific>` for enterprise-specific ones), `sysUpTime.0` comes from the time-stamp,
  `snmpTrapAddress.0` from `agent-addr` and `snmpTrapEnterprise.0` from `enterprise` are appended to
  the variable bindings. `seshat.trap.generic_type`, `specific_type` and `agent_address` keep the
  original v1 header values.
* **v2c** notifications: `sysUpTime.0` and `snmpTrapOID.0` are lifted into `seshat.trap.uptime_ticks`
  and `seshat.trap.oid`; the remaining varbinds appear in wire order in `seshat.trap.varbinds`.
  The community string is checked by nothing and **never stored or emitted**: use the allow-list.
* **v3** with authentication (MD5 and SHA-1/224/256/384/512) and optional privacy (DES, AES-128/192/256).
  `seshat.trap.security_name`, `engine_id` and `context_name` are filled.
* Every varbind carries `oid`, `type`, `value` (always a string) and `raw` (hex). `name`, `mib` and
  `description` are filled only when the MIB library can translate the OID; until then events carry
  `seshat.trap.translated: false`. Octet strings that are printable text are shown as text, anything
  else as `0x...` hex (MAC addresses become `aa:bb:...` once the MIB library knows the object is a
  PhysAddress).
* The sender is stamped `seshat.device.status: unknown` and `seshat.enrichment.level: none` until
  the device knowledge base exists. `host.ip` is the datagram's source address (plus the v1 agent
  address when different), `seshat.source.listener` is `snmp-trap-udp-default`.
* A datagram that cannot be decoded is still forwarded as an event with `error.code: snmp.decode`
  and `seshat.trap.version: unknown`, and counted in `seshat_snmp_decode_errors_total`. The raw
  datagram rides on the in-process event (not in the JSON) for the future raw-relay output.

## Informs

An inform is a trap the sender wants confirmed. Seshat accepts it into the pipeline and then answers
with the same variable bindings and no error. For v3 informs the sender first asks the listener for
its engine ID (RFC 3414 discovery); Seshat answers that too. Seshat is the *authoritative* engine
for informs, which is why they need no engine ID registration (below).

## SNMPv3: engine IDs and users

Every SNMPv3 message names an **authoritative engine ID**, and the authentication and privacy keys
are derived (localised) from the user's passphrase *and that engine ID*:

* For **traps** the sender is authoritative. Seshat can only verify a trap if it knows the sender's
  engine ID, so each v3 trap sender's engine ID must be **registered** (Inputs, SNMP, "SNMPv3 sender
  engine IDs", or `POST /api/inputs/snmp/engine-ids`), optionally bound to its source address. Leave
  the source empty for a sender behind NAT or with changing addresses.
* For **informs** the receiver (Seshat) is authoritative, so the sender uses Seshat's own engine ID,
  which it discovers automatically. Nothing needs registering.

Add one USM user per credential set (Inputs, SNMP, "SNMPv3 users", or `/api/inputs/snmp/v3-users`).
Passphrases are 8 to 256 characters, stored **encrypted** (AES-256-GCM with a key derived from
`SESHAT_SECRET_KEY`) and never returned by the API. Changing `SESHAT_SECRET_KEY` makes stored
passphrases unreadable: the affected users are skipped and logged until their passphrases are
entered again. Prefer SHA-256 or stronger with AES; MD5 and DES exist for old devices.

### Unknown engine IDs

A v3 message whose engine ID is neither Seshat's own nor registered for that source is **dropped
and counted** (`seshat_snmp_traps_dropped_total{reason="unknown_engine"}`), and the pair of source
address and engine ID is listed at `GET /api/inputs/snmp/unknown-engines` and on the SNMP page. That
list is the way to onboard a sender: check that the address is really your device, then press
Register. Seshat deliberately never learns an engine ID on its own; automatic learning would let any
host that can send a UDP packet enrol itself. The list is per node, kept in memory, capped at 256
entries and cleared on restart. When it is full the least recently seen entry makes room (and
entries idle for 24 h expire), so a flood of spoofed pairs cannot keep a real new device off the
list (`seshat_snmp_unknown_engines_evicted_total`).

### Replay protection: the SNMPv3 time window

Authenticated SNMPv3 messages carry the sending engine's boot counter and clock (`engineBoots`,
`engineTime`). Seshat applies the RFC 3414 timeliness check to every message that passed
authentication (a message that failed authentication never changes any stored clock):

* **Traps** (the sender is authoritative): Seshat remembers, per sender engine ID, the highest boots
  counter and clock it has seen. The first message from an engine is accepted and starts its record. A
  higher boots counter is accepted (the device rebooted) and replaces the record. A lower boots
  counter, the latched value 2147483647, or the same boots counter with an engine time more than 150
  seconds behind where the record says the sender's clock should be, is dropped.
  The table is bounded (4096 engines, oldest evicted) and per node.
* **Informs** (Seshat is authoritative): the message must carry Seshat's own boots counter and an
  engine time within 150 seconds of Seshat's. A sender that is out of step gets the standard
  authenticated `usmStatsNotInTimeWindows` Report with Seshat's current boots and time (when it asked
  for reports), which a conforming sender uses to resynchronise and resend. Seshat's boots counter
  changes when it restarts, so informs sent right after a restart are answered this way once.

Drops are counted as `seshat_snmp_traps_dropped_total{reason="v3_not_in_time_window"}`. The check is
the setting **Drop replayed or badly skewed SNMPv3 messages** (`v3_time_window` in
`PUT /api/inputs/snmp`, default on).

Limits to know: the RFC window still accepts an exact replay *inside* the 150 s window, and a device
that does not keep a monotonic boots counter or clock is dropped by design. Typical offenders are
agents that restart their clock at zero without increasing `engineBoots` (traps are dropped until the
clock passes its old value) and one-shot tools that send every trap as boots 0 and time 0 from a new
process. Fix the device (persist the boots counter) or, for a trusted segment, switch the setting off
and rely on the allow-list; the drop counter shows how many messages are affected.

## Allow-list and rate limits

Both are edited in the UI or with `PUT /api/inputs/snmp` and apply immediately on every node.

* **Allowed sources**: CIDRs or single addresses. Empty accepts every source (Seshat's default is to
  accept everything). A datagram from anywhere else is dropped before it is decoded
  (`reason="not_allowed"`).
* **Rate limits**: a token bucket per source address (`per_source_rate` per second,
  `per_source_burst`) and a global bucket (`global_rate`, `global_burst`). `0` disables a limit.
  Defaults: 500/s burst 1000 per source, 20 000/s burst 40 000 global.
* **Sampled drop**: the receive path never blocks or queues. A datagram over a limit is dropped and
  counted (`rate_limited_source` or `rate_limited_global`); every `sample_every`-th over-limit
  datagram (default 100, `0` = none) is let through anyway, so a storm stays visible downstream, and
  counted in `seshat_snmp_traps_sampled_total`.

## Metrics

| Metric | Labels |
|---|---|
| `seshat_snmp_traps_received_total` | `version` (`v1`, `v2c`, `v3`) |
| `seshat_snmp_traps_dropped_total` | `reason` (`not_allowed`, `rate_limited_source`, `rate_limited_global`, `unknown_engine`, `v3_auth_failed`, `unsupported_pdu`, `v3_not_in_time_window`, `decoder_panic`) |
| `seshat_snmp_decode_errors_total` | none |
| `seshat_snmp_informs_acked_total` | none |
| `seshat_snmp_traps_sampled_total` | none |

`v3_auth_failed` covers unknown users, wrong passphrases and undecryptable messages.
`v3_not_in_time_window` is the replay/skew check above. `decoder_panic` counts datagrams on which a
decoder (the SNMP library included) failed unexpectedly: the datagram is dropped, `seshat_input_panics_total{input="snmp_trap"}`
is incremented, one rate-limited error line names the source address (the line carries the panic text, at most 200 bytes, but never the datagram), and the
listener carries on.

An SNMPv3 message is also structurally validated before it is handed to the decoding library: the
message ID, size, flags, security model, the user-security block (engine ID, boots, time, user name,
authentication and privacy parameters) and the scoped PDU must all be present with the right types.
A message that fails that check is counted in `seshat_snmp_decode_errors_total` and forwarded as an
undecodable event like any other undecodable datagram.

## Trying it

Replace `seshat.example.com` with your host. The OIDs below are documentation examples.

```sh
# v2c linkDown trap
snmptrap -v2c -c public seshat.example.com:162 '' 1.3.6.1.6.3.1.1.5.3 \
    1.3.6.1.2.1.2.2.1.1.10114 i 10114 1.3.6.1.2.1.2.2.1.8.10114 i 2

# v1 enterprise-specific trap
snmptrap -v1 -c public seshat.example.com:162 1.3.6.1.4.1.32473.1 192.0.2.77 6 7 '' \
    1.3.6.1.4.1.32473.1.1 i 5

# v2c inform (waits for the acknowledgement)
snmpinform -v2c -c public seshat.example.com:162 '' 1.3.6.1.6.3.1.1.5.4

# v3 authPriv trap (needs the user and the sender's engine ID registered)
snmptrap -v3 -l authPriv -u trapuser -a SHA -A 'example-auth-passphrase' \
    -x AES -X 'example-priv-passphrase' -e 0x80007ed90402000000000003 \
    seshat.example.com:162 '' 1.3.6.1.6.3.1.1.5.3

# v3 inform (needs only the user)
snmpinform -v3 -l authPriv -u trapuser -a SHA -A 'example-auth-passphrase' \
    -x AES -X 'example-priv-passphrase' seshat.example.com:162 '' 1.3.6.1.6.3.1.1.5.4
```

Site and VRF: the page's Site and VRF fields (`site`, `vrf` in `PUT /api/inputs/snmp`) tag everything this listener receives with `seshat.source.site` / `seshat.source.vrf`. They are part of a device's identity in the device knowledge base (`docs/device-kb.md`), so the same address at two sites stays two devices. Leave them empty for the `default` site. Each trap's sysName (when the sender includes it) and a v3 sender's engine ID are reported to the knowledge base as learning signals.

See what arrived: the SNMP page's live tail, or `GET /api/events/tail?dataset=seshat.trap&limit=20`
(administrator or operator; the last 500 events in memory).


## Known limits

* UDP only (TCP transport is not implemented).
* The RFC 3414 time window accepts a replay inside its 150 s (see above); the per-engine clocks are
  per node and are forgotten on restart (the first message of each engine after a restart is accepted).
* The unknown-engine list and the counters are per node.
