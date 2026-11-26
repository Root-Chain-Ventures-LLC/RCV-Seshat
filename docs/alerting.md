# Alerting

Seshat has a built-in alert engine, so an operator can run it without a separate NMS. It turns events and metric
samples into alerts, keeps their lifecycle, holds back the noise, and hands notifications to the channels you
configure ([notification channels](#notifications) are a separate component). It is **off until you enable a rule**:
the starter rules ship disabled. Routing events to a downstream alerting system keeps working exactly as before; the
engine is additional.

Everything here is read-only toward devices. Nothing in the engine writes to a device.

## Contents

- [Concepts](#concepts)
- [Rules](#rules): event, threshold, state change, absence, correlation (incidents)
- [Port classes](#port-classes): which ports are access ports
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
| **Rule** | A condition. Five kinds: event, threshold, state change, absence, correlation. |
| **Identity** (key, fingerprint) | What an alert is *about*: the rule plus a key such as the device and the interface. One identity has at most one open alert. |
| **Signal** | A compact record `firing` or `clear` for a rule and identity, appended by whichever replica saw the event. |
| **Alert** | The folded state of an identity: status, severity, when it started, how often it fired, who acknowledged it. |
| **Policy** | Which alerts go to which channels, with delay steps, a repeat interval and whether to send the resolve. |
| **Incident** | The alert of a correlation rule: one alert for a group of members (the access ports of one switch, the switches of one site) that went down together, kept up to date until it is over. |
| **Member** | One thing a correlation rule counts: an interface that is down. A member that comes back leaves the incident. |

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

### Correlation rules

A correlation rule turns many members that go down together into **one incident**: instead of one alert per access port, one alert that says
"7 access ports down on Example Switch 3 (example-site)", lists them, and stays up to date until the ports are back. The incident is an
ordinary alert of the rule (acknowledge it, close it, silence it, route it by policy), so everything in [noise control](#noise-control) and
[notifications](#notifications) applies to it.

```json
{"name": "Access ports down together", "kind": "correlation", "severity": "major",
 "spec": {
   "source": {"match": "event.action == \"interface-down\"", "clear": "event.action == \"interface-up\""},
   "member": "{interface|if_index}",
   "group_by": ["{device_id|source_ip}", "{site}"],
   "port_class": ["access"], "device_role": ["access-switch", "distribution"],
   "min_members": 5, "window_s": 120, "clear_below": 2, "auto_resolve_s": 86400, "min_children": 2, "site_grace_s": 30,
   "parent_title": "{count} access ports down across {device_count} switches at {site}"},
 "title": "{count} access ports down on {device} ({site})", "summary": "{members}"}
```

- **Members.** `source` says what a member is. Either `match` (with an optional `clear` and `dataset`, the grammar of an
  [event rule](#event-rules)) names the events that take a member down and bring it back, or `rule` names another rule whose firings are
  the members (`{"rule": "Interface down"}`). `member` is the template of a member's name (default `{interface|if_index}`); a member is
  the device plus that name, so `ethernet1/1/1` of two switches are two members. Events without a device identity (no device id and no
  source address) or without a name are not members.
- **Which members count.** `port_class` keeps the members whose interface has one of the listed [port classes](#port-classes) (empty: all);
  an interface the inventory does not know, or of a device whose interface table was never read, is `unknown` and counts only if `unknown`
  is listed. `device_role` keeps the members of devices with one of the listed roles (without regard to case). Members the filters leave out
  are counted (`seshat_alert_members_filtered_total`) and never reach the incident.
- **Groups.** `group_by` lists one or two templates, finest first: the first is the group an incident is made for (a switch:
  `{device_id|source_ip}`), the second the group that contains it (its site: `{site}`). An incident whose group template names the site and
  no device is a **site** incident, any other a **switch** incident (`incident_kind`).
- **Opens** when `min_members` members of a group (default 5), all still down, went down within `window_s` seconds (default 120) of one another:
  the window is how close together they went down, not how long an incident may last. It is judged by the times the members' signals carry (the
  receipt times), never by the clock of the node that folds them, so a late fold (a leader change, a stalled database, a backlog) or a replica with a clock
  that is off still makes the incident its members made. Members that went down far apart, even if all are still down, are no burst.
  **Grows** as more members join, whenever they do: no new incident and no new notification (the first notification already waits, see
  below). **Resolves** when fewer than `clear_below` members are down (default 2), or when nothing has
  changed for `auto_resolve_s` (default one day: a member whose clear was lost does not keep an incident open for ever). A member that
  flaps counts once, however often it goes down and up; `flapping_members` says how many did it three times or more. A new burst after a
  resolve opens a new incident. An incident an operator closed by hand whose members are still down opens again once the hold-off (`close_holdoff_s`)
  has passed, on the next pass of the leader.
- **Site incidents.** With two `group_by` entries a site incident opens when at least `min_children` (default 2) switch incidents of the
  site are open, and resolves when fewer are. It **contains** them: the switch incidents stay open and listed but are marked
  `suppressed: correlation:<site incident id>`, so only the site incident is notified (a site's one failing switch stays a switch
  incident). A site incident carries no tenant, because the devices of a site may belong to several. `parent_title` and `parent_summary`
  are its text (default "{count} members down across {device_count} devices at {site}"). The first notification of a switch incident whose rule has a site
  level waits `site_grace_s` (default 30 seconds) longer than the dependency wait, so a site incident that is about to open covers it; a switch whose
  neighbours go down later than that is still announced first, and the site incident follows. Both are notified then.
- **The members' own alerts.** If the per-port rule (the "Interface down" starter, or the rule named as the source) is on too, its alerts
  are marked `suppressed: correlation:<incident id>` while an incident covers them, as with `dependency:<device>`. For a rule that
  names its events they are the alerts of the event rules with the same `match` and `clear`. The first notification of a per-port alert
  that a correlation rule counts waits the rule's `window_s` (at least the policy's `dependency_wait_s`), so ports that go down 20 seconds apart are
  not paged (only alerts the rule would count: an uplink port is paged at the normal wait) before the incident has opened; a port that goes down alone is paged after that wait. When the incident ends, the members still down are
  released and each is notified then, once; the resolve notice of the incident lists them (`still_down`), so they are not news.
- **Dependencies win.** A device that is down (a rule marked `down`, or an ancestor in the LLDP/CDP topology) explains its members: no
  incident opens for it (`seshat_alert_incidents_explained_total`), and one that opened before the device-down alert arrived is resolved
  as `explained_by` on the next pass. The first notification of an incident waits `dependency_wait_s` of the policy (30 seconds by
  default), like any alert of a device's interface, so the device-down that arrives just after pages alone and so that members still
  joining are in the notification: it is sent once and lists all of them.
- **Silences and maintenance** match the incident's labels (device, site, role, tenant, `incident_kind`, and every label below) like any
  alert's.
- **Labels for policies and channels.** The incident carries the labels of its group (`device_id`, `device`, `site`, `tenant`, `role`,
  `vendor`, `model`, `source_ip`; a site incident only `site`) and: `incident_kind` (`switch` or `site`), `count` (members down now),
  `members` (their names, sorted naturally, cut to 240 characters with "+N more"; a site incident lists its devices with their counts),
  `devices` and `device_count`, `down_for`, `recovered` (members that came back since it opened), `peak`, `flapping_members` and
  `members_dropped`. Titles, summaries, policy matchers and channel templates (`.Labels.count`) can use them; `GET /api/alerts/meta`
  lists them as `incident_labels`. Title and summary are rewritten as members join and leave; the notification carries what they said when it
  was sent, and the resolve notice what they said last.
- **Bounds.** A group keeps at most 2000 members: further ones are counted (`members_dropped` on the incident,
  `seshat_alert_members_dropped_total`). A rule opens at most `max_open_per_rule` incidents (5000): one it has no room for is counted
  (`seshat_alert_incidents_refused_total`) and raises the rule's health alert ("events were dropped"), and opens when room appears.
  Member signals are queued and written like alert signals, with the same per-rule rate and burst. **Retention:** a member signal is kept for a day after it
  was folded; a member that came back is kept a day, and a member nothing has said anything about for 30 days is removed; incidents are alerts and follow
  `retention_days`. A member that nothing has said anything about for `auto_resolve_s` is not counted as down any more (not so for a member of a rule that takes its members from another rule's firings: it counts for as long as that alert is open, and is not removed while it is).
  A close by hand leaves a marker so the incident opens again after the hold-off while its members are still down; it is dropped when fewer than `min_members` are down.
- **Status.** `GET /api/alerts/rules` adds `correlation` to a correlation rule: `members_filtered` and `members_unknown` (members the port class or role
  filter left out on this replica in the last 15 minutes, and of them the ones whose class is unknown, which is why a fresh install's starter opens nothing until the interface
  tables have been read), and notes in words: the rule named as the source is gone (deleted or renamed), correlation is paused (below), a pass read only part
  of a very large incident.
- **History.** An incident has its timeline: fired, "occurrence" (it grew: the first growth, a doubling, or five more), suppressed, ack,
  resolved. `GET /api/alerts/{id}` adds `incident` with the members (live and recovered, when they went down and came back, how often
  they flapped) and, for a site incident, the switch incidents inside it.

The **starter rule** "Access ports down together" (disabled) is the example above for one switch at a time: five or more access ports of one
switch within two minutes, resolving below two. It needs the events of the "Interface down" rule (traps or pack-mapped syslog) and the
[port classes](#port-classes), which need the device's interface table (SNMP polling or the inventory).

**Trying it and replaying history.** `POST /api/alerts/rules/dry-run` with a correlation rule runs it over the recent events (as for an
event rule, the events' own times decide what is "within the window") and returns `incidents`: what would have opened, with its peak,
members and when it would have resolved. `POST /api/alerts/rules/replay` (`{"rule": {...}, "days": 7}`) answers "over the last N days this
rule would have opened K incidents". Seshat keeps no events, so the replay reads the **stored alerts of the members**: the rule named as
the source, or the event rules with the same `match` and `clear`; each alert is a member that was down from when it fired to when it
resolved. Without such a rule the answer says there is nothing to replay (turn the per-port rule on for a while, or name one as the source),
instead of answering zero. The window is at most the retention of resolved alerts (90 days), an alert that opened before it and is still open is a member that went down then (it can not
satisfy the window with newer ones), the replay reads at most 100000 alerts and
stops after 8 seconds (`truncated`), and the port classes and role filters are the ones in force now. Nothing is written or sent.

**High availability and rolling upgrade.** Every replica appends member signals to their own log (`alert_member_signals`, migration 0327)
for the events it receives, like alert signals; only the leader folds them into the member table and decides the incidents, in the same
transaction that moves its position, so any replica's events count and a leader change loses nothing and repeats nothing (the notification
keys are those of any alert). A rule that takes its members from another rule's firings is fed from that rule's signals as the leader folds
them, and from its open alerts when the correlation rule is created or its identity changes. Changing what the members are (`source`,
`member`, `group_by`, `port_class`, `device_role`) resolves the rule's open incidents (`rule_changed`) and forgets its members; other
changes (`min_members`, `window_s`, `clear_below`, texts) apply to the next decision. **Correlation rules take effect when every node runs this release.** Each
node advertises `alert_correlation` in its cluster heartbeat; while a live node of a shared database lacks it, its leader would clear the suppression of
the members' alerts, so correlation pauses: incidents are held back (`suppressed: correlation:paused`) and each port notifies as before, and the rule's status
says so. When every node has it, the suppression applies. **During a rolling upgrade from 0.11.x** the previous
release does not know the kind: a node of it skips an enabled correlation rule (`seshat_alert_rules_invalid`), it never reads the member
log, so a member can never become an alert of its own there, and while such a node holds the leader lease no correlation rule opens, grows or
resolves an incident (incidents already open stay open and are notified as ordinary alerts, and catch up when an upgraded node leads).
A rule disabled, or a starter left disabled, costs the old nodes nothing.

#### Baselines: learning what is normal

"5 ports in 2 minutes" means something on a switch that sees one link-down a day and little on one that sees forty an hour. Give `min_members` as an
object and the threshold of each switch follows what is usual for it:

```json
"min_members": {"baseline_factor": 5, "floor": 5}
```

A plain number (`"min_members": 5`) keeps working and means exactly what it did: no baseline is consulted. With the object, the members a switch needs in
`window_s` are `max(floor, ceil(baseline_factor x R x window_s / 3600))`, where `R` is the switch's usual number of members going down in the current
hour of the week (see below). Example: a switch that usually has 40 members down an hour on weekday mornings, a window of 10 minutes and a factor of 5 needs
34; the same switch at night, when it usually has none, needs the floor. The threshold applies to the first level (the switch); a site incident still needs
`min_children` switches with an incident. `clear_below` is unchanged.

- **What is counted.** Per rule and group (each switch, each site), the number of **distinct members that went down** in each clock hour (UTC): a member
  that goes down, comes back and goes down again in the same hour counts once, in two hours twice. The leader counts as it folds member signals, at the
  signals' receipt time, so the number is what the rule itself judges (port class and device role filters apply) and is the same for a rule fed by events
  and one fed by another rule's firings. Members are counted whether or not the rule uses a baseline, so turning one on does not start from nothing.
- **How it is kept.** Every few minutes the leader folds completed hours (10 minutes after they end) into one row per group in `alert_baselines`: a rate for
  each of the 168 hours of the week (Sunday 00:00 UTC is 0) and how many weeks each has seen. A bucket's first three observations are a plain average;
  after that it is an exponentially weighted average with weight 1/4 for the newest week, so it follows the last four weeks or so and forgets older ones.
  An hour with no member down is an observation of zero. An hour counts for at most `max(4 x the bucket's rate, 10)` once the bucket has two
  observations, and before that at most `max(4 x the mean of the group's other busy buckets, 10)`, so one outage does not teach Seshat that outages are normal. The most members that went down in one hour (unclipped) is kept too:
  the threshold is never more than that or the members the group holds now, because a higher one could never be met (the view shows `max_members` and `capped`). Hours are UTC. The rate used for an hour is the highest of that hour and the two next to it, which softens a boundary and a daylight-saving change.
- **When it is used.** A group has a baseline once it has been followed for a week. Before that (a new device, a new rule, a group that never had a member
  down, or after a gap of more than 28 days in which no leader ran: the rates are kept, but the group is followed from the end of the gap) the **floor** is the threshold, and the rule's status says so (`correlation.baseline`, and a
  note in the rules list). The rate is read for the time of the signals (the latest member down), not the time of the fold. A disabled rule's rows are not advanced. Hours are folded after `late_s` (at least 10 minutes) so late signals count; one later than that is not counted. Alerts that are already open when a rule is created are not counted as an hour of normal.
- **Bounds.** At most 5000 groups per rule and level keep a baseline (a newer group makes room by dropping the one quiet longest; each drop is counted); a row is two arrays of 168 numbers
  (about 1.5 KB); a group with no member down for 56 days loses its row (its baseline would be about zero); raw hourly counts are deleted as they are folded.
  Editing what the members are (`source`, `member`, `group_by`, `port_class`, `device_role`) or deleting the rule forgets its baselines; changing the factor,
  floor or window does not.
- **See it.** `GET /api/alerts/baselines?rule=ID` (or `device=NAME`, `devices=A,B`, `site=NAME`, `level=0|1`, `limit`, `buckets=1`) returns, per group, the
  usual rate for the current hour of the week (`expected_per_hour`), the members that went down so far this hour, the threshold the rule applies now
  (`threshold`, with `floor: true` when no baseline is used yet and a `note` saying why), and with `buckets=1` the 168 rates and the weeks each has seen.
  The rule's status carries a summary and the busiest groups; the rule editor shows the table; the Storm tab adds a column (link-downs this hour / usual) for
  senders that are a known device; a device's health page lists its baselines. Reading needs a caller not limited to some sites or tenants.
- **Suggestions from history.** `POST /api/alerts/rules/suggest` (`{"rule": {...}, "days": 30}`; optional `thresholds` and `factors`) replays the rule's stored
  history ([as the replay does](#trying-a-rule), same signal-time windows) once for each candidate: `min_members` 3 to 20 and baseline factors 2 to 10 (with the
  rule's floor), and answers for each how many incidents it would have opened, per day, on how many switches, and the biggest. The rule editor has the table
  with a button that applies a row. A baseline candidate builds its baselines from the replayed history itself, as the leader would have, so the first week of the
  window uses the floor and a window shorter than eight days cannot show a baseline's effect (the answer says so); a baseline candidate's `per_day` counts from the day its first baseline was usable (`measured_from`). Two runs at a time; the baseline candidates run first with at most 60 % of the time. At most 40 candidates of each kind, 100000 alerts and 25 seconds.
- **High availability and rolling upgrade.** Only the leader counts and folds (compare-and-set on the row's position, so a leader change repeats nothing); replicas
  read the rows. The migration (0331) is expand-only. The stored spec keeps the floor as the plain `min_members` number and the factor as `baseline_factor` beside it
  (the API shows the object), so a node of the previous release that reads the rule sees an ordinary threshold at the floor; it ignores the two new tables. Correlation
  itself is still governed by the `alert_correlation` gate: while a node without it is in the cluster the rule is paused as before, whatever its `min_members`.

### What is probably going on: cause, impact, severity

Every incident of a correlation rule carries a **cause**, a **confidence** (`low`, `medium`, `high`) and the **evidence** behind them, computed when it
opens and looked at again whenever a member changes, evidence arrives (within a second) or half a minute has passed. The inference is deterministic
(no model): the same facts give the same cause, and each conclusion lists the facts it rests on, each with its time and a one-line reason, as `supports`,
`context` or `against` (looked at, not counted). It is evaluated in this order and the first row that fits wins (the one departure from the order of the
design table: a maintenance window is checked before the shape-based rows, because it is the operator's own statement and must be reachable):

| Cause | When | Incident |
|---|---|---|
| (device down) | the switch is unreachable | no incident: the device-down alert explains it (as in phase 1) |
| `planned` | a maintenance window covering the switch or site was in force when the first member went down | recorded and held back by the window; when the window ends with members still down it is judged like any incident, the text says "still down after the maintenance window ... ended", and the alert is notified then |
| `uplink` | an uplink-class port of the switch went down up to `uplink_lookback_s` (120) before, or within 5 s plus the clock skew after, the first member, and no uplink capacity is left: every physical uplink the port classes know is down (the aggregate need not say anything; interface names are compared across spellings such as `Te 1/49` and `TenGigabitEthernet 1/49`), or an aggregate (port-channel, LAG) says it is. An uplink that went down earlier and has not come back counts as down. One member of a LAG going down is not counted (shown as `against`), and with no known uplink table (the device's interface table was never read) nothing is inferred | `incident_kind: uplink`; title "Uplink down on X: N access ports behind it" unless the rule sets its own `title` |
| `site` | a site incident (second `group_by` level) | confidence high with three devices or more, or two within the window; low when they went down far apart; the switch incidents inside keep their own cause |
| `reboot` | a restart of the switch (`device-restarted` from the poller, `cold-start`, `warm-start`, reload messages) within `reboot_lookback_s` (300) before, or the window after, the first member | no timing asked of the ports |
| `module` | a module or stack event (`module-down`, `module-offline`, `stack-unit-down`, ...) not yet answered by its `-up`, within `hardware_lookback_s` (300) before or the window after; its slot or unit must be the ports' (**both** are compared with the unit and slot read from the port names: `ethernet1/2/5` is unit 1, slot 2; `Gi0/12` slot 0). An event for another slot is shown as `against`. Also, without any event, when at least 80% of the ports are in one slot and they went down together, **but only on a device whose ports are in two or more units/slots** (on a switch of one slot every burst is "in one slot" and says nothing) (medium) | high when the slot matches and the event is within a minute |
| `flapping` | at least three members, and half of them, went down again after coming back at least three times | `incident_kind: flapping` |
| `change` | a configuration change (`config-change`) on the switch within `change_lookback_s` (300) before the first member; the evidence says who and what when the pack gives it (`user.name`, the message) | high within a minute |
| `power` | `psu-fail`, `fan-fail`, `fan-or-psu-fail` or `temperature-high` not yet answered by its `-ok`, within `hardware_lookback_s` of the first member | high when the ports went down together and the trap is within a minute before or 30 s after |
| `common` | the first `min_members` ports went down within `common_spread_s` (10 s): a common cause on the customer side (power in the served building, a shared line card or PoE budget) with the uplinks up and the switch reachable | medium; low when they took up to `scatter_s` (60) |
| `scattered` | slower than `scatter_s`: independent events or a gradual problem | low or medium (medium across slots); minor unless it keeps growing; shows the rate per minute |

**Evidence is kept** in a small table (`alert_evidence`, migration 0330) because the event inspector's ring is neither durable nor shared between replicas. Only
the actions above (the Dell chassis, stack and health notifications as the pack emits them, and the rule's `cause.evidence` expressions) are kept, a configuration change is kept as who made it and a fixed phrase (not the message text), at most 200 a second, the same action of the same component of a device
within 5 s counts once, a row lives 24 hours and the table holds at most 200000 rows. The hot path pays one map lookup on `event.action` per event and
nothing else; the replica that received the event appends the row off the hot path and the leader reads rows when it decides, so a leader change or a
restart loses none. An incident keeps the rows its conclusion used (at most 60) with itself. Uplink link changes are recorded from the member events
the rule already receives (a port the class filter leaves out because it is an uplink).

`cause` in a rule's spec tunes the windows (`common_spread_s`, `scatter_s`, `uplink_lookback_s`, `hardware_lookback_s`, `reboot_lookback_s`,
`change_lookback_s`; 0 keeps the default), adds events (`evidence: [{"match": "<event expression>", "kind": "power|fan|temperature|module|stack|reboot|config", "ok": false}]`) or
turns the inference off (`off`: no cause, the rule's severity).

**Impact.** From the Device Tracker's port history the incident lists, per member, the endpoints last seen on the port before it went down (MAC, IP,
hostname, user, vendor) and the tenants (the device's, and the tracker's). A member is **active** when an endpoint was seen on its port within
`impact.active_s` (24 hours) before it went down, otherwise **idle**; `affected` counts the distinct endpoints on active members (the endpoints of idle ports are
listed, not counted), `active_members` and `idle_members` split the members the tracker has sightings for; members it has nothing on (a device it does not poll, a port name it does not know) are `unknown_members`, not idle, and never lower the severity, `access_ports` and `fraction` say how much of the switch's access ports is down.
The tracker is read in the background (at most four reads at once), never inside the leader's write transaction, and what is kept for an incident goes when it resolves; and the result is kept while the member set does not change: an incident can open (and, with a first-notification wait of zero, send its first message) before `affected` is known, and the next update carries it. Counters are not read: activity is the tracker's sightings. A site incident adds up its switches (an endpoint behind two switches counts twice). Endpoints
are listed in the incident's detail, not in the notification, and not for a client token. `impact: {"off": true}` leaves the tracker alone; `lookback_s`
bounds how old a sighting may be (7 days).

**Severity.** The rule's severity is the base; points move it by whole steps (the points that applied are kept with the incident): member count against
`min_members` (+1 at twice, +2 at five times), fraction of access ports (+1 from 25%, +2 from 50%), devices (+1 for two, +2 for three), affected endpoints (+1 from 10,
+2 from 50), no or few active members (-2, -1), duration (+1 over 15 minutes, +2 over an hour), cause (+2 site, uplink, reboot; +1 module, power; -2 scattered unless
growing; -3 planned). A score of 3 or more raises one step, 6 or more two; -2 or less lowers one, -5 or less two; planned is never above minor.
`escalate: [{"when": "fraction >= 0.5 || devices >= 3", "severity": "critical"}, {"when": "down_for > 900", "severity": "critical"}]` raises further: the conditions read
`count`, `peak`, `recovered`, `fraction`, `devices`, `affected`, `active`, `idle`, `down_for` (seconds), `flapping`, `access_ports` (numbers) and `cause`, `confidence`,
`kind`, `severity` (words) with `== != < <= > >=`, `and`/`&&`, `or`/`||`, `not`/`!` and parentheses. A severity rises at once and comes down only after five quiet minutes; a different cause replaces the earlier one when it is more confident, when the earlier one was a maintenance window, or after 30 seconds (while it is held the whole earlier result is kept: cause, confidence, sentence and evidence). The user who made a configuration change is named in the evidence item only, never in the sentence, the labels, the summary or the history. A severity change is written to the history (`severity`) and goes through
the policies: a policy that lists `critical` starts to announce the incident, and the policies that announced it keep sending its updates and its resolve whatever the
severity became.

**Notification updates.** The first message is sent when the incident is first due. After that an **update** (status `update`, the same fields as the first message with the
current title, summary and labels) goes out only on a material change: the cause changed, the severity changed, or the member count crossed 10, 20, 50, 100, 200, 500, 1000
or 2000 (or `min_members`) in either direction, and at most once per `incident_update_s` (setting, default 300) for an incident. What the last message said is kept with the
incident, so a new leader neither repeats nor skips one; each update has its own key. An incident sends at most 24 updates for each day it has lasted (a rise of severity is exempt from this budget, not from the five-minute spacing). An acknowledged or held-back incident sends none. Channels that can edit (Discord,
Fluxer, Matrix, Telegram) edit the first message in place, the others get a new message ([alerting-channels.md](alerting-channels.md#incident-updates)). The **resolve** message
carries the duration, the peak, the cause, the endpoints affected and the members. Routing labels for policies: `incident_kind` (`switch`, `site`, `uplink`, `flapping`),
`cause`, `confidence`, `affected` (and `count`, `fraction`, `active_members`, `cause_text`, `reason`).

Evidence counters are on `/metrics` (`seshat_alert_evidence_emitted_total`, `seshat_alert_evidence_dropped_total`, `seshat_alert_evidence_expressions_ignored`) and in the engine stats. After new evidence the leader looks again only at the incidents of that device or site; new rows are found by the time they were written, with a look-back, not by the highest id, so a row that commits late is not missed.

**Dry-run and replay** judge the cause by the shape only (when the members went down, their slots, their flapping): events are not stored, so they do not see power, module,
uplink, reboot or configuration evidence, and say nothing of impact or severity.

**Rolling upgrade.** Migration 0330 adds tables only (expand); a 0.11.x node never reads them and does not know the `cause`, `impact` and `escalate` fields of a rule's spec (it
skips an enabled correlation rule anyway). The `alert_correlation` gate still governs everything: while a node of an older release is in the cluster the incidents are held back
with their cause and no update is sent. A saved settings document without `incident_update_s` keeps the default.

### Trying a rule

`POST /api/alerts/rules/dry-run` with `{"rule": {...}}` runs a rule, saved or not, over recent events and returns what it
would have done: the signals in order, how many identities would be open at the end, and how many events of each dataset
were examined. Nothing is written or sent. Absence rules cannot be tried.

Recent events come from a small in-memory ring **per dataset** (`SESHAT_DRYRUN_RING`, default 1000 events per dataset,
0 to 5000, `0` turns the rings off; together they hold at most `SESHAT_DRYRUN_RING_MB` of memory, default 64 MiB, 1 to 4096,
estimated from each event's size and shared evenly over at most 16 rings, so a ring of large events keeps fewer than its count and
drops its oldest first; the high-volume `seshat.flow`, `seshat.flow_rollup`, `seshat.device`,
`seshat.passthrough` and the engine's own `seshat.alert` documents are not kept). A busy dataset therefore never pushes
the others out: an interface-down rule is tried against the traps even when the firewall's syslog is a thousand times
louder. The rules' own dataset is used when the rule names one; a rule without one is tried against every dataset kept.
The rings hold references to events under the pooled-event contract and are memory only; nothing is persisted.

The scope is applied **before** the events are counted:

| Field | Meaning |
| --- | --- |
| `datasets` | up to 8 dataset names, e.g. `["seshat.trap"]`, `seshat.syslog`, `seshat.reachability` |
| `site`, `device` | only events of that site, or of that device (name, id, source address or host name) |
| `window_minutes` | only events newer than this (for `source: "history"`, the span read: default 60, at most 1440) |
| `events` | most events examined per dataset (default 2000, at most 20000) |
| `source` | `recent` (default) or `history` |

`events` counts per dataset (a run over three datasets may examine three times that), and `datasets` that leave out the
rule's own dataset are called out in the answer's `note`. The `site` and `device` filters mean different things in the two
modes: over recent events `site` is the device's inventory site, else the listener's site, and `device` matches the device's name or id, the
host name, the sender address or the syslog host name; over stored history both are the exact site and device name of the
metric series.

The cost is bounded: at most 60000 events are looked at and the run stops after 8 seconds (the answer then says
`truncated`). `source: "history"` replays the stored metric history (the [metric store](metrics-store.md)) of a
threshold or state rule over the window: raw samples for a window of two hours or less, five-minute buckets beyond,
at most 200 series and 100000 points; a state rule sees the stored numbers (enumerations as their codes), not text.
Events have no queryable history in Seshat (they are forwarded to the destinations), so an event rule run with
`source: "history"` says so and examines nothing.

### Storm view

`GET /api/alerts/storm?window=5&limit=10&dataset=seshat.trap` (window 1, 5 or 15 minutes) lists, per dataset, the
busiest senders by event rate: address, device and site when known, count and rate over the window, total, last seen and
the latest event name. The console shows it under **Alerts, Storm**. It is built from counters kept as events pass, not
from stored events: 16 one-minute buckets per (dataset, sender address), at most 4096 senders per dataset and at most 12 datasets; memory only. When a dataset's table is full, senders idle for
the whole 16 minutes are dropped and a newcomer replaces the weakest of a sample of eight (it inherits that sender's score,
the space-saving algorithm), so a flood of spoofed one- and two-event addresses keeps replacing its own and cannot push out a
sender that keeps sending; `evicted_senders` counts the replacements and the counts of a replaced sender are gone. Flow
exporters are not counted here (their rates are on the flow input's statistics). For SNMP `authenticationFailure` traps the row also lists `requesters`: the address of whoever sent the bad
request, where the agent says (the standard trap carries none, some vendors add a varbind). A varbind counts when its
value is an address other than the sender and the agent address (not unspecified, loopback, multicast or broadcast) and either it
has the type IpAddress or its MIB name says it is a source, client, manager or requester address (octet strings count only
with that name); the proxy objects of SNMP-COMMUNITY-MIB (`1.3.6.1.6.3.18.1.*`) never count. `requester_from` names the
varbind, with its OID. A trap without such a
varbind leaves the field empty. The view shows sender addresses of every site, so it needs a caller that is not limited
to some sites or tenants.

## Port classes

A rule that speaks of "access ports" needs to know which ports those are. Seshat classifies every interface of a device as one of four classes
(read-only toward devices: it reads what polling and the inventory already learned):

| Class | What it is | How it is recognised (first match wins) |
|---|---|---|
| `uplink` | leads to another switch, router, firewall or controller | an operator's override; the inventory's interface role says uplink; an LLDP/CDP neighbour that is a switch, router, firewall or controller in the inventory (by the neighbour's role, whole words of it: a `voip-gateway` is not a gateway); the port is a LAG or a member of one |
| `infrastructure` | not a customer port | the inventory's role says infrastructure or management; a neighbour that is an access point, a server or another known infrastructure device; a virtual interface (loopback, VLAN, tunnel, management); a port the access-port selector leaves out |
| `access` | a customer-facing port | none of the above, and selected by the access-port selector (everything, when none is set). A neighbour that advertises bridge or router capabilities but is not in the inventory is a customer's switch or modem, so it does not make an uplink (`unknown_bridge_neighbour: uplink` in the selector says otherwise); the port's reason says so |
| `unknown` | not enough is known | the device's interface table was never read |

A phone, a camera or a printer on a port is an endpoint, not infrastructure: IP phones bridge, and are read as the tracker reads them. If
a port has several neighbours the strongest wins (an uplink beats infrastructure).

- **Selectors.** `PUT /api/port-classes/selectors` sets, per site and/or role (both empty: the default for every device), which ports are
  access ports: `include` and `exclude` are name globs (`*` any run, `?` any one character, case ignored), `alias_regex` and
  `exclude_alias_regex` are RE2 on the interface's alias (its description); `unknown_bridge_neighbour` (`access`, the default, or `uplink`) says what a neighbour that
  bridges but is not in the inventory makes of the port. A port is selected when it matches an include glob or the alias
  regex (or when neither is set) and no exclude. Use it where the inventory has no interface roles: names such as `ethernet1/1/*` minus the
  uplinks, or the aliases the switch itself carries. The most specific selector that fits a device applies: site and role, then site, then
  role, then the default.
- **Preview.** `POST /api/port-classes/preview` (`{"device": "Example Switch 3", "selector": {...}}`) says "this selector makes 44 of 52 ports
  access ports on Example Switch 3" before anything is saved (`matched` of `total`, `selector_matched` for what the selector alone selects,
  the counts of the other classes and example names). Without a selector it shows the one in force.
- **Who may change what.** A caller limited to some sites or tenants may change the override of a device of its sites only (another site's device answers
  404) and the selectors of its own sites only; the default selector and a role-wide one cover every site and need a caller that is not limited. It
  lists only the selectors of its sites.
- **Override.** `PUT /api/devices/{id}/port-classes/override` (`{"interface": "ethernet1/1/7", "class": "access", "note": "..."}`) sets the
  class of one interface by hand; it wins over everything, and `DELETE ...?interface=` removes it. The console's device page has a Class
  column with this control, and Alerts, Port classes edits the selectors.
- **Suggested interconnects.** The tracker suggests ports that look like trunks from the MACs the ports hold (a port whose MACs another polled device
  sees on at least two of its non-uplink ports). A suggestion is advisory (the port's class is not changed, the `suggested` field says why); confirm it by overriding the
  port to uplink, or with `POST /api/devices/{id}/port-classes/detected/confirm?interface=` and `POST /api/port-classes/suggested/confirm`, or dismiss it with
  `DELETE /api/devices/{id}/port-classes/detected?interface=` (docs/device-tracker.md, "Suggested interconnects"). The inventory roles `uplink`, `trunk`, `core`, `backbone` and `interconnect` make an
  interface an uplink (NetBox: an interface custom field `role` or a tag of that name).
- **Where the facts come from.** The interface table (name, alias, type) is the knowledge base's: SNMP polling, or the inventory (NetBox
  interfaces now also bring the LAG an interface belongs to and its role). LLDP/CDP neighbours and LAGs are what the Device Tracker's poller
  saw on the last full poll of the device; the replica that polled stores them, so every replica classifies from the same facts
  (`port_class_obs`). A device polled by an edge does not yet report neighbours to the server: its classes come from the interface table,
  the inventory, the selector and overrides.
- **Cheap to ask.** The classes are derived and cached in memory per device (keyed by the device's record revision and a version that
  changes when a selector, an override or an observation does), so a rule asks for one with a map lookup on the evaluation worker, never on
  the event path. Replicas notice a change within seconds (migration 0328; a release that does not know port classes never reads these
  tables).
- `GET /api/devices/{id}` lists each interface with `class`, `class_source`, `class_reason`, `class_override` and its neighbours;
  `GET /api/devices/{id}/port-classes` lists just the classes.

## Alert lifecycle

`firing` → `acknowledged` (with a note; the alert keeps firing but stops escalating and repeating) → `resolved`.
An alert is deduplicated by fingerprint: a rule firing again for an open identity raises `occurrences` and `last_seen_at`
(a replica coalesces identical repeats within five seconds and admits a rule events at a limited rate, so the count is a lower bound under a storm; a refresh of a standing condition is not an occurrence). History is
kept for 90 days by default (`retention_days` in the settings) and every alert keeps its own timeline: fired, flapping,
suppressed, unsuppressed, ack, unack, resolved or closed. An alert resolves by `clear` (a clear signal), `auto` (timed
out), `user` (closed by hand), `explained_by` (an incident closed because a device-down alert explains it), `stale` (a threshold or state alert nothing re-asserted for `stale_s`, 1 hour), `flap_settled`, `rule_deleted`, `rule_changed` (the key, clear expression or metric path changed) or `rule_disabled`. Changing or disabling a rule resolves its open alerts with that reason and sends the resolved notice. Closing an alert whose condition still holds: an event alert opens again on the next event; a threshold or state alert opens again
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
and keeps its history; `suppressed` says why (`silence:<id>`, `maintenance:<id>`, `dependency:<device>`, `correlation:<incident id>`). When the hold
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
| Access ports down together | correlation | five or more access ports of one switch down within 2 minutes (the events of the "Interface down" rule), resolves below two; see [correlation rules](#correlation-rules) |

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
| `POST /alerts/rules/dry-run` | try a rule against recent events (scoped by dataset, site, device, window) or stored metric history; a correlation rule answers with the `incidents` it would have opened |
| `POST /alerts/rules/suggest` | a correlation rule's history replayed with min_members 3 to 20 and baseline factors 2 to 10: incidents each would have opened |
| `GET /alerts/baselines` | what is normal: the usual members down per hour of the week of a rule's switches or sites, and the threshold now |
| `POST /alerts/rules/replay` | a correlation rule over the stored alerts of its members: how many incidents it would have opened in the last N days |
| `GET /port-classes/selectors`, `PUT /port-classes/selectors`, `DELETE /port-classes/selectors/{id}`, `POST /port-classes/preview` | the access-port selectors and their preview |
| `GET /devices/{id}/port-classes`, `PUT` and `DELETE /devices/{id}/port-classes/override` | the class of every interface of a device, and the operator's override |
| `GET /alerts/storm` | top senders by event rate per dataset over 1, 5 or 15 minutes; `window`, `limit`, `dataset` |
| `POST /alerts/preview` | which open alerts a silence or maintenance window being drafted would hold back |
| `GET/POST /alerts/silences`, `GET/PUT/DELETE /alerts/silences/{id}` | silences (`?all=true` includes ended ones) |
| `GET/POST /alerts/maintenance`, `GET/PUT/DELETE /alerts/maintenance/{id}` | windows, with `active` and `next_start` |
| `GET/POST /alerts/policies`, `GET/PUT/DELETE /alerts/policies/{id}` | notification policies |
| `GET/PUT /alerts/settings` | `flap_count`, `flap_window_s`, `retention_days`, `max_open_per_rule`, `close_holdoff_s`, `stale_s`, `clear_grace_s`, `clock_skew_s`, `late_s` |
