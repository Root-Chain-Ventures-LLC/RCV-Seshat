# Metric history store

Seshat keeps a history of the `seshat.metric` samples it receives or collects (SNMP polling, streaming telemetry, sFlow
interface counters, the reachability probe) in the database it already uses, SQLite or PostgreSQL, and answers range, latest and
top-N queries over it. It is the data behind the metric views (a chart with overlays, the fleet interface table, the device
health page) and the built-in alert engine ([alerting](alerting.md)). API under `/api/metrics/*`.

Nothing here changes how metrics are routed to destinations. The store is one more tap on the event pipeline.

## What is stored

- **Input.** Every `seshat.metric` event with a numeric value (integers, floats, booleans as 0/1). Deletes and strings are skipped, except
  the enumerations telemetry sends by name: `oper-status` (`UP` 1, `DOWN` 2, `TESTING` 3, `UNKNOWN` 4, `DORMANT` 5, `NOT_PRESENT` 6,
  `LOWER_LAYER_DOWN` 7, the IF-MIB numbers) and `admin-status` (`UP` 1, `DOWN` 2, `TESTING` 3) are stored as their number, as `state`.
  The alert engine reads them the same way, so a name and its number are one reading everywhere. Any other string
  is still skipped.
  The store uses the same path normalisation as the metric destinations.
- **Series identity.** device, path without list keys, interface, remaining labels, source. The device is the knowledge-base name,
  else the host name, else the address. The interface comes from the `interface` label, else the `name` label or list key of an
  `interfaces/interface[...]` path, so the same interface seen through gNMI and through SNMP polling is one series.
  Site and tenant are part of the identity: the same device name at two sites is two devices, and their counters never share a series.
  (A device that is classified into a site later therefore starts a new series from then on.)
- **Kind.** `counter`, `gauge` or `state`, as the event says; when it does not, a path under `/counters/` is a counter and everything
  else a gauge. Whatever the collector says, `oper-status`, `admin-status` and `reachability/*/up` are stored as `state`: a bucket
  mean of up and down (0.58) is not a status, so a state is read with `last` (the UI asks for `min` on up/down charts, so an outage inside a bucket shows).
- **Values** are stored as float64. Integers up to 2^53 are exact; larger 64-bit counters lose the low bits, which is invisible in a rate.

## Tap and write path

The store taps the event pipeline. On the caller's thread it does
a dataset check and one non-blocking channel send; it never parses, allocates or touches the database. A full queue (default 65 536
events) drops the event and counts it (`queue_dropped`). Everything else happens on three goroutines:

1. the **aggregator** extracts samples and appends them to the open chunk of the series, and to the open rollup buckets;
2. the **writer** wakes every `flush_seconds` (default 30), copies the open chunks that changed and writes them, in transactions of at
   most 500 rows, as upserts. A failed transaction puts its rows back for the next flush;
3. the **refresher** re-reads settings, retention and the series list every 30 s.

**Durability bound.** Open chunks live in memory. A crash (or kill -9) loses the samples that were not yet flushed: at most
`flush_seconds` of data, plus whatever is still in the intake queue (a few seconds at the rates the queue is sized for). A clean
stop drains the queue (every event accepted before the stop is appended) and writes everything, rollup buckets still filling included
(`TestStopDrainsTheQueueAndWritesEverything`). Rollup buckets are written when they close (every 5 minutes and every hour); a crash
also loses the 5-minute and 1-hour bucket that were still filling, but not the raw samples, which are flushed, so a bucket can be
rebuilt from them.

**When the database does not take writes.** A failed flush puts its head snapshots back and tries again later. Finished chunks stay in the
pending list until the write that carries them has *committed* (a read in between still finds them), and are readable by queries (a chart
does not show a hole for the outage), within two bounds: `pending_mb` (default 256 MB) for all series and 8 MiB per series; over either the
oldest, by chunk start, are dropped and counted (`pending_dropped`). A snapshot of an open chunk whose chunk has since been finished is
never written again: the finished chunk has the same key and its fuller content must not be replaced by the older, shorter snapshot.

**What counts as a bad row.** Only a failure that one row can cause: a PostgreSQL data or integrity exception (SQLSTATE class 22 or 23, such
as a NUL in text) or a SQLite constraint, mismatch or too-big error. A batch that fails that way is retried row by row, and a row that still
fails alone is set aside (a series row: *quarantined*, `quarantined_series`; a chunk row: dropped, `quarantined_rows`; one line in the log),
while the other rows of the batch are written. Everything else (a read-only replica after a failover, a full disk, an I/O error, a lost
connection, a timeout) hits every row alike: nothing is quarantined, the rows are kept, and the flush loop backs off (5 s, doubling to 5 min,
back to normal after a good flush). If every row of a batch fails when tried alone, that is an outage too. A quarantined series drops its
samples for an hour and is then tried again; it stays listed and its stored history stays queryable. Series rows are written in key order
so two nodes cannot deadlock on each other.

**Optional at start.** If the store cannot read its state when the gateway starts, the gateway starts anyway: the store logs it, takes samples
within the bounds above, writes nothing, and retries the load every 30 s. `status` and every answer's `meta` carry `degraded: true` (and `loaded:
false` in status, with a note) until it has loaded. Nothing is written before the settings have been read once, and if they say the store is off,
what was taken before that was known is thrown away, so an administrator's disable is honoured. Without a store at all the API answers 503
`metrics_unavailable`.

**Intake hygiene.** NUL bytes and invalid UTF-8 are removed from device, path, interface and label names (PostgreSQL refuses both in text),
and they are cut to 255 bytes (device, interface, site, tenant), 512 (path), 64 (label key), 256 (label value), at most 16 labels. A
sample may be at most 60 seconds ahead of the clock (a later one is refused and counted as `future_time`). Such a sample counts as the
series' newest only up to the time it was received, so a forged timestamp 59 seconds ahead cannot make the series drop the real samples that
follow it, again and again; an exact repeat of the last timestamp is still a duplicate. A raw chunk is closed at 65 536 samples
or 128 KiB, whichever comes first, so no chunk grows past what can be read back; a chunk that cannot be decoded is counted as
`decode_errors`, apart from non-numeric values.

### Layout

| table | one row per | holds |
|---|---|---|
| `metric_series` | series | key, device, site, tenant, path, interface, labels, source, kind, counter width, first and last time |
| `metric_chunk` | series, resolution, chunk, writer | a compressed block of samples (raw) or buckets (5m, 1h) |

A chunk row covers up to 1 hour of raw samples (less when it was closed at its size bound), 6 hours of 5-minute buckets or 24 hours of
1-hour buckets. The key includes the writing
node and process run, so two nodes writing one series into a shared PostgreSQL, or one node before and after a restart, never overwrite
each other. A reader merges rows by time: samples at the same time are one sample, buckets at the same time are combined, and the
combined bucket's "last" is the one whose sample is the later in time (each bucket stores the time of its last sample), whichever writer
wrote it, so a hand-over between nodes or a restart gives the right last value and the right rate. The tables are
written straight to the connection pool (like the tracker's): they are derived data, not replicated by the SQLite cluster sync and not
journalled for the offline mode. The SQLite-to-PostgreSQL copy tool carries them.

### Resolutions

| resolution | bucket | default retention | holds |
|---|---|---|---|
| raw | every sample | 24 hours | the sample |
| 5m | 5 minutes | 14 days | min, max, sum, count, last (mean = sum / count) |
| 1h | 1 hour | 90 days | the same |

**Counters** keep only the sample count and the last value in their rollups. Min, max and mean of a monotone counter carry nothing a
rate needs (the rate comes from the last values), and each of them would cost as much as the last value. Asking a counter's rollup for
its mean returns roughly its last value.

Retention is part of the existing retention settings (`GET/PUT /api/retention`): `metric_raw_hours`
(default 24), `metric_5m_days` (14), `metric_1h_days` (90). **Each must be at least 1.** The other retention fields use 0 for "keep
forever"; a metric field of 0 would mean "forever" to one reader and "delete" to another, so it is refused (400), and a 0 found in a stored
policy is replaced by the default and never deletes anything. The upper bounds are 744 hours and 3650 days. Retention deletes whole chunk rows
that started more than one chunk span before the cut (so a resolution keeps up to one chunk span more than configured), 1 000 rows per
statement with a short pause between statements, so it never holds SQLite's write lock long enough to stall other writers. A series whose
chunks are all gone and that has not been seen within the longest retention is removed too.

A resolution is **switched off** with its own store setting (`raw_enabled`, `rollup_5m_enabled`, `rollup_1h_enabled`, all on by default):
nothing is written at it, queries refuse it, and what is stored ages out by its retention.

`metric_chunk` is indexed on `(res, start_ms)`, not on the end time. Every flush rewrites the open chunk's end time, and an index on a
column that changes defeats PostgreSQL's heap-only updates and bloats the index; the start time never changes. The table keeps 20 %
free space per page (`fillfactor = 80`) so those upserts can stay on their page (migration 0321).

**Last sample.** Each series row carries the time of its last sample (`last_ms`, *not* the end of a chunk, which for a rollup is later). It is
written in batches every 2 minutes for the series that changed (and at a clean stop), and other replicas and a restart read it: the refresh
selects only the rows changed in the last 20 minutes (an index on it, migration 0322), so there is no scan of the chunk table and no
per-series work at start. "Stale" and the revival of an idle series derive from it, accurate to within a few minutes.

### Caps and the disk budget

| setting | default | when exceeded |
|---|---|---|
| `max_series` | 50 000 | new series are refused |
| `max_series_per_device` | 5 000 | new series of that device are refused |
| `disk_budget_mb` | 4096 (0 = none, else at least 64) | the oldest chunks are deleted until under it, never the newest data; new series are refused meanwhile |
| `series_idle_days` | 7 | a series with no sample for this long leaves the series cap and the ingest state; it stays listed and queryable |
| `pending_mb` | 256 | the oldest unwritten chunks are dropped |

A refused series is counted once per series, not once per sample (`refused_series_cap`, `refused_device_cap`, `refused_disk_budget`;
Prometheus `seshat_metricstore_refused_series_total{cap}`), and `GET /api/metrics/status` carries a note and the time of the last
refusal. Existing series keep recording.

**Disk budget.** On PostgreSQL the figure is `pg_total_relation_size` of the two tables, indexes included; elsewhere the bytes of chunk data times 1.7
(1.68 measured on SQLite). It is taken every 5 minutes. When it is over the budget, the oldest raw chunks are deleted first, then 5-minute, then 1-hour
ones, 500 rows at a time with a short pause, until it is under; the deletions are counted (`budget_deleted`). The newest data is **never**
deleted for the budget: the newest 2 hours of raw samples, the newest 24 hours of 5-minute buckets and the newest 48 hours of 1-hour buckets are
kept. If that is not enough, deletion stops there, new series stay refused, and status says `over_budget: true`; whenever data was removed the
status note says so ("older history is shorter than the retention says"). That is why the smallest budget accepted is 64 MB. Queries pick their
resolution by what is actually on disk (the oldest chunk of each resolution), not by the retention, so a range that raw no longer reaches is
answered from a rollup. On a shared PostgreSQL only the cluster leader enforces the budget; each SQLite node enforces its own file. SQLite does
not give pages back to the file system, it reuses them.

**Idle series.** A series nobody reports any more (a decommissioned device, a spoofed exporter that tried a million names) must not hold
a slot of the series cap for the whole retention, and a device that has been dead for a week is exactly the one whose history someone
wants to see. After `series_idle_days` without a sample a series therefore leaves the cap, the per-device count and the ingest state
(no open chunks, no pending data), but stays in the series list as a small metadata entry (about 400 bytes). At most 200 000 idle entries are
kept: when the list is full, entries of devices the device inventory does not know (stray or spoofed exporters) go first, then the ones with the
oldest last sample; a restart loads series newest first. Their chunks stay until retention removes them. It is returned by `series`, `labels`, `devices` and range queries
with `"idle": true`, and `status` counts it as `idle_series`. The entry's last-sample time is the series row's `last_ms`. A new sample **revives** it: it takes a slot like a new series (refused if a cap is reached), carries on
from the newest sample it has stored, and anything not newer than that is dropped as out of order, so the revived series cannot overlap its
history. A restart lists idle series again without counting them. When retention removes the last chunk and the series row, the entry goes.

Settings are changed with `PUT /api/metrics/settings` (administrators only, and not by a caller limited to a scope; audited) and take
effect on this node at once and on the others within 30 s.

### Disabling

`enabled: false` stops sampling and writing: `Accept` returns after one atomic load. Stored history stays readable, and every answer
carries `meta.enabled: false` so a view can say that nothing new is being recorded. Switching all three resolutions off has the same
effect (the status note says so).

## Compression

Chunks use a Gorilla-style encoding in pure Go (no cgo, no new dependency): timestamps as delta-of-delta with a 1 to 5 bit prefix class,
values as the XOR with the previous value, stored with the leading and trailing zero counts of the XOR. A series that does not change costs
about one bit per sample.

It was chosen by measurement against a byte-aligned alternative (zigzag varint delta-of-delta timestamps; integral values as zigzag varint
deltas; other values XORed with a one-byte length header). `TestCodecEvaluation` (`codec_eval_test.go`) generates seven kinds of series, 60
samples at 60 s with 80 ms of timestamp jitter (one raw chunk), and prints the sizes. Run on this branch:

```
series (60 samples @60 s)            uncompressed B  gorilla  varint
counter, busy link (octets)                     960      328     322
counter, mostly flat (errors)                   960      106     142
gauge, cpu percent (integer)                    960      172     146
gauge, temperature random walk                  960      136     208
gauge, rtt ms (noisy float)                     960      516     567
state, constant (oper-status)                   960      104     142
gauge, constant (speed Mb/s)                    960      103     149
total                                          6720     1465    1676
```

Gorilla is 13 % smaller overall and wins clearly on the series that dominate a real fleet (flat counters, states, constants, slowly moving
gauges); the varint codec wins only on integer gauges and on a busy counter, by 2 to 15 %. It is also the simpler of the two to extend
(rollups reuse the same value stream per column). The varint codec stays in the test file only, as the record of the comparison.

## Latest values: the newest two samples in memory

The aggregator keeps the newest two samples of every series in memory. The fleet table, the device summaries, `latest` and the
`top` ranking by `latest` are built from them: no chunk is read and no read budget applies, so their cost is the number of series (a
17 000-series table is built in tens of milliseconds, and a computed table is reused for 5 seconds per scope and filter). Nothing is
capped or cut alphabetically; `latest` announces a cut with `truncated`.

- **Freshness.** A sample is current when it is no older than three times the distance of the last two samples, and at least five
  minutes. Past that bound a value is not shown as current: an interface row is `oper_state: "unknown"` with `oper_stale`, its
  rates are left out with `rates_stale`, and a device summary leaves the value out and lists the metric in `stale_metrics` with its last
  sample time ("no recent sample"), which is told apart from a metric never stored (simply absent). Series of a silent or idle device
  stay listed, as unknown.
- **One source per interface and metric.** The same interface counter can be stored from the SNMP poll, gNMI and sFlow, as separate
  series. The interface table, the device summaries, `latest` and `top` show one of them for each interface and metric: the freshest
  usable one (a current sample, for a counter one that has a rate), else the newest. A series that stopped reporting never overwrites a
  live one, whichever is read first. The interface row names the source (`source` for the status, `rate_source` for the counters). The
  Explorer and `query` keep every series; the Explorer adds the source to a line's name when an interface has more than one.
- **Status codes.** Only ifOperStatus 2 is down. 3 (testing), 5 (dormant), 6 (notPresent), 7 (lowerLayerDown) and 4 (unknown) are
  states of their own (`oper_state`). `admin_up` is false only for ifAdminStatus 2. A device's `interfaces_down` counts neither
  not-present nor administratively down ports (`interfaces_admin_down`, `interfaces_other`, `interfaces_unknown`).
- **Several nodes.** A node holds in memory only what it received. Two things complete the picture, in this order:
  1. *Peers.* When cluster peers are configured (`SESHAT_CLUSTER_PEERS`, SQLite or PostgreSQL alike) the table asks them for their heads
     (one `heads` call, merged per series by the newest sample), and a peer that does not answer makes the answer `partial`. A configured peer the cluster has marked down is not asked (it would hold the query for the peer timeout), but it is still named in `coverage.failed`, so `partial` stays true for as long as it is down.
  2. *The database.* For every series that no node answered for (it has no sample in memory, or the series row's last-sample time is more
     than two and a half minutes ahead of the sample held) the node reads the newest chunk rows from the database in one bounded read
     (400 series per query, at most 60 000 series and 12 million points per request, the freshest series first). On a shared PostgreSQL
     every replica therefore returns the whole fleet, filtered, sorted and paged correctly, with or without peers configured; with a peer
     down it is `partial` but still complete. What it reads is what the writing node has flushed, so it can trail a live sample by up to
     the flush interval (30 s by default); the freshness rule above applies to it unchanged. A series silent for more than six hours, or
     past the caps, reads as unknown and the answer sets `truncated` (the UI says the table is incomplete). Measured: a node that holds none of
     17 500 series built the 2 500-interface table from the database in 180 ms on SQLite (`TestMeasureSharedDatabaseTable`); the table is
     reused for 5 seconds.
- **Devices** are keyed by device and site. `GET device?device=NAME&site=SITE` takes the name as a query parameter (a path segment
  cannot carry `/`, `+`, `:` or `,`); `GET devices?interfaces=0` leaves out the interface counts (the reachability board).

## Query API

All routes are under `/api/metrics`, read by admin, operator and viewer (the `user` role gets 403, never an empty list; no token without
one of those roles gets in). Settings are changed by admin and operator. Callers with a scope (API tokens) are limited to the series whose
site or tenant their scope lists, by the same rule as the tracker APIs; a request body cannot widen it; a device outside
the scope answers 404 like an unknown one. Every answer carries

```json
"meta": {"enabled": true, "coverage": {"nodes": 1, "merged": false, "partial": false}}
```

and an error is `{"error":{"code","message"}}`: `invalid_query` (400), `query_limit` (422, a hard limit), `metrics_unavailable` (503,
the store is not running on this instance).

| route | purpose |
|---|---|
| `GET status` | enabled, settings, retention in force, series and device counts, disk estimate, queue, drop, quarantine and refusal counters, last flush. A caller limited to a scope gets `{"enabled": ...}` only, and `settings` answers it 403: totals over the whole store are not its business |
| `GET/PUT settings` | `enabled`, `max_series`, `max_series_per_device`, `disk_budget_mb`, `flush_seconds`, `raw_enabled`, `rollup_5m_enabled`, `rollup_1h_enabled`, `pending_mb`, `series_idle_days`; omitted fields keep their value. PUT: administrators only |
| `GET series` | list series by `device`, `site`, `interface`, `path`, `path_prefix`, `kind`, `source`, `q`; `limit`, `offset` |
| `GET labels?field=` | distinct values of `device`, `site`, `interface`, `path`, `source`, `kind` with series counts (filters as above) |
| `GET/POST query` | range query; POST takes up to 20 queries for overlays |
| `GET top` | top-N by `latest`, `avg` or `max` over a `window`; counters ranked as rates |
| `GET latest` | newest value of every matching series, with the last interval's rate for counters |
| `GET interfaces` | the fleet interface table |
| `GET devices`, `GET devices/{device}` | device health summaries, and one device's summary with its metric paths |

Paths in filters are written without list keys and without a leading slash: `interfaces/interface/state/counters/in-octets`.
Times (`from`, `to`) are RFC 3339, unix seconds or milliseconds, `now`, or relative (`-6h`); `step` is a duration (`60s`, `5m`) or seconds.

### Range query

`GET /api/metrics/query?device=example-switch-3.example.com&interface=Eth1/1&path=interfaces/interface/state/counters/in-octets&from=-6h&scale=8`

```json
{"from":1893456000000,"to":1893477600000,"step_ms":60000,"resolution":"raw","points":360,
 "series":[{"query":"0","series":{"key":"...","device":"example-switch-3.example.com","interface":"Eth1/1","path":"interfaces/interface/state/counters/in-octets","kind":"counter"},
            "rate":true,"rate_stats":{"resets":1},"points":[[1893456060000,2.0e8],[1893456120000,2.1e8]]}],
 "meta":{"enabled":true,"coverage":{"nodes":1,"merged":false,"partial":false}}}
```

- **Resolution** is automatic: the coarsest resolution whose bucket is not wider than the step and whose retention reaches back to `from`
  (a one-hour step over a week reads the hour rollup; a one-minute step over the last hour reads raw samples). When no resolution does both,
  the finest one that reaches back is used. A resolution that has nothing stored yet is never chosen: on a young store (no one-hour
  bucket written yet) the default six hour view is answered from the finest resolution that has data, and starts where that data does.
  `resolution=raw|5m|1h` forces one; a disabled one is refused. The answer names the resolution and
  the step actually used (a step finer than the stored buckets is raised to the bucket width).
- **Step** defaults to about 300 points over the range, in whole seconds, and is never finer than the observed sample interval of the series
  asked for (`sample_ms` in the answer): a finer step could only draw dots or a line broken at every empty bucket. A line is broken only where the
  data has a hole longer than about twice the sample interval. Points are aligned to the step. Empty buckets are absent, so a gap
  in the data is a gap in the line. `agg` picks `avg` (default), `min`, `max` or `last`; `band=1` adds each bucket's min and max as
  `[t, value, min, max]`.
- **Counters become per-second rates** (`rate=auto`; `rate=none` returns the raw counter, `rate=rate` forces it for a gauge). `scale`
  multiplies the values (8 gives bits per second from octets).
  - A counter that goes down is either a **wrap** or a **reset**. Counters are taken to be 64 bits wide, where a fall is always a reset. A counter
    is 32 bits wide only when its collector says so explicitly (`schema.Metric.CounterBits`, set in process: the poller's 32-bit fallback table
    and the 32-bit fields of sFlow interface records); the width is not guessed from a metric's name or a collector's. For a 32-bit counter a fall
    from the top quarter of the range to a value within a quarter of a full wrap is a wrap (increase = new + 2^32 - old); every other fall is a
    reset. After a reset the new value counts as the increase, as Prometheus does. Both are counted in `rate_stats`. Limit: metrics polled on an
    edge collector reach the server as events without the width, so their counters are taken as 64-bit (a wrap reads as a reset).
  - **The width is a property of each stored chunk** (a column of `metric_chunk`, migration 0322; of each bucket in a rollup), and a chunk is
    closed when the width of the samples changes. No rate is computed across a change of width (`rate_stats.width_changes`): a series that moves
    from the 32-bit table to the high-capacity one would otherwise show one interval of 10^10 per second, and old wraps are not reinterpreted.
  - An interval longer than one hour between raw samples (three buckets for rollups) produces no rate; the outage stays visible as a gap
    (`rate_stats.gaps`).
  - From the rollups a rate is the difference of consecutive bucket "last" values over the distance of the times of those last samples.
- **Overlays.** `POST` a body `{"from":"-6h","to":"now","step":"60s","queries":[{"id":"in","filter":{"device":"...","interface":"...","path":"...in-octets"},"scale":8},{"id":"in-yesterday","filter":{...same...},"scale":8,"offset":"24h"},{"id":"cpu","filter":{"device":"...","path":"system/cpus/cpu/state/total/instant"},"agg":"max"}]}`.
  Each query returns its own lines tagged with its `id`; `offset` reads that long ago and draws it at the current time, which gives the
  "this week against last week" overlay with one request and one shared time axis.
- **States** (`state` kind, e.g. oper-status) are read with `last` unless `min` or `max` is asked for: the mean of an enumeration over a
  bucket is meaningless. **Overlays** are bucketed on the shifted time, so an `offset` that is not a multiple of the step still lands on
  the step grid of the line it is drawn against. `scale` must be finite and at most 1e12 in size (400 `invalid_query`).
- **Hard limits** (422 `query_limit`, never a silent cut): 200 series per request, 5 000 points per series, 200 000 points per answer,
  400 days of range (compared in milliseconds), 20 queries, and 2 000 000 points read per request, counted from the chunk headers
  before anything is decoded and shared by every query, overlay and replica of the request (a replica gets an equal share of what is left), so `resolution=raw` over a long retention is refused instead of loaded.

### Top-N, latest

`GET /api/metrics/top?path=interfaces/interface/state/counters/in-errors&by=avg&window=6h&n=10` ranks series by their latest value,
their mean or their peak over the window; counters are ranked as rates. It scans at most 20 000 series (else 422). Rows carry the series, the
ranking `value`, the newest value and its time.

`GET /api/metrics/latest?device=...&path_prefix=system/` returns the newest sample of each matching series within `lookback` (default 30 min,
at most 48 h), with the rate of the last interval for counters.

### Shaped for three screens

- **Chart with overlays**: `POST query` (several paths, an earlier period as an offset overlay, `band` for min/max shading), `GET labels` and
  `GET series` to fill the pickers.
- **Fleet-wide interface table**: `GET interfaces?site=&q=&status=up|down&sort=util&order=desc&limit=&offset=` returns one row per interface:
  oper and admin status, speed, in/out bits per second, in/out utilisation as a fraction of the speed, packet, error and discard rates, the
  newest sample and a `stale` flag (older than 10 minutes), with `total` for the pager. Rows without a value sort last in either direction.
  `top` answers "busiest interfaces" and "most errors" for the same data.
- **Device health page**: `GET devices/{device}` returns ICMP and SNMP reachability, round-trip time, loss, uptime, peak CPU and temperature,
  interface up and down counts and the last sample, and the list of metric paths the device has; `GET devices` is the same as a fleet list.
  The chart route draws any of those paths over time.

## Metric views (UI)

The console's **Metrics** entry (admin, operator and viewer; not the `user` role) has four tabs over this API. The route is
`/monitor` (the path `/metrics` belongs to the Prometheus endpoint):

| tab | route | shows |
|---|---|---|
| Interfaces | `/monitor` | the fleet table from `GET interfaces`, paged on the server (filters `q`, `device`, `site`, `status`, `sort`, `order`, `top`, `offset`, `limit` live in the URL), sparklines for the visible page only, a drill-down chart per interface |
| Device health | `/monitor/device?device=NAME` | `GET devices/{device}` summary, charts for the paths the device reports (CPU, memory, temperature, power supplies, fans, optics, reachability), its interfaces and its open alerts |
| Reachability | `/monitor/reachability` | up, down, round-trip time, loss and last change, down first; the tracker's probes (`/api/tracker/devices`) where they run, the stored reachability metrics otherwise |
| Explorer | `/monitor/explorer?q={json}&q=...&from=-6h&to=now&res=&band=0` | any stored path; one `q` per line (`d` device, `i` interface, `p` path, `a` aggregation, `o` offset such as `24h`); lines of different units get separate charts |

Charts use uPlot (MIT, bundled, no CDN). A gap in the data is a gap in the line, rollup resolutions show the min to max band, and the
state of the store (switched off, not loaded, over budget, history removed by the budget, a resolution off, series refused) and of an
answer (`partial`, degraded) is stated above the view. A 403 is shown as a refusal, never as an empty list.

## High availability

- **PostgreSQL.** Every node writes into the shared database; the series table is the registry, and each node refreshes its copy every 30 s.
  Ranges read the shared chunks, so any node sees all of it; the latest values (fleet table, device summaries) come from memory, peers and the database as described above.
- **SQLite replicas.** Each node stores what it received. A query is answered by the node that got it: it asks the other nodes for their part
  over the cluster peer path (the signed extension requests of the cluster sync, next to the edge relay) and merges: series by key, raw samples at the same time are one sample, rollup buckets are combined. The caller's
  scope travels in the request and is applied on the peer. Peer bodies must carry the request signature's body hash (an unsigned body is refused),
  the cluster's rule for plain `http://` peers applies (`SESHAT_CLUSTER_ALLOW_PLAIN_RELAY`), each peer has 10 seconds, and a peer that does not
  answer is left out. **Peer responses are not signed** (the cluster's extension responses never are): over `https://` peer URLs the TLS
  layer protects them; with plain `http://` peers and `SESHAT_CLUSTER_ALLOW_PLAIN_RELAY=1` the request bodies are authenticated by the
  signature but the answers (series lists and samples) travel in the clear and could be altered by anyone on the path. Do not enable
  that mode on a network you do not control. `meta.coverage` says so: `{"nodes":2,"merged":true,"partial":true,"failed":["node-b"]}`. A view shows "partial" when it is set.
  - Freshness: a replica learns that a series received elsewhere is alive from the series row's last-sample time (written every 2 minutes, see
    above), so "stale" on the device views is right to within a few minutes. New series rows are found by an incremental refresh that looks
    back 5 000 ids from the highest seen (PostgreSQL can commit a lower id after a higher one), and a full reload every 5 minutes.
  - Known limits: a series that two replicas both received is deduplicated sample by sample; the ranking and table views transfer the
    samples of the lookback window for the series they scan (a few KiB per series), so on a large fleet the fan-out makes them slower than on
    one node; the status endpoint describes this node only.

## Monitoring the store

`seshat_metricstore_samples_total`, `_queue_dropped_total`, `_refused_series_total{cap}`, `_out_of_order_total`, `_flush_errors_total`,
`_rows_written_total`, `_bytes_written_total`, `_series`, `_queue_length`, `_last_flush_seconds`, `_disk_bytes` (estimate), `_quarantined_total`, `_pending_dropped_total`, `_decode_errors_total`. Samples that are not newer than the
series' last one are dropped (`out_of_order`); samples stamped more than 60 seconds ahead of the clock are refused (`future_time`).

## Measured cost


**10 000 series, 60 s interval, 24 hours (14.4 million samples):**

| | flush every 60 s | flush every 300 s |
|---|---|---|
| ingest (aggregator) | 0.5 us per sample, 5 ms of CPU per polling round | 0.35 us per sample (earlier format) |
| flush: mean / worst, per flush | 640 ms / 2.2 s for 12 300 rows | 1 035 ms / 2.3 s for 21 600 rows (earlier format) |
| flush time per simulated minute | **640 ms** (1.1 % of one core, in transactions of 500 rows) | **207 ms** (earlier format) |
| worst-case loss on a crash | 60 s plus the queue | 300 s plus the queue |

Disk after 24 hours (60 s flush, final format with the last-sample time in each bucket): raw 80 MB (8.0 KB per series per day, 5.5 bytes per
sample), 5-minute rollups 30.5 MB (3.0 KB per series per day), 1-hour rollups 2.9 MB (0.29 KB per series per day); chunk data 113 MB, SQLite
file 187 MB with its indexes and page overhead.
At the default retention that is, per 10 000 series: raw 24 h = 80 MB, 5m x 14 d = about 420 MB, 1h x 90 d = about 25 MB, so **about 0.5 GB of
chunk data in steady state** (the file is roughly 1.7 times that). Real fleets compress better than this test (flat counters, constant states).
Memory: 38 MB of heap for 10 000 series (the series registry and the open chunks); about 3.5 KB per series, which is what the default cap of
50 000 series is sized for (about 175 MB).

The write cost is dominated by SQLite upserts (about 17 to 50 microseconds per row, rising as the file grows); a longer flush interval writes
fewer rows per sample and lowers the cost at the price of a larger loss window. The default is 30 s.

**Queries** (10 000 series, one node, the 24-hour store above; they were 4 to 7 seconds before the chunk read was bounded by the primary key): the
fleet interface table over about 6 000 interface series 0.54 s, a top-10 by average rate over a 1-hour window 0.55 s, one counter over 24
hours at the automatic step 0.8 ms. The table and the ranking are not
cached; a UI that refreshes them should do so at a minute scale. With SQLite replicas each of them is a fan-out and slower.


## Not covered

- Rollups are not rebuilt from raw samples after a crash.
- Counters' min, max and mean are not kept in the rollups.
- Counter width does not reach the server from an edge collector (the width is set in process): edge-polled 32-bit counters read a wrap as a reset.
- A read counts a point once from the stored chunk and once from the open chunk in memory when both hold it (a limit of N reads about N/2 distinct points).
