# RCV Seshat

**Seshat** is a self-hosted, white-label network telemetry gateway. It sits between your network devices and
your log platform: it receives SNMP traps, syslog, flow records (NetFlow v5/v9, IPFIX, sFlow) and streaming
telemetry, decodes and translates them with vendor packs, enriches them from your inventory (NetBox, Nautobot,
CSV, HTTP, DNS) and delivers the result to any number of destinations at once (Logstash,
Elasticsearch/OpenSearch, Kafka, Splunk, an existing NMS, files). It also keeps a read-only **Device Tracker**:
look up a MAC address, IP address, hostname or user and see what the device is, where it is, where it has been,
and how old every fact is.

Two applications ship from here:

- **Seshat**: the gateway and its web console.
- **Device Tracker portal**: a small SSO portal with only the lookup page, for everyday users, installed outside
  the collectors' network.

An **edge collector** (`seshat-edge`) forwards a remote site's traps, syslog and flows to the main server over
an outbound connection.

Seshat accepts data from any sender, never changes anything on a device (no SNMP SET, no CLI writes) and keeps
credentials sealed under one key you hold.

## License

**RCV Community License 1.1**: free for personal and home-lab use and for any organization's own internal
operations. A paid commercial license is required only to offer the software to third parties as a hosted,
managed, or SaaS service. See [`LICENSE`](LICENSE). Commercial inquiries: **legal@rootchainventures.com**.

Seshat is built from a private source repository; the source is not published. See
[`CONTRIBUTING.md`](CONTRIBUTING.md).

## What you download

Each release carries the install artifacts and nothing else (the release notes are empty on purpose):

| Artifact | |
|---|---|
| `seshat`, `seshat-device-tracker`, `seshat-edge` as `.deb` and `.rpm` | Linux packages for amd64 and arm64 with systemd units |
| `seshat_<version>_linux_<arch>.tar.gz` | static binaries and the built-in vendor packs |
| `install-bundle.tar.gz` | the compose files, `.env.example`, systemd units and drop-ins |
| `SHA256SUMS`, `SHA256SUMS.sig`, `cosign.pub` | checksums, their signature and the public key |
| `*.spdx.json` | software bills of materials for the source tree and both images |

Container images (linux/amd64; arm64 hosts use the packages), pulled without logging in:

- `ghcr.io/root-chain-ventures-llc/seshat`
- `ghcr.io/root-chain-ventures-llc/seshat-device-tracker`

Only the newest stable release is kept here; older releases and tags are removed when a new one is published.

## Requirements

- **Docker** path (one host): Docker Engine with Docker Compose **2.24 or newer**.
- **Packages**: Debian 12 or newer, Ubuntu 22.04 or newer, RHEL, Rocky or Alma 9 or newer, or Fedora, with systemd.
- **Kubernetes** path: Kubernetes 1.27 or newer, Helm 3, a way to give a Service a stable external address
  (MetalLB or a cloud load balancer) and PostgreSQL 16 or newer for more than one replica.
- A DNS name and a TLS certificate. Seshat serves plain HTTP and expects a **reverse proxy or ingress to
  terminate TLS** in front of it ([`docs/hardening.md`](docs/hardening.md) has Caddy and nginx examples).

## Install with Docker Compose

```sh
git clone https://github.com/Root-Chain-Ventures-LLC/RCV-Seshat.git
cd RCV-Seshat
cp .env.example .env
sed -i "s|^SESHAT_SECRET_KEY=.*|SESHAT_SECRET_KEY=$(openssl rand -base64 48)|" .env   # the key that seals stored credentials
docker compose up -d                                       # UI and API on http://127.0.0.1:8080
docker compose logs seshat | grep setup_token              # the one-time token for the setup page
```

The compose file publishes the UI on the loopback interface only, because it speaks plain HTTP: put a TLS proxy in
front of it before exposing it. SNMP traps arrive on host port 162/udp, syslog on 514/udp and tcp, and flows on
2055, 4739 and 6343/udp. Open `http://127.0.0.1:8080`; the first visit asks for the **setup token** (so that nobody
else who reaches the port first can claim the instance), creates the administrator and asks for your organisation's
name and short name.

**Back up `SESHAT_SECRET_KEY` separately from the data.** It seals every stored credential (destination passwords
and tokens, SNMPv3 keys, the edge CA key); without it they cannot be read, and stored next to the database backup it
protects nothing. To keep it out of the environment, use `compose.keyfile.yaml`. Details: [`docs/hardening.md`](docs/hardening.md)
and [`docs/secrets.md`](docs/secrets.md).

| Variant | Command |
|---|---|
| PostgreSQL storage | `docker compose -f compose.yaml -f compose.postgres.yaml up -d` (needs `SESHAT_POSTGRES_PASSWORD` in `.env`) |
| Device Tracker portal on :8081 | `docker compose -f compose.yaml -f compose.portal.yaml up -d` |
| Two replicas on one PostgreSQL | `docker compose -f compose.yaml -f compose.postgres.yaml -f compose.replicas.yaml up -d` |
| Streaming telemetry dial-out on 57400/tcp | add `-f compose.telemetry.yaml` (plaintext unless you configure TLS) |
| Edge collector | `docker compose -f compose.edge.yaml --env-file .env.edge up -d` ([`docs/edge.md`](docs/edge.md)) |

The compose files run the image of the release you cloned. `SESHAT_IMAGE` and `SESHAT_PORTAL_IMAGE` in `.env`
override it. The containers run as a non-root user with a read-only root file system, no capabilities and
`no-new-privileges`.

## Install with Linux packages

Download the packages for your architecture from the latest release, verify them (below) and install:

```sh
# Debian 12+, Ubuntu 22.04+
apt install ./seshat_<version>-1_amd64.deb
# RHEL / Rocky / Alma 9+, Fedora
dnf install ./seshat-<version>-1.x86_64.rpm

systemctl enable --now seshat
journalctl -u seshat | grep setup_token       # the one-time setup token
curl -s http://127.0.0.1:8080/api/health      # {"ok":true}
```

The packages create a dedicated service user, generate the secret key once into `/etc/seshat/secret.env` (root
only; back it up separately from `/var/lib/seshat`) and keep your `/etc/seshat/*.env` files across upgrades.
`seshat-device-tracker` installs the portal and `seshat-edge` an edge collector. See
[`docs/packaging.md`](docs/packaging.md).

## Install on Kubernetes

The Helm chart is in [`deploy/helm/seshat`](deploy/helm/seshat) (high-availability mode 4: an external load
balancer spreads senders over the pods):

```sh
kubectl create namespace seshat
kubectl -n seshat create secret generic seshat --from-literal=SESHAT_SECRET_KEY="$(openssl rand -hex 32)"
kubectl -n seshat create secret generic seshat-db --from-literal=SESHAT_DATABASE_URL='postgres://seshat:CHANGE_ME@db.example.com:5432/seshat?sslmode=verify-full'
helm -n seshat install seshat deploy/helm/seshat \
  --set secrets.existingSecret=seshat --set database.external.existingSecret=seshat-db
```

The chart never creates Secrets, certificates or the database. Walkthrough, values and troubleshooting:
[`docs/kubernetes.md`](docs/kubernetes.md).

## Verify what you downloaded

Every release is signed with a key pair; the public key is [`cosign.pub`](cosign.pub) in this repository. Take it
from here (or from a release you verified earlier), not from the download being checked.

```sh
cosign verify-blob --key cosign.pub --signature SHA256SUMS.sig --insecure-ignore-tlog=true SHA256SUMS
sha256sum -c --ignore-missing SHA256SUMS
cosign verify --key cosign.pub --insecure-ignore-tlog=true ghcr.io/root-chain-ventures-llc/seshat:<version>
cosign verify --key cosign.pub --insecure-ignore-tlog=true ghcr.io/root-chain-ventures-llc/seshat-device-tracker:<version>
```

`--insecure-ignore-tlog=true` is expected: signatures are made offline with a key pair and are not uploaded to a
public log. The images also carry an SPDX SBOM and a build-provenance attestation
([`docs/hardening.md`](docs/hardening.md), "Verifying a release"). A release without `SHA256SUMS.sig` is not a
Seshat release: do not install it.

## Upgrade

1. Take a backup of the database and keep the secret key.
2. Upgrade the **main server first, then the edge collectors, the Device Tracker portal last.** A new server keeps
   serving edges enrolled by the previous release; an edge newer than its server is not a supported combination.
   In a SQLite cluster upgrade the nodes back to back.
3. Packages: install the newer package (your `/etc/seshat/*.env` files are kept and a running unit restarts).
   Compose: `git pull`, then `docker compose pull && docker compose up -d`. Helm: `git pull`, then `helm upgrade`
   (the migration hook runs first). Migrations run on start, once per cluster.

Read [`docs/hardening.md`](docs/hardening.md), "Upgrading", before a version jump.

## Documentation

[`docs/README.md`](docs/README.md) indexes everything: deploying safely, the inputs (SNMP, syslog, flows,
streaming telemetry), routing and outputs, the device knowledge base, the Device Tracker, edge collectors, high
availability, storage, and the event schema. Index templates, a Logstash input and PostgreSQL roles for the
output side are in [`deploy/`](deploy).

## Reporting problems

- **Security issues:** please report them privately, see [`SECURITY.md`](SECURITY.md). Do not open a public issue.
- **Bugs and feature requests:** GitHub Issues on this repository. Use synthetic data (no real device names,
  addresses or credentials).
- **Commercial licensing:** legal@rootchainventures.com.
