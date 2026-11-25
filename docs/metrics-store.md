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
2. the **writer** wakes every `flush_seconds` (default 30) and writes what is new: finished chunks as chunk rows (upserts), and for an open
   chunk only the samples it gained since the previous flush, as insert-only tail rows (see "The write path and its WAL cost"), in
   transactions of at most 500 rows. A failed transaction puts its rows back for the next flush;
3. the **refresher** re-reads settings, retention and the series list every 30 s (and the last-sample times other nodes wrote), and every fifth minute does the full pass (see "Background steps");
4. the **fold loop** folds tail rows that no live writer will remove into chunk rows, on its own schedule (see "Background steps").

**Durability bound.** Open chunks live in memory, and their flushed part also in tail rows. A crash (or kill -9) loses the samples that were not yet flushed: at most
`flush_seconds` of data, plus whatever is still in the intake queue (a few seconds at the rates the queue is sized for); what was flushed is
kept (the node's fold loop folds its tail rows into chunk rows soon after it starts again). A clean
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
| `metric_chunk` | series, resolution, chunk, writer | a compressed block of samples (raw) or buckets (5m, 1h): a chunk as it was when it closed |
| `metric_tail` | group of 64 series, resolution, window, writer, flush | the samples (raw) or closed buckets (5m, 1h) that open chunks gained in one flush, insert-only (migration 0326) |
| `metric_tail_win` | writer, resolution, window | which windows a writer has tail rows in, so rows a dead writer left are found |

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
chunks are all gone and that has not been seen within the longest retention (in either of its two last-sample times) is removed too, with its
`metric_series_seen` row.

A resolution is **switched off** with its own store setting (`raw_enabled`, `rollup_5m_enabled`, `rollup_1h_enabled`, all on by default):
nothing is written at it, queries refuse it, and what is stored ages out by its retention.

`metric_chunk` is indexed on `(res, start_ms)`, not on the end time. A chunk row is rewritten while its chunk is open when the node writes
whole open chunks (`SESHAT_METRICS_OPEN_CHUNKS=rewrite`, the 0.10.0 write), and an index on a column that changes defeats PostgreSQL's
heap-only updates and bloats the index; the start time never changes. The table keeps 20 % free space per page (`fillfactor = 80`) so
those upserts can stay on their page (migration 0321).

### The write path and its WAL cost

A database that logs its writes pays for every row a flush writes. In 0.10.0 each flush upserted the **whole open chunk** of every series
that changed: a raw chunk is open for up to an hour, so its row was rewritten about 120 times at the default flush interval, each time with
all the samples so far, and on PostgreSQL every rewrite logs the whole row (and the first change of a page after a checkpoint logs the whole
page). The write is now:

1. **Open chunks: tail rows.** A flush appends to `metric_tail` only the samples (raw) or closed buckets (5m, 1h) a chunk gained since the
   previous flush. Rows are insert-only and never updated. One row holds the new samples of up to 64 series (series id / 64) that share a
   chunk window, so a flush of 20 000 series is a few hundred small rows, not 20 000, and the rows of one series stay close together for readers.
2. **Closed chunks: one chunk row.** When a chunk closes (its hour is over, it reached its size bound, or the node stops) its whole row is
   written to `metric_chunk`, exactly as before. Once every open chunk and every finished chunk of a window of this writer is written, the
   writer deletes its tail rows of that window in short transactions of their own. A chunk row is therefore written once per chunk; the tail
   rows exist for at most about an hour (a raw window), 6 hours (5m) or a day (1h).
3. **Readers merge.** A query, the fleet table and the latest-value reads (`DBHeads`) read the tail rows of the other writers together with
   the chunk rows and merge them by time per writer, so a sample that is in both (a chunk is closed and its tail rows are not yet deleted) is
   one sample. A tail row is committed in the flush that wrote it: the 30 s visibility of fresh samples, also to the other nodes, is unchanged.
4. **Crashes.** Tail rows are the flushed part of an open chunk. A node that died leaves them; when the same node starts again it folds the
   tail rows of its earlier runs into chunk rows (the chunk of that run is then what 0.10.0 would have left), and the leader does the same for
   any writer's windows that ended more than two hours ago. A chunk row is never replaced by one with fewer samples (no chunk write is, and a fold only adds). Tail rows that cannot be read (a
   format of a newer release) are left in place. A series whose chunk was dropped without being written (the database refused the series, or
   the pending list was full) has what it had flushed, and the rollup buckets it held in memory, folded into a chunk row before the window's tail
   rows are deleted; a series that is taken again inside the same window opens a chunk of its own, so both are read. Rows that could not be
   folded keep the window's registration, and the fold loop tries them again once the window has been over for two hours. Nothing is lost that
   0.10.0 would not have lost.
5. **Outages and fast sources.** A head remembers at most 256 samples (64 buckets) that are not in the database. When the database was away
   for longer, the next write of that head is its whole chunk, which covers them (the 0.10.0 write), so memory per series stays bounded. A
   source that delivers more than about 8 samples a second to one series (256 in a 30 s flush) overflows that bound at every flush and is
   written as a whole chunk each time: no saving for it, and no loss.
6. **Late samples.** A head whose window has ended waits until no sample was taken for it for two flush intervals (at most an hour) before
   its chunk is closed by the clock, so a device whose clock runs behind and keeps delivering samples of the window joins the same chunk.
   A sample stamped inside a window whose chunk this run has already closed (it arrived after that) is kept as a chunk of its own beside the closed one, and a chunk write never replaces a row that holds more samples; in
   0.10.0 it replaced the whole closed chunk with a one-sample chunk. Readers merge the chunks of a window by time (raw) or combine their
   buckets (5m, 1h).
7. **Latest values of series another node holds.** `DBHeads` reads, per batch of series (grouped by age of last sample and by id, so a
   batch touches a few groups), the tail rows of the last two flush intervals; a series that reports less often than that is read again
   from the tail rows of the last 45 minutes (polls up to 20 minutes apart; at most 10 000 such series per read). A series polled less often
   still shows its newest value from another node, without a rate.

Tail rows count in the disk estimate and are removed by retention like chunks (a window older than the retention cut). The SQLite-to-
PostgreSQL copy tool carries them. The code is the same on SQLite and PostgreSQL; on SQLite the saving is in bytes written to the file.

**What it costs.** `TestMeasureWALOfChunkWrites` writes synthetic counter series, one sample per
10 s each, flushed every 30 s, into a PostgreSQL for one steady-state hour (the close of the previous hour's chunks and their cleanup, and
the growth of the next hour's) and reads the WAL position before and after, with a checkpoint every five simulated minutes and a vacuum at
the end. For 20 000 series (checkpoint every 5 minutes, a vacuum at the end; `wal_compression` off):

| write | WAL per hour | per series and hour | rows written | full-page images |
|---|---|---|---|---|
| 0.10.0: whole open chunk at every flush | 2 810 MB | 140 KB | 2 660 000 | 105 000 |
| tail rows, series of a device sampled together | 178 MB | 8.9 KB | 61 000 | 10 500 |
| tail rows, every series sampled at its own instant | 215 MB | 10.8 KB | 61 000 | 13 700 |

That is 13 to 16 times less WAL for the chunk writes. The figures are from a synthetic load (rising counters, 20 000 series, one sample per
10 s each, flush every 30 s) on a throwaway PostgreSQL 16 and will differ with your data, sample rate and settings; run the test on your
own server to get yours (`TEST_WAL_DATABASE_URL`, `SESHAT_WAL_SERIES`, `SESHAT_WAL_TIMES`, `SESHAT_WAL_CHECKPOINT_FLUSHES`; see its comment).

Rows written fall by more than 40 times (a flush of 20 000 series is a few hundred rows), and the saving is larger when checkpoints are more
frequent, because a full-page image follows the first change of a page after each one and the tail rows are written to the end of the table
and to a few hot index pages.

**Last sample.** Each series has the time of its last sample (not the end of a chunk, which for a rollup is later). Other replicas and a
restart read it, and "stale", the idle state of a series and its revival derive from it, accurate to within a few minutes. It lives in
two places, and a reader takes the newer of the two:

- `metric_series_seen (series_id, last_ms)` (migration 0325) holds the frequent value: a narrow table with no index but its primary key and a
  fillfactor of 70, so on PostgreSQL the updates are heap-only (HOT) and write one small row version instead of every index of the wide series row.
- `metric_series.last_ms` holds a coarse value. It is written when the series row is created, when it is behind the series' last sample by
  the step below, and (because an idle series' stored time is days behind) in the first round after an idle series is revived. It stays indexed
  (`metric_series_last`, migration 0322) because the bounded start-up read orders by it, the retention test uses it, and nodes of the previous
  release read it; so it is kept rare, not removed. Dropping the index is a contract-shaped migration and waits for a release that no longer has to
  work next to 0.10.0.

Every `lastSeenEvery` (2 minutes) a node writes the series that changed, in batches, and at a clean stop. A node writes a series only when its own
time is at least 90 seconds ahead of what the database holds (a stop writes anything that is ahead), so the stored time is at most about 90 seconds
plus one round (3.5 minutes) behind the series' last sample. It reads the stored times of the batch just before writing (no locks, so no WAL): replicas
that all receive the same series therefore write it about once per interval between them instead of once each. The write itself is an `UPDATE`
that matches only rows that are behind (a row it does not change is not locked and logs nothing) and an `INSERT ... ON CONFLICT DO NOTHING` for a
series with no row yet; a series whose row another node's retention removed is skipped. The refresh selects the rows of both places changed in the
last 20 minutes; the narrow table is read without an index (it is small and read-only work), and the refresh also tells the node what is stored so it does
not write it again. There is no scan of the chunk table and no per-series work at start.

**The coarse step and a rolling upgrade from 0.10.0.** A 0.10.0 node reads only `metric_series.last_ms`, and calls a series stale after 10
minutes (`StaleAfter`). Every node of a cluster on a shared PostgreSQL therefore advertises the feature `metric_series_seen` in its heartbeat
(`cluster_nodes`, `features`); a node of 0.10.0 does not. The step of the coarse column follows what the cluster says:

| cluster (heartbeats newer than 5 minutes) | step of `metric_series.last_ms` |
|---|---|
| every node advertises the feature, or this is the only node, or SQLite | 1 hour |
| a node that does not advertise it is running (or membership cannot be read, until it has been read once) | 3 minutes |

The 3 minutes is chosen so that a live series never reads stale on an old node: 3 minutes of step + one write round (2) + the old node's refresh (30 s)
+ the old node's database-head re-read lag (150 s) is 8 minutes, under the 10 minutes of `StaleAfter`. During the mix the column is written about
every 3 minutes for a series that reports steadily (once between the replicas), so the write volume of that column falls from 3 nodes x every 2 minutes to
one write per 3 minutes, and falls to once an hour when the last 0.10.0 node is upgraded (within a refresh, 30 s, after its heartbeat is older than 5
minutes or it reports the feature). A series that was idle and reports again on a newer node is written to the column in its first round, so the old node
revives it within its 20-minute window. An old node does not read `metric_series_seen`, and its own writes keep updating `metric_series.last_ms`
as before (a newer node reads both). Rolling back (a 0.10.0 node joining a cluster of new nodes) can show live series as stale on that node for a few minutes, until the new nodes see its heartbeat (at their next refresh, 30 s) and catch the column up at the 3-minute step. A 0.10.0 node that has no heartbeat in `cluster_nodes` cannot be seen by the new ones: do not run one
beside new nodes without the cluster heartbeat (it is on by default).

### Caps and the disk budget

| setting | default | when exceeded |
|---|---|---|
| `max_series` | 50 000 | new series are refused |
| `max_series_per_device` | 5 000 | new series of that device are refused |
| `disk_budget_mb` | 4096 (0 = none, else at least 64) | the oldest chunks are deleted until under it, never the newest data; new series are refused meanwhile |
| `series_idle_days` | 7 | a series with no sample for this long leaves the series cap and the ingest state; it stays listed and queryable |
| `pending_mb` | 256 | the oldest unwritten chunks are dropped |
| `idle_heartbeat_seconds` | 75 (30 to 150) | an unchanging series is written at most this often; another replica sees a live idle port as current because of it (a value stays current for five minutes) |

A refused series is counted once per series, not once per sample (`refused_series_cap`, `refused_device_cap`, `refused_disk_budget`, and `admission.refused_priority_reserve` for series held back to keep room for state and core counters, see "What is admitted first";
Prometheus `seshat_metricstore_refused_series_total{cap}`), and `GET /api/metrics/status` carries a note and the time of the last
refusal. Existing series keep recording.

**Disk budget.** On PostgreSQL the figure is the live chunk data plus about 170 bytes of row and index overhead per row, plus the series table (never more than `pg_total_relation_size`): the table size itself is not used, because deleting rows does not shrink a PostgreSQL table, so a budget measured on it could never be met. Elsewhere the bytes of chunk data times 1.7
(1.68 measured on SQLite). It is taken every 5 minutes. When it is over the budget, the oldest raw chunks are deleted first, then 5-minute, then 1-hour
ones, 500 rows at a time with a short pause (at most about 100 000 rows per round; the rest at the next round), until it is under, and it stops (`trim_ineffective`) if a round does not reduce the measured size; the deletions are counted (`budget_deleted`). The newest data is **never**
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
with `"idle": true`, and `status` counts it as `idle_series`. The entry's last-sample time is the newer of the series row's `last_ms` and `metric_series_seen.last_ms`. A new sample **revives** it: it takes a slot like a new series (refused if a cap is reached), carries on
from the newest sample it has stored, and anything not newer than that is dropped as out of order, so the revived series cannot overlap its
history. A restart lists idle series again without counting them. When retention removes the last chunk and the series row, the entry goes.

Settings are changed with `PUT /api/metrics/settings` (administrators only, and not by a caller limited to a scope; audited) and take
effect on this node at once and on the others within 30 s.

### What is admitted first

A streaming router can send one series per ARP neighbour, route entry or MAC entry: thousands of series that no screen draws, arriving
before or among the interface counters and using up the per-device cap. Three rules keep the interface data.

**Table paths are left out by default.** A sample whose path (without list keys) matches the built-in list never becomes a series. The
built-in list is OpenConfig: the ARP and ND neighbour lists (`**/ipv4/neighbors/neighbor/**`, `**/ipv6/neighbors/neighbor/**`; the BGP
session list is not one of them), the forwarding tables (`**/afts/**`), the BGP routes (`**/bgp/rib/**`, `**/loc-rib/**`) and the MAC table
(`**/fdb/mac-table/**`). In a pattern `**` stands for any number of path segments, `*` for any run inside one segment, and a module
qualifier (`Vendor-model:name`) on a path segment is ignored unless the pattern has one. Only the metric store is filtered: the same
events still reach every destination a route sends them to, and Prometheus remote write, InfluxDB and OTLP see them as before.

| setting | default | meaning |
|---|---|---|
| `table_paths_exclude` | `true` | `false` stores table paths for every device (the built-in list and `table_paths_extra` are not applied) |
| `table_paths_extra` | `[]` | more path patterns to leave out (a vendor model with its own table) |
| `table_paths_keep_devices` | `[]` | device names whose table paths are stored |
| `table_paths_keep_inputs` | `[]` | telemetry input names (the target name, or `telemetry-dialout`) whose table paths are stored |

Patterns have no leading or trailing slash and no empty segment; a pattern of only `**` is refused (it would leave out everything).
A series that exists from before keeps its history and stays queryable, but it does not keep its slot: when the rule takes effect (a
settings change, or the first refresh after the upgrade) the table series that are now left out are idled at once, whatever their age,
their open chunks are finished and written, and a new sample revives one if the table paths are kept again. The input of a series is
known only after it has reported since the start, so while `table_paths_keep_inputs` is set a stored series of unknown input is
decided by its next sample.
`GET /api/metrics/status` shows `admission.excluded_table_samples` and the biggest `admission.excluded_paths`
(`seshat_metricstore_excluded_table_samples_total`).

**State and core interface counters come first.** A series is in one of three classes: *state_core* (every state series, and on an
interface oper and admin status, speed (`high-speed`, `lag-speed`, port speed), octets, packets, errors and discards in both
directions; also the same counters of a few vendor models that are not OpenConfig: Junos `/junos/system/linecard/interface/` and the
Cisco IOS XR `infra-statsd` generic counters), *interface* (every other series directly under `interfaces/interface/`) and *other* (the rest, including what hangs under a
logical unit, such as an ARP entry or an address). On PostgreSQL the caps and so the reserve count series the same way as the caps do (see "Caps"). `core_priority_pct` (default 20, 0 to 50, 0 switches it off) keeps that share of
`max_series` and of `max_series_per_device` for the class before: *other* series stop being admitted when the device or the store is
within that share of the cap, *interface* series within half of it, state and core counters until the cap. With the default 5 000
series per device that is 4 000 for *other*, 4 500 for *interface* and 5 000 for state and core.

**Interface series are kept or cut by whole interface.** An interface that has a series in the store (its status, say) is completed up
to the cap. A new interface whose first non-core series does not fit is marked cut: its other series are refused, one by one, instead of
leaving half an interface; its state and core counters are still admitted. Existing series are never evicted, so the order matters
only for series that arrive after the cap is near.

**Scope of the counts.** The reserve and the idling of left-out series use the same counts as `max_series` and `max_series_per_device`
(`series_cap_scope` in the status): on PostgreSQL every replica reads the one shared series list, so the reserve is a share of the
merged count of all replicas and each replica applies the table rules to the shared list itself (at its refresh, within about 30 s of a
settings change and at once when it reports a left-out sample); on SQLite each node counts its own file. `refusing_reason` in the
status also says `priority_reserve` (the active count is within the reserve: only state and core counters are admitted), after
`disk_budget` and `series_cap`; `refusing_new_series` and its Prometheus gauge are true for those three only. Table paths left out are
intended behaviour, not a refusal: `admission.excluded_table_samples` (all time), `admission.excluded_table_samples_10m` and
`admission.excluded_paths` report them.

What was refused and why is in `GET /api/metrics/status` under `admission`: `refused_by_class` (`state_core`, `interface`, `other`),
`refused_priority_reserve`, and `devices`, the devices that lost the most with their series by class and by reason (`series_cap`,
`device_cap`, `disk_budget`, `priority_reserve`, `interface_cut`). Each series is counted once, when it is first refused. Prometheus:
`seshat_metricstore_refused_series_total{cap="priority_reserve"}`. The report holds at most 500 devices and 200 table paths; `untracked`
counts the rest.

### Internal interfaces

A router lists interfaces that are not ports: tunnels, packet-forwarding and line-card links and other pseudo interfaces. They are
stored when admitted, but the interface table (`GET /api/metrics/interfaces`) and the interface totals of the device views
(`interfaces_total`, `_up`, `_down`, ... in `GET /api/metrics/devices` and `.../devices/{device}`) leave them out by default; the answers
say how many in `hidden_internal` and `interfaces_internal_hidden`. The built-in list matches the name before the first `.` (the
logical unit) and covers Junos `fti*`, `pimd`, `pime`, `vtep`, `esi`, `pfe-*`, `pfh-*`, `lc-*`, `lsi`, `dsc`, `mtun`, `cbp0`, `demux0`,
`bme0`, `jsrv`, `rbeb` and the Cisco `Null*`. `gre`, `ipip`, `tap` and `pp0` are not on it, because they can carry real traffic.
The match is on the name alone (the store does not know a device's vendor); `xe-0/0/0`, `ae0`, `lo0`, `irb` and `em0` are not
matched. An interface that shows traffic in the current window (a fresh rate above zero) is never hidden, whatever its name.
Add patterns (`*` is any run of characters, `?` one) with `internal_interface_extra`, and names that are never hidden with
`internal_interface_keep`. To show them all: `show_internal_interfaces: true` in the settings (everyone), or `include_internal=1` on the
interfaces, devices and device requests.

### Telemetry paths

The telemetry input gives every leaf one canonical path, the form the SNMP and sFlow collectors use for the shared interface metrics
(`/interfaces/interface[name=X]/...`). A stream that sends `interface[name=ae0]/aggregation/state/lag-speed` (the `interfaces/`
container missing, from a prefix or a sensor) and one that sends `interfaces/interface[name=ae0]/aggregation/state/lag-speed` are one
series, and an `openconfig-interfaces:` qualifier on the first element is dropped. Only interface paths are rewritten: the first element is
`interface` and the element after its keys is an OpenConfig interface child (`state`, `config`, `aggregation`, `ethernet`,
`subinterfaces`, `hold-time`, ...). Every other path (other models, other `openconfig-*:` qualifiers, a vendor's own `interface[...]/statistics/...`)
reaches routes and the store exactly as the device sent it. The metric store applies the same rule when it reads an event, so older
sources are covered too. History already stored under the path without `interfaces/` stays queryable under it; its series are idled
at the upgrade and new samples go to the canonical path, so a query or an alert rule written against the old path must be changed.

### Defaults on a shared database

When the history lives in the application database on PostgreSQL, every replica and the rest of the application share it, so a fresh
install starts lighter than on SQLite: `max_series` 20 000, `max_series_per_device` 2 000, `disk_budget_mb` 1024, `flush_seconds` 60 and
`pending_mb` 128 (SQLite: 50 000, 5 000, 4096, 30, 256). Only a store that holds no metric history yet gets them; an install that upgraded with data and has no saved settings keeps the
previous defaults (they are saved at first start). Settings you save are never changed, and `PUT` saves only the fields you send; raise them with
`PUT /api/metrics/settings` when the database can take it (`GET /api/metrics/settings` returns the `defaults` for this backend).
`max_series` on PostgreSQL is a cap on the **shared** list: every node reads the one list, so `series` in the status is the count over all
replicas, and a node's own part is `series_this_node`. On SQLite each node has a file of its own and the cap is per node
(`series_cap_scope` says which). A count above the cap (a lowered cap, or several nodes admitting at once) is reported as `series_over_cap`;
only new series are refused.

**WAL, backups and checkpoints on PostgreSQL.** Whatever the store writes is logged by the server, and a shared server's backups and WAL
archive carry that volume together with the rest of the application's. With the tail write the store's chunk writes cost about
9 to 11 KB (140 KB with the 0.10.0 write) of WAL per series per hour at the default flush interval (one sample per 10 s, measured on synthetic counters; a
series with a sample every second costs more, a flat one less). 20 000 series are about 0.2 GB of WAL per hour, 4 to 5 GB
per day, before the rest of the application. Size the server for it:

- **`max_wal_size`**: a checkpoint is forced when this much WAL has accumulated. With the default (1 GB) a busy server checkpoints every few
  seconds to minutes, and every checkpoint makes the next change of each page a full-page image (8 KB for a change of a few bytes), which
  is most of the WAL of a store that touches many rows. Set it to several times the WAL the server writes between two timed checkpoints
  (for example 8 to 16 GB) so that checkpoints are timed, not forced; the log line `checkpoints are occurring too frequently` and
  `pg_stat_bgwriter.checkpoints_req` growing faster than `checkpoints_timed` say it is too small.
- **`checkpoint_timeout`**: 15 minutes is a good value for this load (default 5 minutes). A longer interval means fewer full-page images and a
  longer crash recovery.
- **`wal_compression`**: `on`, or `lz4` or `zstd` where the server has them. It compresses the full-page images that remain, at a small CPU cost.
- A **WAL archive** or a replica receives every byte: check the archive's space and the replica's link before enabling the store on a large
  fleet, and watch `pg_wal` and the archive for the first days. The disk budget limits what the store keeps in its tables, not the WAL it
  writes, and retention's deletes are logged too.

### How a flush keeps up

A flush writes the finished chunks first, then the new samples of the open ones (tail rows), in transactions of at most 500 rows or 2 MB, several rows per statement.
Each transaction has its own timeout (a quarter of the flush interval, 2 to 20 s) and a flush starts no new transaction after 70 % of the
interval. Whatever is left is carried to the next flush, which starts where this one stopped; nothing is retried as a whole. If a
transaction fails or times out the flush stops there (one `flush_errors`), the store backs off (5 s doubling to 5 min) and the rest
waits. Flush start times and back-offs are jittered so replicas do not write together. The status shows how it is going under `flush`:
`last_duration_ms`, `rows_per_second`, `backlog_rows` (planned and not written by the last flush), `pending_chunks`, `behind_streak`;
three flushes in a row with a backlog make the store `degraded` (`flush_behind`), a failing one `flush_failing`. Data waiting is held in memory
(bounded by `pending_mb`), and this node answers queries from it; other replicas see it when it is written.

**Unchanging series.** A series whose value does not change (an idle port's counter at 0, a constant gauge) is not rewritten at every
flush: it is written when its value changes, when its chunk is finished, and at most every `idle_heartbeat_seconds` (75) otherwise, and the
chunk stores its values as runs when that is smaller. Every sample keeps its exact time and value, so a query returns the same points
whether or not the series was compacted, and a rate over a flat counter is 0. A crash loses, for such a series, at most the repeats since the
last write; another replica's view of it can be up to the heartbeat behind.

**Raw window.** When the disk budget trims, the oldest raw chunks go first, so raw history can be shorter than `metric_raw_hours`.
`raw_window` in the status gives the configured hours and the age of the oldest raw chunk actually on disk (`short` when the store is old
enough to hold more), and queries use the rollups for older ranges.

**PostgreSQL space.** Deleting chunks (retention, the disk budget) leaves free space inside the tables; PostgreSQL reuses it for new rows, but
returns it to the operating system only after `VACUUM FULL` (which locks the table) or `pg_repack`. Autovacuum keeps the size steady, not smaller;
the budget therefore limits the size the tables settle at. The chunk table keeps 20 % free space per page for in-place updates. Trimming is done in batches of 500
rows with one statement each; partitioning the chunk table by time (so old data is dropped with `DROP TABLE`) is not done.

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
  not-present nor administratively down ports (`interfaces_admin_down`, `interfaces_other`, `interfaces_unknown`). Status unknown (4), a status
  sample that is not current, and an interface that has counters but no status series at all are all counted in `interfaces_unknown` (an interface's status and counter series are matched by their `ifindex` label when they carry one, else by name),
  so up, down, admin down, other and unknown add up to `interfaces_total`. An interface row says what its state rests on (`oper_basis`:
  `reported`, `stale` or `none`) and whether it carries traffic (`carrying_traffic`), so an unknown port that is passing traffic reads
  differently from an idle one.
- **Interface order.** Names sort naturally (digit runs compare as numbers, letters without regard to case, case-only differences tie-broken for a stable order): `ethernet1/1/10`, `ethernet1/1/10:1`, `ethernet1/1/100`.
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
  `top` answers "busiest interfaces" and "most errors" for the same data. Internal router interfaces (`fti0`, `pfe-0/0/0`, ...) are left out
  unless `include_internal=1` is sent (see "Internal interfaces").
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
  - Freshness: a replica learns that a series received elsewhere is alive from the series' last-sample time (written every 2 minutes, see
    above), so "stale" on the device views is right to within a few minutes. New series rows are found by an incremental refresh that looks
    back 5 000 ids from the highest seen (PostgreSQL can commit a lower id after a higher one), and a full reload every 5 minutes.
  - Known limits: a series that two replicas both received is deduplicated sample by sample; the ranking and table views transfer the
    samples of the lookback window for the series they scan (a few KiB per series), so on a large fleet the fan-out makes them slower than on
    one node; the status endpoint describes this node only.

## Background steps

The store's background work is a list of steps, and **every step has a deadline of its own**. A step that runs out of it is cut off, named in
the log with how long it took and how long it was given (`metric store: a background step ran out of its own time`, at most once in five
minutes per step), counted, and takes nothing from the steps after it: the next round does it again, or carries on where it stopped.
Before 0.11.3 one refresh had one minute for all of its steps, so on a store of a few hundred thousand series the last of them, the
last-sample read, found the minute spent by the fold and the full series read (`metric last seen: context deadline exceeded`).

| step | what | budget | when |
|---|---|---|---|
| `settings` | settings and retention | 20 s | every refresh (30 s) |
| `series` | the series list: the rows newer than the highest id seen, or every ten rounds (about five minutes) the whole list | 90 s (5 min for the first read after the start) | every refresh |
| `cluster` | the cluster's nodes (the step of the coarse last-sample column) | 15 s | every refresh |
| `last_seen` | the last-sample times other nodes wrote | 45 s | every refresh |
| `disk` | the disk estimate: on a shared PostgreSQL only the leader measures, from a page sample (see below); the others take its figure | 45 s | full pass |
| `budget` | trimming for the disk budget (leader on a shared database) | 90 s | full pass |
| `coverage` | the oldest chunk per resolution | 45 s | full pass |
| `fold` | one pass of the fold loop | 90 s (soft stop at 30 s) | its own loop |

**The disk estimate** used to be a full `SUM(LENGTH(data))` over the chunk and tail tables on every replica every five minutes. On a shared
PostgreSQL only the leader measures now. For a table of more than 8000 pages (64 MB) it reads a sample of about 4000 pages
(`TABLESAMPLE SYSTEM`) and scales the sums up (within a few percent; smaller tables are read whole), and it publishes the figure in the
setting `metricstore.disk`, which the other replicas take (up to 30 minutes old). The full scan is left to what must be exact: after
trimming for the budget the deletions have to show in the measure, so it is made whole then. A replica that has no fresh figure keeps its
last one. Until a replica has taken the first figure (a replica that has just started, or a cluster with no leader yet) its estimate is 0, so the disk
budget does not refuse new series on it; the series cap still does, and the figure arrives within one full pass of the leader's publishing. The setting row
`metricstore.disk` (JSON: `used`, `data`, `at_ms`) is the only new stored row; a node of an earlier release ignores it. SQLite has a file per node and no election and measures locally as before. `seshat_metricstore_disk_measure_total{how}` counts
`scan`, `estimate` (sampled) and `adopted`. Budget enforcement is unchanged: new series are refused at the budget, and only the leader trims.

**The fold is not part of the refresh.** It runs in a loop of its own: a pass right after the start, then one every two minutes, and while a
backlog remains a pass every two seconds. A pass folds the tail rows of this node's earlier runs, and (on the leader of a shared database)
those of any writer's windows that ended more than two hours ago, as before, and it works in slices of 4000 rows, each its own transaction
that also deletes the rows it folded. After 30 s a pass starts no new slice; it ends, and the next one carries on from the rows that
remain. A backlog of hundreds of thousands of tail rows left by a restart is therefore worked off steadily, in the background, without
holding the refresh or the flush, and a pass that is cut off loses nothing. Readers merge tail rows as they are while they wait.

**Bounds are per call, and the stream's cap is one.** A bound on a wait for the database applies to one call; what keeps a run of calls (the
records of one request) from waiting once per call is the backoff after the first wait that ran out (the owner resolver and the owner check
of metric samples: 5 s). The only cap on a whole stream request is the poll budget (see docs/edge.md).

**Locks.** The loops over the whole series list (merging the full read, the sweeps that idle excluded series or move old ones to the idle
list, ranking and trimming the idle list, the last-sample merge) take the series lock a chunk of 2048 series at a time and let go in
between; the full read and the ranking of the idle list are done before the lock is taken. A sample waits for the lock for one chunk, not for
the pass. (Measured on 200 000 series: the longest wait of a sample during a full refresh fell from about 75-85 ms to about 20 ms; the
flush's planning scan, about 15 ms, is the rest.) Handing a metric event to the store never waits for any of this: `Accept` puts it in the
bounded queue and returns; a full queue drops the event and counts it (`seshat_metricstore_queue_dropped_total`).

Status (`GET /api/metrics/status`) lists the steps under `steps` (runs, overruns, failures, budget, last and longest duration). Prometheus:
`seshat_metricstore_step_runs_total`, `_step_overruns_total`, `_step_failures_total`, `_step_seconds_total`, `_step_last_seconds` and
`_step_max_seconds`, each with a `step` label.

## Monitoring the store

`seshat_metricstore_samples_total`, `_queue_dropped_total`, `_refused_series_total{cap}`, `_out_of_order_total`, `_flush_errors_total`,
`_rows_written_total`, `_bytes_written_total`, `_series`, `_queue_length`, `_last_flush_seconds`, `_disk_bytes` (estimate), `_quarantined_total`, `_pending_dropped_total`, `_decode_errors_total`, and the step timings above. Samples that are not newer than the
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
