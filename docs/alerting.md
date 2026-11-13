# Alerting

Seshat has a built-in alert engine, so an operator can run it without a separate NMS. It turns events and metric
samples into alerts, keeps their lifecycle, holds back the noise, and hands notifications to the channels you
configure ([notification channels](#notifications) are a separate component). It is **off until you enable a rule**:
the starter rules ship disabled. Routing events to a downstream alerting system keeps working exactly as before; the
engine is additional.

Everything here is read-only toward devices. Nothing in the engine writes to a device.

## Contents

- [Concepts](#concepts)
- [Rules](#rules): event, threshold, state change, absence
- [Alert lifecycle](#alert-lifecycle)
- [Noise control](#noise-control): silences, maintenance, dependencies, flapping
- [Notifications](#notifications): policies, escalation, repeat
- [Starter rules](#starter-rules)
- [Outputs](#outputs): `seshat.alert` events, subscriptions, metrics
- [High availability](#high-availability)
- [Hot path and limits](#hot-path-and-limits)
- [API](#api)

## Concepts

| Term | Meaning |
|---|---|
| **Rule** | A condition. Four kinds: event, threshold, state change, absence. |
| **Identity** (key, fingerprint) | What an alert is *about*: the rule plus a key such as the device and the interface. One identity has at most one open alert. |
| **Signal** | A compact record `firing` or `clear` for a rule and identity, appended by whichever replica saw the event. |
| **Alert** | The folded state of an identity: status, severity, when it started, how often it fired, who acknowledged it. |
| **Policy** | Which alerts go to which channels, with delay steps, a repeat interval and whether to send the resolve. |

## Rules

A rule has a name, a kind, a severity (`critical`, `major`, `minor`, `warning`, `info`), an `enabled` flag, a
kind-specific `spec`, and optional `title` and `summary` templates. Templates and the key use `{label}` for a label of
the event or sample, `{a|b|c}` for the first of those that is set, and `{{` `}}` for literal braces. The labels are
`device_id`, `device`, `interface`, `if_index`, `site`, `tenant`, `role`, `vendor`, `model`, `source_ip`, `dataset`,
`action`, `event_severity`, `message`, `check`, `state`, `path`, `metric`, `value` (the reading, for a metric rule's title and summary), `rule`, and for a metric sample each
of its own labels. `GET /api/alerts/meta` lists them.

### Event rules

`match` is a route expression (the grammar of [routes](outputs.md); the same fields, evaluated without allocation) on any
dataset: traps, syslog, `seshat.reachability`, tracker events. `dataset` limits the rule to one dataset before the
expression runs, which is cheaper and recommended. `clear` is an optional second expression that resolves the alert
(link-down cleared by link-up, device-down by device-up); `key` sets the identity. Without `clear` the alert resolves
`auto_resolve_s` seconds after the last matching event (default one hour).

```json
{"name": "Interface down", "kind": "event", "severity": "major",
 "spec": {"match": "event.action == \"interface-down\"", "clear": "event.action == \"interface-up\"",
          "key": "{device_id|device|source_ip}/{interface|if_index}"},
 "title": "Interface down: {device} {interface}"}
```

### Metric paths

A metric rule names the path of the leaf, with no list keys and no leading slash (`interfaces/interface/state/oper-status`). Either
spelling is accepted when the rule is saved (`/interfaces/interface[name=Ethernet1/1]/state/oper-status` is stored as the first), and a
sample matches whatever its collector's spelling is: gNMI and the tracker send a leading slash and the list keys, and the keys do not
take part in the match. The keys of the sample's path become labels, so templates and keys can use them: `{interface}` for
`interface[name=...]`, `{component}` for `component[name=...]`, `{cpu}` for `cpu[index=...]`; a list with a second key adds
`{list_key}`. A sample's own labels win over the path's. The `path` label (and a `select` on it) is the same key-free form. Each distinct
set of keys is its own series, so one interface going down does not touch another's alert. Enumerations that telemetry sends by name
(`UP`, `DOWN`, ...) are read as their numbers (see [metrics-store.md](metrics-store.md)): a state rule's `fire_values` and `clear_values`
are the numbers.

**Identity and sources.** The identity of a metric alert is the rule and its key (for example the device and the interface); the
source of the sample (SNMP poll, gNMI, sFlow) is not part of it, and a rule cannot select on it (`select` matches the sample's
labels, and the source is not one). When two sources report one interface and disagree (SNMP says up while gNMI says down), their
samples are judged as one series and drive the same alert, which fires and clears with whichever reported last, so it can flip back
and forth. Where two sources cover the same device, let only one of them cover the interfaces a rule watches (a gNMI subscription
or a poll collector, not both).

### Threshold rules

On `seshat.metric` samples of a `path`, optionally narrowed by `select` matchers on the sample's labels. The
sample is compared with `value` using `op` (`>`, `>=`, `<`, `<=`, `==`, `!=`); the condition must hold for `for_s`
seconds (judged from the samples' own times, so a rule with `for_s: 300` on a 60 s poll needs six samples). With
`rate: true` the value compared is the per-second rate between two samples, for counters; a counter reset produces no
rate for that sample. Gauges and counters both work.

### State-change rules

For a metric of kind `state` (the enum number of the MIB, so SNMP-polled `oper-status` gives interface up/down without
traps). Three forms:

- `fire_values` (and optionally `clear_values`): the alert fires when the value becomes one of them, clears on one of the
  `clear_values`. A series first seen already in a firing value is **not** a change and does not fire unless
  `fire_initial` is set (unused ports that are down at start-up do not alert).
- `clear_values` only: it fires on any value outside them (level-triggered); use `fire_initial: true` for health states.
- neither: any change fires and the alert resolves by itself after `auto_resolve_s` (default one hour). The summary says
  what changed from and to.

Values are compared as text, so `2` and `"2"` are the same.

### Absence rules

No sample of a series for `absent_s` seconds (at least 60, twice the 30 s the replicas take to write their last-seen table). The time is the time this installation received the sample, not the device's. A leader that has just started or taken over waits as long as the rule's time before judging, so a restart or a fail-over does not page for every healthy series. The replicas record when they last saw each series in a
small table, written in coalesced batches; the leader judges the table, so the answer is right when a series moves
between replicas. The alert clears when the series reports again. Closing an absence alert by hand forgets the series
until it reports again. Use `key: "{device_id}"` to alert per device rather than per series.

### Trying a rule

`POST /api/alerts/rules/dry-run` with `{"rule": {...}, "events": 5000}` runs a rule, saved or not, over the most recent
events the event inspector keeps and returns what it would have done: the signals in order, how many identities would be
open at the end. Nothing is written or sent. Absence rules cannot be tried. The inspector must be enabled
(`SESHAT_INSPECT_RING`); it keeps at most 500 events per request here.

## Alert lifecycle

`firing` → `acknowledged` (with a note; the alert keeps firing but stops escalating and repeating) → `resolved`.
An alert is deduplicated by fingerprint: a rule firing again for an open identity raises `occurrences` and `last_seen_at`
(a replica coalesces identical repeats within five seconds and admits a rule events at a limited rate, so the count is a lower bound under a storm; a refresh of a standing condition is not an occurrence). History is
kept for 90 days by default (`retention_days` in the settings) and every alert keeps its own timeline: fired, flapping,
suppressed, unsuppressed, ack, unack, resolved or closed. An alert resolves by `clear` (a clear signal), `auto` (timed
out), `user` (closed by hand), `stale` (a threshold or state alert nothing re-asserted for `stale_s`, 1 hour), `flap_settled`, `rule_deleted`, `rule_changed` (the key, clear expression or metric path changed) or `rule_disabled`. Changing or disabling a rule resolves its open alerts with that reason and sends the resolved notice. Closing an alert whose condition still holds: an event alert opens again on the next event; a threshold or state alert opens again
on the next refresh after the hold-off (`close_holdoff_s`, 30 minutes).

## Bounds

Alerts come from the network, so everything that can multiply is bounded. A syslog hostname is never an identity (the known
device id, else the sender address). A rule has at most `max_open_per_rule` (5000) open alerts. A further identity is not forgotten: it waits in the register, flagged
*refused* (at most 50,000 per rule; beyond that they are only counted), and opens as room appears; a clear removes a waiting identity.
One **overflow alert** per rule shows the live number waiting and resolves only when none is left. Labels (40), label values (256), title (256) and summary
(1024) are clipped and stripped of NUL and control characters. A rule admits events at 2000 a second sustained with a burst of 20000
(`rule_rate`, `rule_burst`; a token bucket each for the events that raise and the events that clear), so a whole site going down and
coming back inside a second is kept, and one noisy rule is throttled and cannot push out another rule's link-down. What a rule
refuses is counted per rule (`dropped_events` in the rule's status, `seshat_alert_rule_events_dropped_total{rule}`), and a rule that
dropped events raises one **health alert** for itself ("events were dropped"), because its alert state may then be incomplete. A rule
that is over its limit makes no signal even when another rule admits the same event. Each of the two signal queues (events, metrics) keeps 10 percent for
clears, and one rule's clears may take at most half of it: firings fill 90 percent, and a clear that finds the queue full displaces the oldest *refresh* signal, never another identity's
firing. There are at most 1000 rules, expressions are at most 2000 characters, and a
matcher list at most 20 entries.

## Noise control

Noise control acts on **notifications**. A silenced, in-maintenance, dependent or flapping alert still exists, is listed
and keeps its history; `suppressed` says why (`silence:<id>`, `maintenance:<id>`, `dependency:<device>`). When the hold
ends and the alert still fires, it is notified then, once (the latest due step, not a backlog).

- **Silences**: matchers plus a time range. Matchers compare a label of the alert with `=`, `!=`, `=~`, `!~` (anchored
  RE2). The alert's labels include `rule`, `severity`, `status`, `device_id`, `device`, `interface`, `site`, `tenant`,
  `role` and every label of the event.
- **Maintenance windows**: once, daily or weekly (with days, a start time and a duration, in a time zone; a window may
  cross midnight), for devices by id or name, sites, roles or tenants. A device is in scope when it is in every list that
  is not empty.
- **Dependencies**: a rule marked `down` (the starter "Device down") explains the device: while its alert fires, the
  device's other alerts are suppressed, and so are the alerts of the devices behind it. "Behind" comes from the uplink
  neighbours (LLDP/CDP) the Device Tracker's poller sees: a neighbour is a parent when its role is closer to the core
  (core, router, firewall, then distribution, then access, then access point). A neighbour of an unknown role is never
  taken as a parent: a wrong dependency would hide a real alert, a missing one only leaves noise.
- **Flap detection**: `flap_count` transitions (default 6) within `flap_window_s` (default 10 minutes; per rule or in the
  settings) turn the alert into one flapping alert. The clears are held until the identity has been quiet for the window,
  then it resolves (`flap_settled`) or, if it settled firing, stops being flapping. Only changes of state count: six firings with no clear in between are not flapping.
- **Waiting for an explanation**: the first notification of a device's *child* alert (an interface, or a health reading from a metric; not the alert that says the device is down, nor any other alert of the device itself) waits
  30 seconds (`dependency_wait_s` of the policy; 0 turns it off), so a device-down that arrives just after the interface alerts
  suppresses them instead of being paged beside them.

## Notifications

Delivery is the job of the notification channels ([channels](alerting-channels.md)); the engine hands over a
`Notification` per due step with a deterministic idempotency key (`alert-<id>-p<policy>-s<step>-r<repeat>-<status>`), so a replay after a
leader change is queued once by the outbox. A policy step may only name channels that exist. A **policy** selects alerts by severity and matchers
and has `steps`: each step names channels and a `delay_s` after the alert started (step 0 normally 0; the next ones are the
escalation). A step is due (after that wait) only while the alert is firing, not suppressed and not acknowledged. The last step repeats
every `repeat_s` (0: never). `send_resolved` tells the channels that were told about the alert when it ends; `send_ack`
tells them it was acknowledged. Policies run by `priority` (lower first); `stop` ends the walk. Statuses handed over:
`firing`, `escalated`, `acknowledged`, `resolved`.

## Starter rules

Shipped disabled. Each starter has a stable key and Seshat remembers the keys a deployment has seen: on start, a starter the deployment has never seen is added (disabled), including one introduced by a later release. A starter you edited is left alone, and one you deleted is not re-created:

| Rule | Kind | Condition |
|---|---|---|
| Interface down | event | `interface-down` (trap or pack-mapped syslog), cleared by `interface-up`, per device and interface |
| Interface down (polled or telemetry) | state | `interfaces/interface/state/oper-status` becomes down (2) or lowerLayerDown (7), cleared by up (1), per device and interface |
| Device down | event | `seshat.reachability` `device-down`, cleared by `device-up`; marked `down` |
| Device rebooted | event | `device-restarted`, resolves after 15 minutes |
| CPU high | threshold | `system/cpus/cpu/state/total/instant` > 90 for 5 minutes |
| Memory high | threshold | `system/memory/state/utilization` > 90 for 5 minutes |
| Temperature high | threshold | `components/component/state/temperature/instant` > 75 for 2 minutes |
| PSU failed | state | `components/component/power-supply/state/status` not 1 (normal on the shipped packs) |
| Fan failed | state | `components/component/fan/state/status` not 1 |
| Optics receive power low | threshold | `components/component/state/optical-power/instant` < -20 for 2 minutes |
| Interface input errors | threshold (rate) | `.../counters/in-errors` above 1 per second for 5 minutes |
| Interface output errors | threshold (rate) | `.../counters/out-errors` above 1 per second for 5 minutes |
| Syslog critical or worse | event | syslog severity 2 or lower, resolves after 15 minutes |

**Interface down: trap or polled.** The two interface starters watch different things and are different rules, so each keeps its
own alerts (an identity includes the rule); with both enabled one outage raises two alerts. Enable one:

- *Interface down* reads events: a linkDown trap, or a syslog message the pack maps to `interface-down`. It never fires from polled or
  streamed status, because the SNMP poll and telemetry produce only `seshat.metric` samples, not events. Use it for devices that only send traps or syslog.
- *Interface down (polled or telemetry)* reads the `oper-status` samples of the Device Tracker's SNMP poll or of gNMI telemetry, so it
  works without traps and notices a port that went down while a trap was lost. It uses the same device-and-interface key and the same severity.
  It is a state rule, which fires on a *change*: a port that is already down on the first sample of its series (a start-up, a restart, a
  device newly polled) does not fire, and an alert already open for it is kept. That is deliberate: `fire_initial` would raise an alert for every
  unused or shut-down port the moment the rule is enabled. To alert on those as well, copy the rule and set `fire_initial: true`, accepting
  the noise (or narrow it with a `select` on the interface). Only 2 and 7 fire it; testing, dormant, not-present and unknown ports do not.

The metric rules need the metrics of the Device Tracker's SNMP collectors or streaming telemetry; the paths are the ones
the shipped packs emit. Status enums are vendor-specific: check your pack before relying on the state rules.

## Outputs

- **`seshat.alert` events** ([schema](schema/fields.md), dataset `seshat.alert`, example `schema/examples/alert.json`) go
  through the normal routes for every history entry that matters (fired, resolved, closed, ack, unack, flapping), so any
  destination can receive them.
- **Subscription kinds** `alert.firing` and `alert.resolved` ([events contract](schema/events.md)) for integration
  clients with `events.subscribe`.
- **Prometheus** metrics `seshat_alert_*`: events and samples offered and dropped per queue, queue depths, series tracked and
  refused, signals written, dropped and failed per queue, signals folded, alerts fired and resolved, notifications handed
  over, open alerts by severity and suppression, fold lag, whether this replica leads.
- **Capabilities** `alerts.read` and `alerts.ack` ([integrations](integrations/README.md)).

## High availability

**Ordering.** The time of a signal is the *receipt* time on the replica that received the event, always; the device's own timestamp
is kept only for display (it is what `starts_at` shows). For each identity (rule and fingerprint) the state is a
last-write-wins register ordered by (time, signal id): the leader keeps the last state it applied in one row per identity
(`alert_state`, kept for `clear_grace_s` after the last change and pruned in small batches), and a firing or a clear older than it is
ignored, in both directions. At equal times the higher signal id, the one folded later, wins. So a clear that overtakes its firing
on the way to the log, or an older clear folded after a newer firing, cannot close or strand an alert. Replica clocks are only so close, so the register also
remembers which replica made the state it holds: a signal from *another* replica that is older by no more than the skew tolerance
(`clock_skew_s`, 10 seconds) is not taken for older, and the later-folded one wins; signals of one replica stay strictly ordered.
A register is pruned by the age of its state, never while its identity has an open alert, and never while the identity is waiting
for room (below). A firing older than the register remembers, with no row, still opens (it may be a real outage) but is marked `late`
and resolves after `late_s` (1 hour) unless something recent says it continues. A manual close is an operator's act and writes
nothing into the register: a firing made before the close (beyond the skew tolerance) does not reopen the alert, and a refresh of a
standing condition waits out the hold-off. Every timer (escalation steps, the dependency wait, auto-resolve, stale) runs
from when the installation first *received* the alert (`received_at`), not from the device's clock.

**Concurrent edits.** A rule has a `version` that grows with every update. The editor sends back the version it opened; an update that finds another one is refused with 409 `stale`, decided in the UPDATE itself, so two edits in the same millisecond cannot both succeed. A script that sends no version is not checked.

**Identity revisions.** A rule carries an identity revision that grows when its key, clear expression, metric path or `down` flag
change; signals carry the revision they were made under, and the fold discards signals of an older revision and signals of a
disabled rule. A rule edit that changes identities resolves the open alerts in the same transaction as the edit, so what is still in
flight from before cannot re-create them. The alerts of a rule that no longer exists are resolved by the sweep (`rule_deleted`).
The fold reads each rule's revision and enabled flag from the database inside its own transaction, after the writers' lock, so
an edit or a disable by another replica takes effect at once even while the leader's copy of the configuration is stale; the signals it
discards for an older revision are counted per rule (`stale_revision_signals`). Replicas notice rule changes through a monotonic
configuration version, bumped in every transaction that writes the rules, not through update times (a replica whose clock is behind
could hide an edit). A signal for a rule the leader has not loaded is judged again after one reload from the database; a signal cannot
be appended before its rule exists, so a rule still missing then is gone and the signal is discarded at once. The alerts of a rule that
is disabled or gone are resolved by the sweep.

While a threshold or state condition holds, the replica holding the series re-asserts it about every 5 minutes (spread per series by up
to 20 percent), a *refresh* signal, which opens the alert if the first signal was lost and keeps it alive without counting an
occurrence. A series rebuilt in a state it was already in (an edit, a restart, a fail-over) sends a *keep-alive* instead: it keeps an
open alert alive and never opens one (unless `fire_initial` is set). An alert nothing re-asserts for the stale limit resolves as
`stale`; the limit is `stale_s` (1 hour) or three times the series' own sample spacing when that is longer, at most 72 hours, so a
device polled once a day is not stale between polls. Refreshes are not state changes: they never wake the pass over the open
alerts, and the fold deletes them once applied. An event rule with a `clear` expression may also give `auto_resolve_s` as the
longest it stays open without one (default: no limit, because a link that stays down sends no second event). Alert rows are locked while they are read for
change (PostgreSQL `FOR UPDATE`), and the writers of many rows (the fold, a rule change that resolves alerts, a rule delete) take one
advisory lock, so an acknowledgement and a fold cannot overwrite each other and the writers cannot deadlock. The fold takes 100
signals per transaction; counters move only after a commit.

Same model as [integration event subscriptions](integrations/README.md#events): every replica evaluates what it receives
and appends signals; only the leader folds them into alert state and hands notifications over, from a stored position.
A leader change mid-alert sends no duplicate and loses no resolve; a `for` timer restarts at worst.

## Hot path and limits

The engine is a non-blocking tap. It does an atomic load, a map lookup (metric path) or a few compiled expression matches
(event rules, grouped by dataset) and a non-blocking send to a bounded queue; no allocation and no I/O. Alert-matching
events and metric samples have **separate queues, workers and signal writers**, so a telemetry flood fills its own queue and
drops there (`seshat_alert_metric_dropped_total`) and cannot delay a link-down. The metric worker keeps a bounded set of
series (100,000); beyond it a new series is counted (`seshat_alert_series_refused_total`) and refused, never queued. Metric
paths match exactly once the list keys and the leading slash are dropped (done on the stack, no allocation). With the starter rules enabled the tap costs about 100 ns per event that no rule wants.

## API

All under `/api`; JSON; errors are `{"error": {"code", "message", "fields"}}`. Administrators and operators change, viewers
read, the plain `user` role gets 403. A token holding `alerts.read` reads and one holding `alerts.ack` also acknowledges,
within its scope. Rules, silences, maintenance windows, policies and settings are global: only sessions and tokens of an administrator, operator or viewer that are not limited to some sites read them, and only administrators and operators change them; an `alerts.read` client or a site-limited caller gets alerts only (and the alert detail without the configuration around it). Every change is audited
(`alert.rule.create`, `alert.ack`, ...). The full description is in `GET /api/openapi.json`.

| Route | |
|---|---|
| `GET /alerts` | filters: `status`, `severity`, `rule_id`, `device`, `site`, `tenant`, `q`, `active`, `suppressed`, `since`, `until`, `limit`, `offset` |
| `GET /alerts/{id}` | the alert, its history, deliveries, rule, and the policies, silences and maintenance windows that touch it |
| `POST /alerts/{id}/ack`, `/unack`, `/close` | body `{"note": "..."}` |
| `POST /alerts/bulk-ack` | acknowledge up to 200 alerts with one note (`ids`, `note`); one result per alert |
| `GET /alerts/summary`, `/alerts/meta` | counts by severity and status; the vocabulary for building forms |
| `GET/POST /alerts/rules`, `GET/PUT/DELETE /alerts/rules/{id}` | rules (with open and total alert counts) |
| `POST /alerts/rules/dry-run` | try a rule against recent events |
| `POST /alerts/preview` | which open alerts a silence or maintenance window being drafted would hold back |
| `GET/POST /alerts/silences`, `GET/PUT/DELETE /alerts/silences/{id}` | silences (`?all=true` includes ended ones) |
| `GET/POST /alerts/maintenance`, `GET/PUT/DELETE /alerts/maintenance/{id}` | windows, with `active` and `next_start` |
| `GET/POST /alerts/policies`, `GET/PUT/DELETE /alerts/policies/{id}` | notification policies |
| `GET/PUT /alerts/settings` | `flap_count`, `flap_window_s`, `retention_days`, `max_open_per_rule`, `close_holdoff_s`, `stale_s`, `clear_grace_s`, `clock_skew_s`, `late_s` |
