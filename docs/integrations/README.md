# Integrations: one model for other apps

Other apps (a change-planning tool, a DHCP service, an asset database, a monitoring system) read Seshat's data,
receive its events and, through an edge, reach remote networks. Every one of them plugs into the same surface:

- an **integration client**: one record per consuming app, holding what it may do, where, and how fast;
- **capabilities**: each one opens exactly the routes it names, and nothing else answers for the client;
- **versioned contracts**: the shapes the app builds against, discoverable from the API;
- one list of **error codes**, one audit trail, one set of rate limits and metrics.

There are no consumer-specific roles or endpoints. A new need is either an existing capability or a new capability
in the table below.

## The model

An administrator registers a client (Settings, Integrations, or `POST /api/integrations/clients`) and issues tokens
for it. A client record holds:

| Field | Meaning |
|---|---|
| `name`, `description`, `owner` | Free text; the name is unique and appears in the audit log and the metrics. |
| `contracts` | The contracts and versions the app is built against (informational; checked against the registry). |
| `scope` | `sites`, `tenants` (what the tracker capabilities see or write; `*` is everything) and `edges` (what the edge capabilities reach: edge ids, `group:<id>` for an edge group's relay and SNMP-read routes, or `*`; a group is not reached through its members' entries, nor they through the group's). Nothing is reachable without a scope. |
| `capabilities` | The capabilities it holds. |
| `limits` | Optional rate limit per capability (below). |
| `expires_at`, `disabled` | Expiry and an off switch. A disabled or expired client's tokens stop working at once. |

A client's tokens follow its definition: editing the scope, the capabilities or the limits takes effect on tokens
already issued, with no re-issue. A token carries the client's scope; the secret is shown once and stored hashed.

`PUT /api/integrations/clients/{id}` changes only the fields the body names: an omitted field keeps its stored
value, so a partial body never re-enables a disabled client, clears its expiry or drops its limits. Send
`"expires_at": null` to clear the expiry. On create, an omitted field is empty; the name and at least one capability
are required.

**An empty scope is deny-all for a client.** A client with no sites, tenants or edges reaches nothing: the tracker
capabilities see nothing, and push-sync ingest is refused (`403 out_of_scope`). Give it a scope, or `*` for a deliberate
unrestricted grant.

### Tokens and rotation

A client holds at most **two live tokens**, so a secret can be rolled without an outage. The cap is enforced by the
database in the same transaction as the insert, so concurrent requests cannot exceed it (`409 token_limit`).

1. `POST /api/integrations/clients/{id}/tokens/{tid}/rotate` issues a new token and keeps the old one valid for a
   grace period (`grace_hours`, default 24, at most 720). The new token and the old one's retirement happen in one
   transaction, so a refused rotation leaves nothing behind. A grace period needs a free slot; `grace_hours: 0` revokes
   the old token in the same step, is net zero, and works at the cap.
2. The app swaps to the new secret during the grace period.
3. The old token then expires by itself. `DELETE /api/integrations/clients/{id}/tokens/{tid}` revokes a token
   earlier.

A token stops working when the administrator who issued it is disabled or loses the administrator role, as with every
API token. Tokens expire after 90 days unless `expires_in_days` says otherwise (never beyond the client's own expiry).

## Onboarding a new app

1. Ask for the integration: what the app reads, receives or reaches, with the capability and contract for each, the
   expected volume and rate, and whether it needs read or write intent.
2. Register the client with the capabilities that cover exactly that, a scope, and (if the defaults do not fit) limits.
3. Issue a token and hand over the secret through a secure channel.
4. The app calls `GET /api/integrations/contracts` at start-up and fails clearly if a version it needs is gone.
5. Watch the client's calls and refusals in Settings, Integrations (and `seshat_integration_*` in the metrics) during
   the first days; a steady stream of `capability_missing` means the app calls something it was not given.

## Capabilities

Each capability opens exactly the routes it names. A client token on any other route answers
`403 capability_missing`; routes that name no capability (the console, users, settings, the metrics) are closed to it.

| Capability | Opens | Default limit |
|---|---|---|
| `tracker.read` | Device lookup, CSV export, the device list, a device's ports, port history (`GET /api/tracker/lookup`, `/export.csv`, `/devices`, `/devices/{id}/ports`, `/ports/{device}/{ifindex}/history`) | 600 / min |
| `tracker.bulk` | Batch lookup and prefix bindings (`POST /api/tracker/lookup/batch`, `GET /api/tracker/bindings`). The limit counts **calls**: a batch of 500 queries is one admit, and so is each page of bindings | 60 / min |
| `tracker.poll` | Poll a device now (`POST /api/tracker/devices/{id}/poll`) and per-device status | 60 / min |
| `sync.write` | Push-sync ingest on the portal (`POST /api/sync/v1/batches`, `GET /api/sync/v1/ping`). The client needs a scope (a site and/or tenant list, or `*`); a token for it must name its `stream_id`. Records outside the scope are refused whole (`out_of_scope`). | 120 / min |
| `events.subscribe` | The client's own event subscriptions and the event log (`GET/POST /api/integrations/subscriptions`, `GET/PUT/DELETE /api/integrations/subscriptions/{id}`, `GET /api/integrations/events`), within the client's scope. See [Events](#events) | 60 / min |
| `edge.relay.tcp` | A TCP stream through an edge, or through any healthy member of an edge group (`POST /api/edges/{id}/relay`, `POST /api/edge-groups/{id}/relay`), with a declared `read` or `write` intent | 60 / min |
| `edge.snmp.read` | SNMP reads (get, getnext, getbulk, walk) executed by an edge on its own network: `POST /api/edges/{id}/snmp`, `GET .../snmp/key`, `POST .../snmp/windows` ([SNMP reads](../edge.md#snmp-reads)); and `POST /api/edge-groups/{id}/snmp` and `.../snmp/windows` through a member of an edge group, profile credentials only | 120 / min |

Every client token can also call `GET /api/integrations/contracts` and `GET /api/me` (its own identity).
Seshat stays read-only toward devices: no capability writes to a device. Capabilities for routes that ship later are
accepted by the client API so a client can be defined ahead of them; they open nothing until their routes exist.

### Existing tokens keep working

The two token roles that predate clients map onto capabilities, with no migration step and no change in behaviour:

| Token role | Behaves as |
|---|---|
| `tracker:read` | `tracker.read` + `tracker.poll` (so it still reaches poll-now) + `tracker.bulk` (the batch lookup and prefix bindings) |
| `sync` | `sync.write` |

They are listed under Settings, API tokens, answer refusals with the unchanged `403 forbidden`, and are counted in the
metrics under the client label `(legacy)`. Their behaviour is unchanged, including that an unscoped legacy `sync`
token is accepted for compatibility (with a warning); only a client's empty scope is deny-all. New integrations should
use a client.

## Events

A client holding `events.subscribe` receives events without anyone configuring a route or an output by hand. It
creates a **subscription**: a filter (event kinds, and optionally sites and tenants), an optional webhook URL, and a
secret that signs the deliveries. The events are the ones Seshat already produces, offered under the contract
[`seshat.event`](../schema/events.md) version 1:

| Kind | Meaning |
|---|---|
| `tracker.move` | A device was seen somewhere new (the Device Tracker closed its interval elsewhere) |
| `tracker.new` | The first sighting of a MAC address the tracker had never seen |
| `tracker.sighting` | A known device was seen again |
| `tracker.watch` | A watch-list entry matched |
| `link.up`, `link.down` | An interface came up or went down (an IF-MIB `linkUp` or `linkDown` trap, or a syslog message the packs map to `interface-up` or `interface-down`) |

How it fits together:

1. **Subscribe.** `POST /api/integrations/subscriptions` with `{"name": "...", "filter": {"kinds": ["tracker.move"], "sites": ["..."]}, "url": "https://...", "secret": "..."}`.
   A client manages only its own subscriptions, at most 5 by default (the administrator sets the default and a
   per-client limit). An administrator can list and manage every client's, and sees which client owns each. The secret
   is write-only; leave it out and Seshat generates one and shows it once.
2. **Scope.** The client's scope always applies and a filter can only narrow it. **A client with no scope receives
   nothing**, the same deny-all rule as the tracker capabilities.
3. **Receive.** Seshat `POST`s batches of up to 100 events, signed with `X-Seshat-Signature: sha256=<hex>` (HMAC-SHA256 of
   the exact body under the subscription's secret), with the retries, `Retry-After` handling and per-subscription pacing
   described in the [contract](../schema/events.md#guarantees). Every delivery is attempted by the cluster leader only.
4. **Catch up.** Every event also lands in an event log, and `GET /api/integrations/events?after=<cursor>` returns the
   caller's in-scope, matching events in order with a `next_cursor`, whether or not a webhook is set. A consumer that was
   down resumes from its last cursor; a subscription with no URL is a pull-only one. The log keeps 7 days (and 500,000
   events) by default; Settings, Integrations changes both.
5. **Deduplicate.** Delivery is **at least once**. Every event has a stable `id`; a consumer deduplicates on it.

Webhook targets are checked: `https` is required unless an administrator allows `http` for the client, and loopback and
link-local addresses are refused (so a subscription cannot be used to reach Seshat's own host) unless an administrator
allows local targets for the client; cloud-metadata addresses are refused always. Private (RFC 1918) ranges are
allowed. The check is repeated when the connection is opened.

Verifying a delivery (Go):

```go
func verify(secret, body []byte, header string) bool {
	mac := hmac.New(sha256.New, secret)
	mac.Write(body)
	return hmac.Equal([]byte("sha256="+hex.EncodeToString(mac.Sum(nil))), []byte(header))
}
```

and Python:

```python
import hashlib, hmac

def verify(secret: bytes, body: bytes, header: str) -> bool:
    return hmac.compare_digest("sha256=" + hmac.new(secret, body, hashlib.sha256).hexdigest(), header)
```

Check the signature over the raw request body before parsing it. Settings, Integrations shows each subscription's
state, last delivery, last error, how many events are pending and how old the oldest is. Metrics:
`seshat_integration_deliveries_total{client,result}`, `seshat_integration_events_delivered_total{client}`,
`seshat_integration_events_appended_total` and `seshat_integration_events_dropped_total` (events lost because the
append queue overflowed; the pipeline is never slowed down).

The administrator's controls: `GET/PUT /api/integrations/events/settings` (retention in days and rows, the default
subscription limit) and `GET/PUT /api/integrations/clients/{id}/event-policy` (allow `http`, allow local targets, the
client's own subscription limit). Both are administrator only and closed to client tokens.

## Error codes

Refusals use the usual body, `{"error": {"code": "...", "message": "..."}}`. These codes are shared by every
capability and never change meaning; a consumer should switch on `code`, not on the message.

| Code | Status | Meaning |
|---|---|---|
| `capability_missing` | 403 | The client lacks the capability the route needs (also: a client token on a route that names none). |
| `out_of_scope` | 403 / 404 | The target (site, tenant, device, edge) is outside the client's scope. A route may answer 404 where it hides existence. |
| `edge_offline` | 503 | The edge the call needs is not connected. |
| `target_not_allowed` | 403 | The relay or SNMP target is not on the edge's allow list. |
| `limit_exceeded` | 429 | The client's rate limit (or a size limit) was hit; honour `Retry-After`. |
| `contract_version_unsupported` | 409 | The contract version asked for is not served. |
| `relay_disabled` | 403 | Relay is off on the edge. |
| `write_not_allowed` | 403 | Write intent on an edge that allows read only. |
| `dial_failed` | 502 | The edge could not connect to the relay target; `error.fields.class` is `refused`, `timeout` or `unreachable`. |
| `relay_timeout` | 504 | The edge did not open the relay in time. |
| `snmp_disabled` | 403 | SNMP reads are off on the edge. |
| `credential_unavailable` | 422 | The named SNMP profile is not on the edge, or the sealed credential cannot be used (not sealed to this edge for this target, expired, already used). |
| `snmp_timeout` | 504 | The device did not answer in time, or the request ran out of time. |
| `snmp_auth_failed` | 502 | The device did not accept the SNMPv3 credential. |
| `snmp_error` | 502 | Another failure of the SNMP exchange with the device. |
| `window_expired` | 409 | The read window is unknown, someone else's, altered or over; open a new one. |

Other codes keep their meaning from the rest of the API (`unauthenticated` 401, `validation_failed` 400,
`not_found` 404). The client API adds `token_limit` (409, two live tokens already), `client_inactive` (409, the client is
disabled or expired, or no longer holds the capability) and `token_not_live` (409, rotating a token that is already
revoked or expired). The event subscription API adds `subscription_limit` (409, the client already holds the most
subscriptions it may).

## Rate limits

Capabilities that open long-lived sessions (`edge.relay.tcp`) also have a cap on sessions open at once, per client: `"limits": {"edge.relay.tcp": {"concurrent": 4}}`, default 2. Beyond it, `429 limit_exceeded`.


Each client has a token bucket **per capability**: a sustained rate (calls per minute) and a burst. Defaults are in the
table above (burst is a sixth of the rate, at least 5). Set a client's own with
`"limits": {"tracker.read": {"per_minute": 120, "burst": 20}}`; a missing field uses the default. A call over the limit
answers `429 limit_exceeded` with a `Retry-After` header in seconds. A batch call counts once; push-sync ping counts
like ingest. The buckets are held **in memory, per process**: they reset when Seshat restarts, and each replica keeps
its own, so with several replicas behind a load balancer a client's effective ceiling is the limit times the number of
replicas that serve it.

## Audit and metrics

Three records, all bounded so a busy or misbehaving app cannot flood the log:

- **Administration.** Every mutation of a client or its tokens is audited (`integration.client.create|update|delete`,
  `integration.token.issue|rotate|revoke`) under the administrator's name. Event subscriptions are audited the same way (`integration.subscription.create|update|delete`, under the
  client's own name when a client manages them), as are the event settings and a client's webhook policy
  (`integration.events.settings`, `integration.client.event_policy`); secrets are never written to the log.
- **Refusals.** The first refusal of a given code for a client and capability in a minute is audited at once as
  `integration.refused`, actor `client:<name>`, detail `{client_id, client, capability, code}`; later ones in that
  minute are only counted.
- **Usage.** Every call is counted in memory and written to the audit log as **one aggregated row per client and
  capability per minute that had activity** (`integration.usage`, actor `client:<name>`, detail
  `{client_id, client, capability, minute, calls, refusals: {code: n}}`). The rows are written by a background task
  every few seconds, never on the request path, and a final flush runs at shutdown; a minute with no calls writes
  nothing. A database outage keeps the pending rows in memory (bounded) and writes them when it returns. Routes that
  audit each call themselves (lookup, export, poll-now, push-sync) keep doing so, as `client:<name>`.

Prometheus: `seshat_integration_calls_total{client,capability}` and
`seshat_integration_refusals_total{client,capability,code}`. The `client` label is the client's numeric id (shown in
Settings, Integrations), so renaming a client does not split its series; the label `(legacy)` covers `tracker:read` and
`sync` tokens. A deleted client's counters are dropped. Settings, Integrations shows the same counters since the last
start, the client's last use and its recent audit entries.

## Contracts and versioning

`GET /api/integrations/contracts` (any authenticated caller, client tokens included) lists every contract with the
versions currently served and the path of its documentation:

```json
{"contracts": [
  {"name": "seshat.tracker.bindings", "versions": [1], "doc": "docs/schema/tracker.md"},
  {"name": "seshat.tracker.lookup", "versions": [1], "doc": "docs/schema/tracker.md"},
  {"name": "seshat.tracker.sync",   "versions": [1], "doc": "docs/schema/tracker.md"},
  {"name": "seshat.event",          "versions": [1], "doc": "docs/schema/events.md"}
]}
```

| Contract | Used by | Reference |
|---|---|---|
| `seshat.tracker.lookup` | `tracker.read`, `tracker.bulk` (each item of a batch) | [Lookup response](../schema/tracker.md#lookup-response), [Batch lookup](../schema/tracker.md#batch-lookup) |
| `seshat.tracker.bindings` | `tracker.bulk` | [Prefix bindings](../schema/tracker.md#prefix-bindings) |
| `seshat.tracker.sync` | `sync.write` | [Push-sync envelope](../schema/tracker.md#push-sync-envelope) |
| `seshat.event` | `events.subscribe` | [Integration event contract](../schema/events.md) |

**Versioning rule, for every contract:** an additive change (a new field, a new optional parameter, a new enum value a
client can ignore) keeps the version; consumers must ignore keys they do not know. A breaking change bumps the version,
and the previous version is served for at least one minor release, so a consumer has a release to move. A consumer
checks the list at start-up and fails clearly when its version is gone.

## Requesting an integration

Send the integration owner the following, one line per item the app reads, receives or reaches: the consuming app,
the capability and contract, the expected volume and rate, whether it needs read or write intent, and the owner's
contact. A request either maps onto the capabilities above or adds a capability to the table; it never adds a
consumer-specific endpoint or role.

