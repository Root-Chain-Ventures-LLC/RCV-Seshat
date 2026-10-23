# Kubernetes (Helm chart, high-availability mode 4)

The chart in `deploy/helm/seshat` runs Seshat on Kubernetes 1.27 or later, optionally with the
Device Tracker portal. It is **mode 4** of `docs/ha.md`: an external load balancer (MetalLB, a cloud
network load balancer, IPVS) spreads senders over the pods, and the **source address of every
datagram must reach the pod unchanged**, because Seshat identifies a device by it.

```
devices ──► LoadBalancer Service (externalTrafficPolicy: Local) ──► StatefulSet "seshat" (N pods, own PVC each)
                                                                     │  /api/health  liveness
browsers ─► Ingress ─► ClusterIP Service ───────────────────────────►│  /api/ready   readiness (503 while draining)
                                                                     └─► PostgreSQL (shared: config, KB, leader lock)
```

The chart never creates Secrets, certificates, the database or the load balancer's address pool;
you hand it the names of Secrets that already exist.

## What you need

- A Kubernetes cluster, a way to give a Service a stable external address (MetalLB on bare metal,
  the cloud provider's load balancer), and a StorageClass for the per-pod queue volumes.
- PostgreSQL 16 or later for more than one replica. Either one you run, or CloudNativePG
  (`deploy/k8s/examples/cloudnativepg/`). Without PostgreSQL the chart runs one pod on SQLite.
- The Seshat image, `ghcr.io/root-chain-ventures-llc/seshat`, and for the portal
  `ghcr.io/root-chain-ventures-llc/seshat-device-tracker` (the chart pulls them by default; mirror them into your own
  registry if the cluster cannot reach ghcr.io).

## Install

```sh
kubectl create namespace seshat
kubectl -n seshat create secret generic seshat \
  --from-literal=SESHAT_SECRET_KEY="$(openssl rand -hex 32)"
kubectl -n seshat create secret generic seshat-db \
  --from-literal=SESHAT_DATABASE_URL='postgres://seshat:CHANGE_ME@db.example.com:5432/seshat?sslmode=verify-full'

helm -n seshat install seshat deploy/helm/seshat -f values.yaml
```

`SESHAT_SECRET_KEY` encrypts the stored destination credentials: **keep it** (and back it up) across
upgrades and restores; a different key makes them unreadable.

`values.yaml` for a three-pod install behind MetalLB (the address pool is
`deploy/k8s/examples/metallb/bgp.yaml` or `l2.yaml`):

```yaml
image: {repository: registry.example.com/seshat, tag: "0.1.0"}
secrets: {existingSecret: seshat}
database:
  mode: external
  external: {existingSecret: seshat-db}
replicaCount: 3
topologySpread: {whenUnsatisfiable: DoNotSchedule}   # one pod per receiving node, a hard rule
intake:
  service:
    loadBalancerIP: 192.0.2.10
    annotations: {metallb.io/address-pool: telemetry}
  sourceIPCheck: {snatCIDRs: [198.51.100.0/24]}       # your node subnet(s)
ui:
  publicURL: https://seshat.example.com
  ingress:
    enabled: true
    className: nginx
    hosts: [{host: seshat.example.com, paths: [{path: /}]}]
    tls: [{secretName: seshat-tls, hosts: [seshat.example.com]}]   # an existing kubernetes.io/tls Secret
```

Then create the first administrator in the browser. Point devices at the LoadBalancer address:
162/udp traps, 514/udp+tcp syslog, 2055/udp NetFlow, 4739/udp IPFIX, 6343/udp sFlow, 57400/tcp streaming-telemetry dial-out (Cisco MDT, Juniper, gNMI; `intake.ports.telemetryDialout`) (and 6514/tcp
for syslog over TLS when `intake.ports.syslogTLS.enabled`).

Other shapes, each a value set the chart is tested with:

| Values | Shape |
|---|---|
| `single.yaml` | one pod, embedded SQLite, no database to run |
| `ha-3.yaml` | three pods, PostgreSQL, Lease leader election, Ingress with TLS, ServiceMonitor |
| `split-roles.yaml` | `roles.split=true`: collectors (listeners) in the StatefulSet, console (UI/API) in a Deployment; UDP and TCP on two Services that share an address; shared queue bus; syslog over TLS |
| `portal-shared.yaml` | Seshat plus the Device Tracker portal on the same PostgreSQL (`portal.mode: shared`) |
| `portal-push.yaml` | the portal with its own volume, fed by Seshat over HTTPS (`push`) |
| `hostnetwork.yaml` | no load balancer: pods on the host network, one per node, standard ports |
| `cnpg.yaml` | the database is a CloudNativePG cluster you created |
| `ephemeral-nobus.yaml` | `persistence.enabled=false` without a bus: `/data` is an emptyDir and Seshat logs the data-loss warning at start (demos and tests only) |

## What preserves the source address

| Path | Source preserved? | Notes |
|---|---|---|
| LoadBalancer + `externalTrafficPolicy: Local` (the chart default) | yes | traffic goes only to pods on the node that received it; the balancer must health-check nodes |
| LoadBalancer + `externalTrafficPolicy: Cluster` | **no** | kube-proxy SNATs to a node address when it forwards to another node; every device looks like a node |
| MetalLB BGP or L2 with `Local` | yes | BGP announces the address only from nodes with a ready pod; L2 puts all intake on one node |
| `intake.hostNetwork.enabled` | yes | there is no Service in the path |
| Cloud network load balancer | depends | see `docs/ha.md`, Mode 4: use the passthrough type that preserves the client address and keep `Local` |
| An Ingress or HTTP proxy | n/a | telemetry is UDP and raw TCP; only the UI/API goes through the Ingress |

Why `Local` matters: enrichment, the device knowledge base, per-sender rate limits and flow
templates are keyed by the sender address. With a rewritten source, thousands of devices collapse
into the few node addresses. The chart therefore defaults to `Local` and tells you so in
`NOTES.txt` when you override it.

**The startup check.** With `intake.sourceIPCheck.enabled` (default) the pods get
`SESHAT_EXPECT_SOURCE_IP_PRESERVED=true` and `SESHAT_LB_SNAT_CIDRS` (the pod's own node address plus
`intake.sourceIPCheck.snatCIDRs`, which should list your node subnets and the balancer's SNAT pool).
Every received datagram or accepted connection is compared against those ranges (a few prefix
compares and one atomic add, no I/O). If any matches, `GET /api/ready` reports
`"source_ip": "snat_detected"` in the detailed answer (the per-check detail is for an administrator, an operator or the metrics token; anonymous callers get only `ready` and the status code) (the pod stays ready: Seshat accepts everything, and taking every
pod out of the Service would also take the UI away), the log shows
`SOURCE ADDRESS REWRITING DETECTED` once a minute while it continues, and the Dashboard shows a
red "Source addresses" tile. Alert on the check value if you scrape `/api/ready` with the metrics token.

## Database

| `database.mode` | |
|---|---|
| `external` | `database.external.existingSecret` holds the URL under `key` (default `SESHAT_DATABASE_URL`) |
| `cnpg` | the chart reads `<clusterName>-app` key `uri` of a CloudNativePG `Cluster` you applied from `deploy/k8s/examples/cloudnativepg/`. The chart does not manage the `Cluster`. |
| `none` | embedded SQLite on the pod's volume; `replicaCount > 1` is refused unless `database.allowReplicatedSqlite=true` (each replica then has its own, unrelated database) |

Seshat uses `LISTEN/NOTIFY` on one dedicated direct connection and an advisory lock: connect to the
primary (`-rw`) Service, not through a transaction-pooling PgBouncer. Least-privilege roles and TLS
(`sslmode=verify-full`) are in `docs/storage.md`.

**Migrations run once per release.** A Helm `pre-install,pre-upgrade` hook Job runs
`seshat store migrate` (apply every pending migration, print the schema version, exit 0; safe to
repeat and to run concurrently, serialised by a PostgreSQL advisory lock) before any pod starts or
rolls. The pods also migrate at start, which then finds nothing to do. If the Job fails, Helm stops
the install or upgrade and the old pods keep running: `kubectl -n seshat logs job/seshat-migrate`.
It retries (`migrate.backoffLimit`), which also covers a database that is still starting.

## Leader election

Singleton jobs (retention, session sweep, change-feed pruning) run on one pod.
`leaderElection.mode`:

- `auto` (default): the PostgreSQL advisory lock whenever a database URL is set.
- `postgres`: the same, explicit.
- `k8s-lease`: a `coordination.k8s.io/v1` Lease named `<release fullname>-leader` (`seshat-leader` for a release called `seshat`) (the chart creates a
  Role limited to that Lease and a RoleBinding, and mounts the service-account token only in this
  mode). Failover takes about 15 s after a crash and is immediate after a clean stop (the Lease is
  released). The Lease's `leaseTransitions` is the fencing token. Use it when the database is
  reached through a pooler that cannot hold a session lock.

## Probes, drain and upgrades

- Liveness `GET /api/health`, readiness `GET /api/ready` (200 when the store and every listener are
  up; 503 while draining), a startup probe that waits up to two minutes for the listeners.
- `preStop` runs `seshat --drain` inside the container (the image has no shell): it calls
  `POST /api/drain` on localhost with a token derived from `SESHAT_SECRET_KEY`, which makes
  `/api/ready` answer 503, waits up to `drain.timeoutSeconds` for the destination queues to flush,
  and then holds for `drain.holdSeconds` so the balancer's health check notices before `SIGTERM`.
  The process then stops its listeners, flushes and exits. `terminationGracePeriodSeconds` must
  cover `drain.timeoutSeconds + drain.holdSeconds + 20` (the chart refuses a smaller value).
- **Rolling upgrade:** `helm upgrade` rolls the StatefulSet one pod at a time, last ordinal first;
  each pod drains before it stops, the PodDisruptionBudget (`maxUnavailable: 1`) protects against a
  node drain at the same moment, and the volume keeps the pod's queue so it resumes where it was.
  A pod's queue is unavailable while that pod is down unless `queue.bus.enabled`
  (NATS JetStream or Kafka; see [`storage.md`](storage.md)). `queue.bus.mode` sets `SESHAT_QUEUE_BUS_MODE`
  (default `only` for the stateless pods the bus gives you; `hybrid` keeps a local write-ahead queue); the chart
  also sets `SESHAT_DATA_EPHEMERAL=1` whenever `/data` is an emptyDir (`persistence.enabled=false` or the bus on).
- **Rollback:** `helm rollback seshat <revision>` restores the previous pods. Migrations are not
  reversed: keep upgrades to versions that migrate forward compatibly, and take a database backup
  first for a release that changes the schema (the release notes say when).
- `kubectl rollout status statefulset/seshat` shows progress; `kubectl get pods -o wide` shows the
  node of each pod.

## Scaling

`helm upgrade seshat ... --set replicaCount=5`. Pods start together (`podManagementPolicy:
Parallel`). Add pods only on nodes that receive traffic: with `Local` policy a node with no ready
pod gets no traffic (a MetalLB BGP node withdraws its route), and a node with two pods sends all of
its traffic to them. `topologySpread` with `DoNotSchedule` keeps it one per node. Scaling down keeps
the PVCs (`persistence.retentionWhenScaled: Retain`), so scaling back up resumes the old queues.
With BGP, the router's ECMP hash keeps one sender on one node, which keeps per-sender state local;
adding or removing a node re-hashes some senders (the shared database and KB make that harmless).

## Without a load balancer: host network

`intake.hostNetwork.enabled: true` runs the pods in the node's network namespace. Trade-offs:

- one pod per node (the chart adds required anti-affinity), so `replicaCount` cannot exceed the node count;
- the ports are taken on the node (a conflict fails the pod, not silently);
- no load balancing: point senders at a node address, or at a floating address you manage
  (keepalived, BGP on the nodes);
- NetworkPolicy does not apply to host-network pods;
- ports 162 and 514 are privileged. With `standardPorts: true` the container runs as root with every
  capability dropped except `NET_BIND_SERVICE`; without it Seshat listens on 1162 and 1514 and you
  redirect 162/514 on the node (the text is printed by `NOTES.txt`).

## Device Tracker portal

`portal.enabled: true` adds a Deployment of the `device-tracker` image, a ClusterIP Service and an
optional Ingress. `portal.mode`:

| Mode | Data | Needs |
|---|---|---|
| `shared` (default) | the same PostgreSQL as Seshat, live, no sync | `database.mode` external or cnpg; optional `portal.readOnlyDatabase` (a read-only role over `tracker_public`, `deploy/postgres/tracker_public_role.sql`) |
| `push` | Seshat pushes to the portal's own store (a PVC, or `portal.database`) | `portal.sync.existingSecret` (optional token) |
| `api` | the portal calls Seshat's `/api/tracker/*` | `portal.api.url`, `portal.api.existingSecret` (`SESHAT_PORTAL_API_TOKEN`) |
| `db` | a read-only role over `tracker_public` | `portal.readOnlyDatabase.existingSecret` |

Break-glass administrator, OIDC settings and the like go in a Secret you pass as
`portal.extraEnvFrom` (`SESHAT_PORTAL_ADMIN_EMAIL`, `SESHAT_PORTAL_ADMIN_PASSWORD`, `SESHAT_OIDC_*`).
See [`device-tracker-portal.md`](device-tracker-portal.md).

## Monitoring

`monitoring.serviceMonitor.enabled` renders a Prometheus Operator `ServiceMonitor` scraping
`GET /metrics` on every pod (through the headless Service; in split mode also the console). The
metrics need authentication: put `SESHAT_METRICS_TOKEN` (at least 32 characters) in a Secret, pass that
Secret to the pods with `extraEnvFrom`, and name it in `monitoring.serviceMonitor.tokenSecret`
(`{name: seshat-metrics, key: SESHAT_METRICS_TOKEN}`); see [`security.md`](security.md). The
metrics are listed in the operator docs of each component (`seshat_output_*`, `seshat_snmp_*`,
`seshat_flow_*`, `seshat_cluster_leader{instance}`).

## Security

Pods run as 65532, read-only root filesystem, no privilege escalation, all capabilities dropped and
the `RuntimeDefault` seccomp profile; `/data` (the PVC) and `/tmp` are the only writable paths. The
exceptions are opt-in and named: `nms.preserveSource` (an NMS destination that re-sends with the
device's address) runs as root with only `NET_RAW`, as `docs/outputs.md` describes; `hostNetwork` with
`standardPorts` adds `NET_BIND_SERVICE`. Secrets are referenced, never rendered. A starting
NetworkPolicy is in `deploy/k8s/examples/networkpolicy.yaml` (it also covers syslog over TLS on 6514 and the
edge listener on 8443, and ships a default-deny policy). Set `intake.service.loadBalancerSourceRanges` to your
device networks: with it empty a cloud load balancer accepts telemetry from anywhere (the chart prints a note
in `NOTES.txt` when it is empty). The deployment checklist for a customer's systems team is
[`hardening.md`](hardening.md).

## Troubleshooting

| Symptom | Check |
|---|---|
| `helm install` stops, `Error: ... migrate` | `kubectl -n seshat logs job/seshat-migrate`; usually the database URL or reachability |
| `secrets.existingSecret is required` | create the Secret with `SESHAT_SECRET_KEY` and name it |
| Pods ready, but the UI shows one device per node, or the Dashboard "Source addresses" tile is red | `kubectl get svc ... -o jsonpath='{.spec.externalTrafficPolicy}'` must be `Local`; behind a cloud balancer make sure the target type preserves the client address; add the node subnets to `intake.sourceIPCheck.snatCIDRs` |
| No traffic arrives | `kubectl get svc -l app.kubernetes.io/component=intake` shows `<pending>` (no pool/address); with `Local`, the node that receives must hold a ready pod (`kubectl get pods -o wide`) and the balancer's health check (`healthCheckNodePort`) must pass |
| Pod stuck not ready | `kubectl exec ... -- /seshat --healthcheck`; `curl -H "Authorization: Bearer $SESHAT_METRICS_TOKEN"` the pod's `/api/ready` (anonymous callers get only the verdict) and read the failing check |
| Two leaders / none | `kubectl get lease`, `GET /api/cluster/leader`; with PostgreSQL behind a pooler use `leaderElection.mode=k8s-lease` |
| Evictions during a node drain block | the PodDisruptionBudget (`pdb.maxUnavailable`) is doing its job; drain nodes one at a time |
| `preStop hook failed` events | harmless when the pod was already stopping; check `drain.*` against `terminationGracePeriodSeconds` |
