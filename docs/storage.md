# Storage and clustering

Seshat keeps configuration, users, sessions, branding, routes and destinations, the device knowledge
base, the inboxes, flow templates and the audit log in a database. Event data never goes through it:
outbound queues live on local disk.

## Choosing a backend

| | SQLite (default) | PostgreSQL 16+ |
|---|---|---|
| Set with | nothing (`$SESHAT_DATA_DIR/seshat.db`) | `SESHAT_DATABASE_URL=postgres://...` |
| Replicas | one per database file. Several SQLite nodes replicate settings and device records over the peer link ([`ha.md`](ha.md)) but do not share one database | any number share one database |
| Change fan-out | in-process only | LISTEN/NOTIFY with a polling fallback |
| Leader | this process, always | advisory lock, one leader per cluster |
| Offline tolerance | not applicable (local file) | memory + write journal while the database is down |
| Use it for | one box, appliance, VM cluster with config sync | Kubernetes, shared state, HA |

Switch later with the copy tool (below). Migrations are embedded and run at start, once per cluster.

## PostgreSQL requirements

- PostgreSQL 16 or newer (17 is what the tests run against).
- A database and a role of your own, see [Roles](#roles-and-tls). Seshat uses its own schema.
- A **direct** connection for change notifications. Seshat opens one extra dedicated connection per
  replica for `LISTEN` and one for leader election, besides the main pool (at least 8 connections, more on hosts
  with more than 8 CPUs) and two helper pools of 2. Budget at least 14 connections per replica, and see
  [Connection budget](#connection-budget) to cap the main pool.
- **PgBouncer**: in `session` pooling mode everything works. In `transaction` or `statement` pooling
  mode `LISTEN` silently never delivers and a session advisory lock is released as soon as the
  transaction ends, which would give every replica leadership. Do not put the election or notification
  connections behind transaction pooling. Either point `SESHAT_DATABASE_URL` at PostgreSQL directly, or
  give Seshat a session-mode PgBouncer database. If `LISTEN` cannot be established Seshat falls back to
  polling by itself (see below), but the leader election has no fallback: use a direct connection.
- Time: replicas compare nothing by wall clock except the lease display; NTP is still good hygiene.

### Connection budget

Per replica, Seshat holds at most:

| Connections | Used for |
|-------------|----------|
| main pool: N | queries and writes |
| 1 | the dedicated `LISTEN` session (change notifications) |
| 1 | the leader-election session |
| 2 x 2 | the helper pools of the notifier and the elector |

N is the larger of 8 and the pool cap. Without a cap the pool grows with the CPU count, so a few replicas
on large nodes can exhaust the `max_connections` of a shared server. Cap it with `SESHAT_DATABASE_MAX_CONNS`
(Helm: `database.maxConns`) or with `pool_max_conns` in the URL. The setting wins when both are present. A URL
value below 8 is raised to 8; `SESHAT_DATABASE_MAX_CONNS` below 8 is refused at start.

With a cap of 8 a replica uses at most 8 + 1 + 1 + 4 = 14 connections, so three replicas need 42, plus
what `psql` sessions, monitoring and other applications use. Keep `max_connections` comfortably above that.

The other `pool_*` URL parameters (`pool_min_conns`, `pool_min_idle_conns`, `pool_max_conn_lifetime`,
`pool_max_conn_lifetime_jitter`, `pool_max_conn_idle_time`, `pool_health_check_period`, `pool_ping_timeout`)
apply to the main pool only. The `LISTEN` and election sessions are single connections and ignore them;
they are never sent to the server. Version 0.2.0 and earlier sent them, and PostgreSQL then refused
the connection (`unrecognized configuration parameter "pool_max_conns"`), which left every replica without a
leader and on 2 s polling.

## Change fan-out

Every successful write announces itself on a named channel; every replica subscribes and refreshes
its in-memory copy without a restart.

| Channel | Published when | Subscriber refreshes |
|---|---|---|
| `settings` | any setting changes (payload: the keys) | syslog / flow / SNMP input settings, connectors, branding values used by formatters |
| `outputs` | route or destination created, changed, deleted | router and destinations (atomic swap; unchanged destinations keep running) |
| `kb` | device records upserted or deleted (debounced 200 ms, ids batched) | the named records, adopted only when newer; never written back |
| `flow_templates` | NetFlow v9 / IPFIX templates persisted | templates of exporters this replica has not heard from yet (failover: the sender arrives with its templates known) |
| `snmp_users` | SNMPv3 user or engine ID changed | the trap listener's USM parameters |
| `mib` | MIB upload or delete | recompiles the MIB tree from the local directories |

**Transport.** PostgreSQL `LISTEN/NOTIFY` on one dedicated connection (`seshat_<hash of schema>`
channel, payload at most 6000 bytes; larger payloads are read from the change feed table). Every
notification is also a row of `store_changes`. If `LISTEN` cannot be established, or the connection
drops, the replica **polls `store_changes` every 2 s** until `LISTEN` is back, and runs a full refresh
of every channel whenever it switches transport so nothing is missed. `SESHAT_STORE_LISTEN=off` forces
polling. Typical latency: well under a second with `LISTEN`, up to about 2 s when polling.
The leader prunes feed rows older than one hour.

A replica ignores notifications it published itself (it already applied the change). Writers apply
their own change locally first; the notification is for the others.

Limits worth knowing:
- KB conflict handling is record level, the newest `updated_at` wins. Per-field last-writer-wins
  merging is part of cluster sync.
- Uploaded MIB files live in each replica's `SESHAT_DATA_DIR/mibs`; the `mib` notification recompiles
  from local files. Share that directory (a volume) or upload to each replica.
- A deleted KB record is removed on the other replicas unless that replica has an unwritten local
  change for it. Deletions missed during a long outage are not replayed (stubs expire on their own).

## Leader election and singleton jobs

One replica per cluster is the leader. PostgreSQL: a session advisory lock on a dedicated direct
connection, retried every 5 s by followers. If the leader's connection ends the lock is released and the
replica **steps down at once**; another replica takes the lock within about 5 s. Each takeover increments
a **fencing token** stored with a lease (`until`) in the `leader` table. A singleton job calls
`Check(token)` before it writes and is refused when a newer leader exists. SQLite: always the leader.

`GET /api/cluster/leader` (admin or operator) shows this replica, who leads, the token and the lease.
`seshat_cluster_leader{instance}` is 1 on the leader. `SESHAT_LEADER_ELECTOR=k8s-lease` (what the Helm chart sets with `leaderElection.mode=k8s-lease`) replaces the
advisory lock with a Kubernetes Lease behind the same election interface; the fencing
token is then the Lease's `leaseTransitions`. SQLite ignores it (every replica leads its own database).

The Device Tracker settings (`tracker.settings`) follow the same change fan-out as the other settings.
The tracker's watch list and approved list are refreshed by every replica once a minute (a change made
on one replica is applied there at once and on the others within about a minute).

Jobs that run on the leader only:
- expired session sweep (hourly)
- retention (hourly, see below)
- change feed pruning (every 10 minutes)
- the **device index publisher**: each `seshat.device` event is emitted once per cluster. The leader also
  emits for changes it adopts from other replicas.

Jobs that deliberately stay on every replica: the unknown-OID, unknown-IE and syslog-template inbox
flushes (each replica holds its own counts and adds them to the stored totals), KB write-through, and
learning from the senders a replica itself receives. The KB has no periodic scheduler on a single node
either; when one is added it should use `leader.Run`.

## Offline tolerance

When PostgreSQL is unreachable a replica **keeps working from memory**: lookups, enrichment, routing and
delivery do not use the database. It:

- serves settings, sessions and users from a last-known-good cache (a cached session is honoured until it
  expires; a session revoked elsewhere during the outage stays valid on this replica until it recovers);
- buffers the writes the pipeline produces (KB records, inbox counters, flow templates, audit rows,
  settings) in a bounded in-memory journal, `SESHAT_STORE_OFFLINE_JOURNAL_MAX` (default 10000). When full
  the **oldest** entries are dropped and counted (`seshat_store_journal_dropped_total`);
- replays the journal **in order** as soon as the database answers (checked every 2 s), then publishes
  the changes to the other replicas;
- refuses interactive administration that needs an immediate answer (creating users, routes,
  destinations, SNMPv3 users) with the underlying error.

`GET /api/ready` reports `"store":"degraded"` and answers **200** by default so the replica keeps its
traffic; set `SESHAT_STORE_DEGRADED_STATUS=503` to have a load balancer drain it instead. The UI shows a
banner on every page. Gauges: `seshat_store_degraded`, `seshat_store_journal_depth`.

A replica needs the database to **start** (migrations, loading the KB). The journal lives in memory: a
restart during an outage loses it.

## Outbound queues and the shared message bus

| State | Where | Survives a pod restart if |
|---|---|---|
| Configuration, users, device KB, routes, destinations | the database: SQLite in `/data`, or PostgreSQL (`SESHAT_DATABASE_URL`) | `/data` is persistent (SQLite) or the database is external (PostgreSQL) |
| Outbound queues | `/data/queue/<destination>/` on the replica that received the events (docs/outputs.md "The queue directory") | `/data` is persistent. A replica that is down cannot deliver its queue |
| Outbound queues with the shared bus | on the bus (NATS JetStream or Kafka), readable by every replica; plus the local write-ahead queue in mode `hybrid`, or the local fallback queue in mode `only` | the bus is; the local part follows `/data` |
| Event data | never in the database | |

By default every replica needs its own persistent `/data` (in Kubernetes a StatefulSet with a
PersistentVolumeClaim per pod, the Helm chart's default); while a pod is down, the events queued on its
volume wait for it. The optional message bus (docs/outputs.md "Shared message bus") removes that limit:
replicas publish to NATS JetStream or Kafka and **every** replica delivers every destination, so a dead
replica's backlog is drained by the others and `/data` can be an `emptyDir`.

Requirements for stateless pods: PostgreSQL for the database (SQLite lives in `/data`), the bus in mode
`only`, and `SESHAT_DATA_EPHEMERAL=1`. The Helm chart does all three from its values:

```yaml
database: {mode: external, external: {existingSecret: seshat-db}}
queue:
  bus:
    enabled: true
    existingSecret: seshat-bus   # a Secret with key SESHAT_QUEUE_BUS_URL (nats://... or kafka://...)
    mode: ""                     # "" renders `only`; hybrid keeps a local write-ahead queue
```

`queue.bus.*` sets `SESHAT_QUEUE_BUS_URL` and `SESHAT_QUEUE_BUS_MODE`; `SESHAT_DATA_EPHEMERAL=1` is set
whenever `/data` is an emptyDir (`persistence.enabled: false`, or the bus on). Without a bus behind it, an
ephemeral `/data` makes the process log an error at start and `GET /api/queue` report the warning: queued
events are lost with the pod.

In mode `only` the local queue is used only while the bus is unreachable; give the pod a
`terminationGracePeriodSeconds` long enough for the intake to flush, and alert on
`seshat_bus_state{state="down"}` and `seshat_output_queue_depth` growing, because that is the data an
ephemeral `/data` would lose.

## Migrations

Run at start under the advisory lock `seshat_migrate`; the applied versions are read after the lock is
taken, so a second replica that was waiting finds nothing left to do. Roll out a new version by starting
one replica (or the Helm pre-upgrade Job) first. Migrations are only ever appended.

## Copy tool

```
seshat store copy --from <sqlite file|dir|postgres url> --to <postgres url|sqlite file> [--dry-run] [--force-empty-check=false]
```

Copies every table in dependency order in **one transaction** on the target, preserving ids and
timestamps (identity sequences are advanced), refuses a non-empty target unless
`--force-empty-check=false`, then compares row counts per table and prints a report. Exit code 0 only if
every table matches. `--dry-run` counts and checks the target schema and writes nothing. Either
direction works. Stop Seshat first (a running process keeps writing to the source), then start it
against the target.

```
seshat store copy --from /data/seshat.db --to 'postgres://seshat_app:...@db:5432/seshat?sslmode=verify-full'
seshat store copy --from 'postgres://...' --to /data/seshat.db      # the reverse
```

The source database is opened with the normal migrations, so a PostgreSQL source is brought to the
current schema first. The change feed and the leader lease are not copied.

## Retention

The leader deletes, hourly, with these defaults (`0` keeps that kind forever):

| Setting | Default | Deletes |
|---|---|---|
| `audit_days` | 365 | audit log rows older than N days; `0` or at least 30 (a shorter value is rejected) |
| `unknown_muted_days` | 30 | muted rows of the unknown-OID, unknown-IE and syslog-template inboxes, N days after they were muted |
| `syslog_template_days` | 90 | unmuted syslog templates not seen for N days |
| `flow_template_days` | 30 | persisted NetFlow v9 / IPFIX templates their exporter has not refreshed for N days (a live exporter's templates are re-stamped daily) |
| `tracker_interval_days` | 180 | closed Device Tracker intervals (location, L3, wireless, user; open intervals are never removed) |

`GET /api/retention`, `PUT /api/retention` (partial update), `POST /api/retention/preview` (counts what the
stored policy, or the policy in the body, would delete; deletes nothing). Settings > Storage shows the
policy, the preview and the last run. A run that deletes rows leaves an audit entry.

## Roles and TLS

`deploy/postgres/roles.sql` creates two roles, idempotently:

- `seshat_app` owns the `seshat` schema (and `tracker_public`, where the tracker views live); no
  superuser, no role/database creation, no replication, no RLS bypass. This is the role in
  `SESHAT_DATABASE_URL`.
- `seshat_readonly` for the portal and other readers: `USAGE` on `tracker_public` and `SELECT` on what
  is in it (now and later), nothing in the `seshat` schema (no users, sessions, settings), read-only
  transactions by default, short statement and idle timeouts.

```
psql "$ADMIN_URL" -v ON_ERROR_STOP=1 -v app_password="$APP_PW" -v ro_password="$RO_PW" -f deploy/postgres/roles.sql
psql "postgres://seshat_readonly:...@db:5432/seshat?sslmode=verify-full" -f deploy/postgres/verify.sql   # every check prints PASS
```

TLS: use `sslmode=verify-full` and the CA that signed the server certificate, never `disable` or
`require` outside a lab:

```
SESHAT_DATABASE_URL=postgres://seshat_app:...@db.example.com:5432/seshat?sslmode=verify-full&sslrootcert=/data/tls/db-ca.pem
```

`verify-full` checks the certificate chain and that the host name matches. The notification and
election connections use the same URL, so they get the same TLS settings.

## Trying it on one host

```
docker compose -f compose.yaml -f compose.postgres.yaml -f compose.replicas.yaml up -d --build
```

Replica 1 is `:8080`, replica 2 is `:8081`; both use the same PostgreSQL. Set `SESHAT_DEV=0` and the same
`SESHAT_SECRET_KEY` in `.env` first. Change something on one and watch it appear on the other
(Settings > Storage shows the transport and the leader). `docker compose stop postgres` degrades both;
`start` replays the journals.

## API and metrics

`GET /api/storage` (admin), `GET /api/cluster/leader`, `GET/PUT /api/retention`,
`POST /api/retention/preview`, `/api/ready`. Metrics: `seshat_cluster_leader{instance}`,
`seshat_store_degraded`, `seshat_store_journal_depth`, `seshat_store_journal_dropped_total`,
`seshat_store_listen_up`, `seshat_store_changefeed_polling`, `seshat_store_notify_publish_errors_total`,
`seshat_store_notify_dropped_total`, `seshat_store_pool_*`.
