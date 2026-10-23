# Seshat documentation

The pages below are the operator's view of each part. Start with the deployment guide.

| Topic | Page | What is in it |
|---|---|---|
| Deploying safely | [`hardening.md`](hardening.md) | What Seshat holds and exposes, the TLS proxy, the secret key, the first-run setup token, firewall rules, edges, HA, backups, upgrading, verifying a release |
| Linux packages | [`packaging.md`](packaging.md) | The `seshat`, `seshat-device-tracker` and `seshat-edge` .deb/.rpm: contents, install, upgrade, uninstall, paths, capability drop-ins per HA mode |
| Kubernetes | [`kubernetes.md`](kubernetes.md) | Helm chart: install, values examples, database and migration hook, Lease leader election, drain and rolling upgrades, scaling, host network, the portal, troubleshooting |
| Security and access | [`security.md`](security.md) | Trusted proxies, sign-in limits and lockout, sessions, the first-run setup token, metrics authentication, API token expiry, CSRF, who sees what in Device Lookup, audit retention |
| Secrets and keys | [`secrets.md`](secrets.md) | How credentials are sealed, what must never hold one, clearing secrets, `seshat secrets rekey`, file permissions, transport security |
| Storage and clustering | [`storage.md`](storage.md) | SQLite vs PostgreSQL, change fan-out, leader election and singleton jobs, offline behaviour, the copy tool, retention, database roles and TLS |
| High availability | [`ha.md`](ha.md) | The four HA modes; mode 4: the load-balancer contract (`/api/health`, `/api/ready`, `/api/drain`), source-IP preservation, MetalLB, IPVS-DSR, cloud NLBs |
| Edge collectors | [`edge.md`](edge.md) | `--role edge`: enrolment, the outbound stream, site scoping, the edge CA, health, footprint; install guide in [`../deploy/edge/`](../deploy/edge/README.md) |
| SNMP trap input | [`inputs/snmp.md`](inputs/snmp.md) | v1/v2c/v3 traps and informs, allow-list, rate limits, v3 users and engine IDs |
| Syslog input | [`inputs/syslog.md`](inputs/syslog.md) | UDP/TCP/TLS listeners, RFC 3164/5424, CEF/LEEF, grammars, the template inbox |
| Flow input | [`inputs/flows.md`](inputs/flows.md) | NetFlow v5/v9, IPFIX, sFlow, J-Flow/NetStream/NSEL, templates, sampling, GeoIP (bring your own), roll-ups |
| Streaming telemetry input | [`inputs/telemetry.md`](inputs/telemetry.md) | gNMI and Juniper JTI dial-in, Cisco MDT / Juniper / gNMI dial-out, the `seshat.metric` event, device-side configuration examples |
| Device knowledge base | [`device-kb.md`](device-kb.md) | How a device becomes known, connectors (NetBox, Nautobot, CSV, HTTP, DNS, opt-in SNMP polling), review actions, the device index and backfill |
| Routing and outputs | [`outputs.md`](outputs.md) | The route expression grammar, destination types, queues and retries, secrets, the shared message bus |
| Device Tracker | [`device-tracker.md`](device-tracker.md) | How location is determined, uplink exclusion, polling and per-VLAN contexts, event-driven sightings, freshness, watch lists, the lookup API, the read-only guarantee |
| Device Tracker portal | [`device-tracker-portal.md`](device-tracker-portal.md) | Data modes, SSO setup, scoping, redaction, audit |
| Common schema | [`schema/`](schema/README.md) | Every field of every dataset (`fields.md`), JSON Schema, one synthetic example per dataset, the Device Tracker portal contract |

Index templates, pipelines and ready-made settings for the output side are in [`../deploy/`](../deploy): OpenSearch and
Elasticsearch templates, a Logstash input, PostgreSQL roles, Kubernetes examples, systemd units and the Helm chart.

## How the parts fit

```
input (snmp | syslog | flows | telemetry) -> device stamper (knowledge base) -> router -> destinations (queue -> batch -> send)
        |                      ^                                   \-> debug tap (GET /api/events/tail?dataset=...)
        v                      |
 MIB library / grammars   learning signals (sysName, engine ID, syslog hostname)
```

Nothing on the receive path does network or database I/O; background workers do the learning, the queue writes and
the sends. Start-up order: configuration, store and migrations, secrets, branding, MIB library, knowledge base and
connectors, outputs and router, enrichment, inputs, API. Migrations run on start, once per cluster.
