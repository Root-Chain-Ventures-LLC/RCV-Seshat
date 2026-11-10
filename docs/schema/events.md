# Integration event contract

Contract name `seshat.event`, **version 1**. This document defines the events that Seshat hands to
other apps through an [integration client](../integrations/README.md) holding the `events.subscribe`
capability: the envelope, the event kinds, the `data` block, how to receive events (a signed webhook, or
by pulling a replay cursor), and what a consumer can rely on. It follows the rules of every contract: an
additive change keeps the version, and a consumer must ignore keys it does not know.

The events are the ones Seshat already produces: tracker events, interface link events and the alerts of its built-in alert engine. Nothing here
describes a way to act on a device.

## Envelope

A webhook delivery is one `POST` with a JSON body; `GET /api/integrations/events` returns the same events
in the same element shape.

```json
{
  "contract": {"name": "seshat.event", "version": 1},
  "events": [
    {
      "id": "01M6F46RZG3HKBNNAFH3QSBPCR",
      "cursor": "YzEuMTI",
      "kind": "tracker.move",
      "time": "2026-11-02T21:56:19.056Z",
      "site": "example-site-a",
      "tenant": "example-tenant",
      "data": { "...": "see below" }
    }
  ]
}
```

| Field | Type | Meaning |
|---|---|---|
| `contract` | object | `name` is `seshat.event`, `version` an integer. Webhook bodies carry it; a pull response carries it next to `events`. |
| `events` | array | One to 100 events in a webhook body, oldest first; up to 500 in a pull response. |
| `events[].id` | string | The event's own id (the pipeline's `event.id`, a ULID). Unique and stable: **deduplicate on it**, because delivery is at least once. |
| `events[].cursor` | string | Opaque replay cursor. Pass it as `after` to receive the events after this one. Never parse it. |
| `events[].kind` | string | One of the [kinds](#kinds). |
| `events[].time` | string | When the event happened (the event's `@timestamp`), RFC 3339 UTC. |
| `events[].site` | string | The site the event belongs to, or empty. This is what the subscription's scope and filter are matched against. |
| `events[].tenant` | string | The tenant, or empty. |
| `events[].data` | object | The event's ECS and `seshat.*` fields, see [`data`](#data). |
| `gap` | object | Webhook bodies (and pull responses, as `gap` next to `truncated`) only, and only when retention removed events this consumer had not received: `{"from": <cursor>, "to": <cursor>}`. Events with a cursor after `from` and up to `to` are gone; `events` carries what remains. See [Retention](#guarantees). |

## Kinds

Every kind is produced by something Seshat already emits; none exists only for integrations.

| Kind | Produced by | `site` and `tenant` | When |
|---|---|---|---|
| `tracker.move` | Device Tracker, `seshat.tracker` `interval-opened` | the site and tenant of the place the device was seen | The tracker opened an interval for an entity that had an interval somewhere else, which it closed. `seshat.tracker.fact` says what moved: `location` (a MAC on a port), `l3` (an IP binding), `wireless`, `user`. |
| `tracker.new` | Device Tracker, `seshat.tracker` `interval-opened` | as above | The first interval of a MAC address the tracker had never seen. |
| `tracker.sighting` | Device Tracker, `seshat.tracker` `interval-opened` | as above | An interval opened for a known MAC that is neither new nor a move: a device seen again after its interval closed. |
| `tracker.watch` | Device Tracker, `seshat.tracker` `watch.hit` | as above | A watch-list entry matched. `seshat.tracker.watch` carries the entry's `id` and `kind`; its `value`, `label` and the `reason` (`appeared`, `moved`, `seen`) are operator-written and are removed from what clients receive (pull and webhook): only an administrator's read of the log has them. The tracker's own quiet period (ten minutes per entry, MAC and reason) applies. |
| `link.up` | traps (`seshat.trap`, IF-MIB `linkUp`, `event.action` `interface-up`) and syslog (`event.action` `interface-up`) | the device's site and tenant from the inventory; for a device not in the inventory, the site of the input that received the message, and no tenant | An interface came up: an IF-MIB `linkUp` trap (notification `1.3.6.1.6.3.1.1.5.4`), or a vendor syslog message that a pack maps to `interface-up`. |
| `link.down` | traps (`seshat.trap`, IF-MIB `linkDown`, `event.action` `interface-down`) and syslog (`event.action` `interface-down`) | as above | An interface went down (`linkDown`, notification `1.3.6.1.6.3.1.1.5.3`, or syslog mapped to `interface-down`). |
| `alert.firing` | the built-in alert engine (`seshat.alert`, Alerting) | the alert's device site and tenant | An alert fired: a rule's condition started to hold for an identity. `data.seshat.alert` carries `id`, `rule`, `status`, `severity`, `title`, `summary`, `fingerprint`, `occurrences`, `starts_at` and the interface when there is one; `seshat.device` the device. |
| `alert.resolved` | as above | as above | An alert ended: its condition cleared, it timed out, or an operator closed it. Same `data`, with `status` `resolved`. |

Not offered as kinds: interval closes and extensions, `unknown.appeared`, and `interface-admin-down`. A
new kind is an additive change.

## `data`

`data` reuses the field names of the Seshat event document ([`fields.md`](fields.md)); a field that does
not apply to the event is absent. It is a fixed subset of the document, so a consumer need not know the
rest of the schema.

| Path | Present on | Meaning |
|---|---|---|
| `@timestamp` | all | When the event was produced. |
| `event.action` | all | `interval-opened` or `watch.hit` (tracker); `interface-up` or `interface-down` (traps and syslog; the trap's notification name stays in `seshat.trap.name`). |
| `event.dataset` | all | `seshat.tracker`, `seshat.trap` or `seshat.syslog`. |
| `event.severity` | tracker | Numeric severity. |
| `message` | link | The one-line rendering of the trap or syslog message. |
| `host.mac` | tracker | The device's MAC address (lowercase, colon separated), a one-element array. |
| `host.ip`, `host.name` | link | The address the message came from, and the device's name once the inventory knows it. |
| `related.ip`, `related.hosts`, `related.user` | all, when known | The IP address, host names and user the event involves. |
| `seshat.source.*` | all | Where the event entered Seshat: `listener`, `input`, `site`, and for link events `ip` and `port` of the sender. |
| `seshat.device.*` | link events; tracker events with a `location` fact | `id`, `name`, `site`, `tenant`, `status` (`known`, `unknown`, `stale`) and `interface.{name,index,alias}` of the device the event is about (the switch, for a tracker location). Absent on tracker events with an `l3`, `wireless` or `user` fact. |
| `seshat.interface.{name,index,state}` | link | The interface that changed. `state` is always `up` or `down`; `index` (the ifIndex) and `name` are set when the message or the inventory gives them (a trap carries the index, syslog the name). |
| `seshat.trap.{oid,name,mib,version,vars}` | link, from a trap | The notification and its variables by name (`vars`, for example `ifIndex`, `ifOperStatus`). The raw varbind list and the security names are not carried. |
| `seshat.tracker.*` | tracker | The tracker fact: `fact`, `source`, `observed_at`, `first_seen`, `last_seen`, `interval_id`, `confidence`, `mac`, `ip`, `vrf`, `hostname`, `user`, `oui_vendor`, `randomized_mac`, `lease_expires`, `gateway`, `location.{site,device,port,ifindex,vlan,ap,ssid,band,rssi,channel,circuit_id,remote_id,circuit_kind,trace}`, and `watch.{id,kind}` on `tracker.watch` (clients; `value`, `label` and `reason` for administrators). |

Example `data` of a `tracker.move` (synthetic):

```json
{
  "@timestamp": "2026-11-02T21:56:19.056Z",
  "event": {"action": "interval-opened", "dataset": "seshat.tracker", "severity": 6},
  "host": {"mac": ["02:00:5e:20:00:07"]},
  "seshat": {
    "device": {"id": "dev-0003", "name": "Example Switch 3", "site": "example-site-a", "tenant": "example-tenant", "status": "known",
               "interface": {"index": 10114, "name": "GigabitEthernet1/0/14"}},
    "source": {"listener": "tracker", "input": "poller", "site": "example-site-a"},
    "tracker": {"fact": "location", "source": "trap", "mac": "02:00:5e:20:00:07", "interval_id": "iv-loc-000002", "confidence": 0.9,
                "observed_at": "2026-11-02T21:55:19.050Z", "first_seen": "2026-11-02T21:55:19.050Z", "last_seen": "2026-11-02T21:55:19.050Z",
                "location": {"site": "example-site-a", "device": "Example Switch 3", "port": "GigabitEthernet1/0/14", "ifindex": 10114, "vlan": 120}}
  }
}
```

Example `data` of a `link.down`:

```json
{
  "@timestamp": "2026-11-02T21:56:19.057Z",
  "event": {"action": "interface-down", "dataset": "seshat.trap"},
  "message": "IF-MIB::linkDown ifIndex.10114=10114 ifOperStatus.10114=down",
  "host": {"ip": ["192.0.2.11"], "name": "Example Switch 3"},
  "seshat": {
    "device": {"id": "dev-0003", "name": "Example Switch 3", "site": "example-site-a", "tenant": "example-tenant", "status": "known",
               "interface": {"index": 10114, "name": "GigabitEthernet1/0/14"}},
    "interface": {"index": 10114, "name": "GigabitEthernet1/0/14", "state": "down"},
    "source": {"input": "snmp", "ip": "192.0.2.11", "site": "example-site-a"},
    "trap": {"oid": "1.3.6.1.6.3.1.1.5.3", "name": "linkDown", "mib": "IF-MIB", "version": "v2c", "vars": {"ifIndex": "10114", "ifOperStatus": "down"}}
  }
}
```

## Receiving events

### Webhook

A subscription with a `url` is delivered by `POST` with `Content-Type: application/json`, the body above, and:

| Header | Value |
|---|---|
| `X-Seshat-Signature` | `sha256=<hex>`: the HMAC-SHA256 of the **exact request body** under the subscription's secret. |
| `User-Agent` | `<org>-Seshat/<version>` (the branding values). |

Answer `2xx` once the events are stored. Anything else is a failed delivery.

**Verify the signature before parsing**, over the raw bytes, with a constant-time comparison.

Go:

```go
func verify(secret, body []byte, header string) bool {
	mac := hmac.New(sha256.New, secret)
	mac.Write(body)
	want := "sha256=" + hex.EncodeToString(mac.Sum(nil))
	return hmac.Equal([]byte(want), []byte(header))
}
```

Python:

```python
import hashlib, hmac

def verify(secret: bytes, body: bytes, header: str) -> bool:
    want = "sha256=" + hmac.new(secret, body, hashlib.sha256).hexdigest()
    return hmac.compare_digest(want, header)
```

The secret is write-only: it is set (or generated, and shown once) when the subscription is created, stored
sealed, and never returned by the API. To change it, `PUT` a new one.

### Pull

`GET /api/integrations/events?after=<cursor>&limit=<n>` returns the events the caller may see, oldest first:

```json
{
  "contract": {"name": "seshat.event", "version": 1},
  "events": [ { "id": "...", "cursor": "...", "kind": "link.down", "time": "...", "site": "...", "tenant": "...", "data": {} } ],
  "next_cursor": "YzEuMTI",
  "has_more": false,
  "truncated": false
}
```

- Start with no `after` (the start of the retained log) or `after=now` (nothing, and a cursor at the head).
  Afterwards pass the previous `next_cursor`. When `has_more` is true, call again at once; when it is false you
  are caught up, and polling about once a second is plenty.
- `next_cursor` advances over events that are not yours too, so a quiet consumer does not rescan them.
- `limit` is 1 to 500 (default 100). `subscription=<id>` applies one subscription's filter instead of all of
  the client's enabled ones.
- `truncated: true` means the cursor is older than the oldest retained event: some events were pruned before you
  read them. Re-synchronise from the tracker API if you cannot afford the gap.
- A cursor is only valid for this API; a made-up one is `400`.

Pull works with or without a webhook: a subscription with no `url` is pull only. Events are logged only while some
enabled subscription wants them, so create the subscription before you expect events.

## Guarantees

- **At least once.** An event can be delivered more than once (a retry after a timeout whose request had
  actually arrived, a fail-over between replicas, a restart). Deduplicate on `events[].id`.
- **Order.** Events of one subscription are delivered, and returned by pull, in the order they were logged. The log
  order is the order in which Seshat processed them, which is close to, but not exactly, the order in which they
  happened on the network; `time` is the event's own time.
- **Nothing is skipped over a failure.** A failed batch is retried unchanged before anything after it is sent.
  Retries back off from 2 seconds up to 5 minutes; `Retry-After` (seconds) on `408`, `425`, `429` and `5xx` is
  honoured up to **one hour** (a longer request counts as an hour). A `413` makes Seshat halve the batch and retry
  at once, down to a single event; a single event the receiver still refuses with `413` is a permanent failure
  (raise the receiver's request size limit). A response that refuses the request for good (another `4xx`) keeps the
  events and retries every 15 minutes, and the subscription shows the error; fix the receiver or the subscription and
  delivery continues where it stopped. The status shows the failure as a class to a client (`refused`, `timeout`,
  `tls`, `dns`, `http_<status>`, `blocked`, `config`, `failed`) and in full, with the response excerpt, to an
  administrator and in the server log.
- **Rate cap.** Seshat sends at most one request per second to a subscription, each with at most 100 events: a
  backlog drains at up to 100 events per second. Outbound deliveries are not client calls and do not count
  against the client's rate limit; pull calls do (`events.subscribe`, 60 per minute by default).
- **Position.** Each subscription's delivery position is stored with it, so a restart resumes where the last
  acknowledged batch ended and events that arrived while Seshat was down are delivered.
- **High availability.** Any replica appends the events it processes. Only the cluster leader delivers webhooks,
  so replicas do not send the same event twice; after a fail-over the new leader continues from the stored
  position. Subscription changes made on one replica reach the others within about 15 seconds. With PostgreSQL the
  replicas append to the log one at a time (a database lock), so ids are committed in the order they are handed out
  and a reader that has seen an event has seen every earlier one: a slow commit holds later events back instead of
  letting them be skipped.
- **Retention.** The log keeps 7 days and at most 500,000 events by default (administrators change both under
  Settings, Integrations). A consumer that was down longer than that misses the oldest events: the next webhook
  carries a `gap` (and a pull response `truncated` with the same `gap`), so the consumer knows to re-synchronise.
  A subscription created after events were pruned is not told about events it could never have had.
- **Off the hot path.** Logging an event never delays the pipeline. If the append queue is full the event is dropped
  from the log and counted in `seshat_integration_events_dropped_total`; that only happens when events arrive
  much faster than the database can store them. A failed write of a batch is a drop too: those events are lost and
  counted in `seshat_integration_events_append_failures_total`. Neither is retried.

## Scope and filters

A subscription has a `filter`: the `kinds` it wants (at least one), and optionally `sites` and `tenants`. The
client's own scope always applies: an event is delivered only if the **client's** sites or tenants allow it and the
filter allows it. A filter can narrow the scope and never widen it. **A client with no scope receives nothing.**
Scope and filter are checked per event when it is delivered or pulled, so editing the client's scope takes effect at
once.

## Webhook URLs

- `https` is required, unless an administrator allows `http` for that client.
- A URL may not carry credentials (`https://user:password@host/`); the secret signs the body.
- Seshat refuses to deliver to loopback, link-local, unspecified and multicast addresses (including a name that
  resolves to one, checked again when the connection is opened), unless an administrator allows local targets for
  that client. Private (RFC 1918) ranges are allowed, so a consumer inside the network works. The instance-wide
  switch `SESHAT_ALLOW_LOCAL_TARGETS` also lifts this check.
- **Cloud-metadata addresses are always refused**, including with local targets allowed and with the instance-wide
  switch on (`169.254.169.254`, `169.254.170.2`, `fd00:ec2::254`, `100.100.100.200`, `168.63.129.16`, also as an
  IPv4-mapped or NAT64 address, or as a name that resolves to one).
- A refusal tells a client which class of address was refused, never which address a name resolved to.
- Redirects are followed only within the same scheme, host and port; a redirect to another host is not followed
  and counts as a failed delivery (`http_3xx`). No proxy is used.
- The administrator's per-client settings are under `GET/PUT /api/integrations/clients/{id}/event-policy`; a
  subscription whose URL a tightened policy no longer allows stops delivering and shows why.

## Subscriptions

| Route | Does |
|---|---|
| `GET /api/integrations/subscriptions` | The caller's subscriptions with their delivery status, the kinds and the limit (an administrator sees every client's). |
| `POST /api/integrations/subscriptions` | Create. Body: `name`, `filter`, optional `url`, `secret`, `enabled`; an administrator also names the `client_id`. A client holds at most 5 subscriptions by default (`409 subscription_limit`). |
| `GET`, `PUT`, `DELETE /api/integrations/subscriptions/{id}` | Read, change (only the fields named) or delete. A client sees only its own: `404` otherwise. |
| `GET /api/integrations/events` | Pull. |

Delivery status, per subscription: `state` (`ok`, `failing`, `idle`, `paused`, `pull`), `last_attempt_at`,
`last_success_at`, `last_error`, `delivered`, `pending` (matching events not yet delivered, up to 1000), `lag_seconds`
(the age of the oldest pending event), and the `cursor` of the last event handed over.

## Versioning

`seshat.event` follows the contract rule in [`../integrations/README.md`](../integrations/README.md#contracts-and-versioning):
new kinds, new keys in `data`, and new envelope keys are additive and keep version 1; consumers ignore what they do
not know (including kinds they did not subscribe to). Removing or redefining a kind or field is breaking, bumps the
version, and the previous version is served for at least one minor release.
