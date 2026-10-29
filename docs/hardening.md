# Hardening and deployment guide

For the systems and security team that installs Seshat. It lists what Seshat holds, what it exposes, what
to put in front of it, and how to check that what you received is what was built. Each recommendation names
the setting or file that implements it. Settings are documented in `.env.example`; the sections referred to
elsewhere are in [`packaging.md`](packaging.md), [`kubernetes.md`](kubernetes.md), [`edge.md`](edge.md),
[`ha.md`](ha.md), [`storage.md`](storage.md), [`security.md`](security.md) (sign-in, proxies, tokens) and
[`secrets.md`](secrets.md) (what is sealed, key rotation).

## 1. What Seshat holds and what it exposes

**It holds**

* credentials for every destination (passwords, API keys, tokens, signing secrets), SNMPv3 passphrases,
  polling communities, connector tokens, the single sign-on client secret and BGP neighbour passwords. All
  are stored **sealed** (AES-256-GCM) under one key, `SESHAT_SECRET_KEY`. Whoever has the database **and**
  the key has all of them; the database alone is useless to read them, the key alone too;
* the edge certificate authority's private key (sealed the same way), user password hashes (bcrypt), API
  token hashes, the audit log;
* the telemetry it is forwarding: device names, addresses, interface and user names that appear in syslog,
  flow records, and the Device Tracker's location data. Treat the disk queue (`<data dir>/queue`) as
  sensitive: it holds events in clear text until they are delivered.

**It exposes** (details and recommended sources in section 6)

* a web UI and API over **plain HTTP** on 8080 (and 8081 for the Device Tracker portal). It has no native
  TLS: put a TLS proxy in front;
* telemetry listeners that, by design, **accept data from any sender**: SNMP traps (162/udp), syslog
  (514 udp/tcp, 6514/tcp TLS), flows (2055, 4739, 6343/udp) and streaming-telemetry dial-out (57400/tcp,
  plaintext unless you configure TLS). Seshat never drops a legitimate event to be safe; it bounds memory,
  counts what it rejects and relies on you to limit who can reach these ports;
* optionally an edge collector listener (8443/tcp, mutual TLS), the HA peer link (the API port, plus VRRP
  protocol 112) and a BGP speaker (179/tcp, off unless you configure it).

**What an attacker gets by position**

| Position | Can do | Limit it with |
|---|---|---|
| Any host that reaches a telemetry port | Send events (spoofable for UDP), consume bounded resources | firewall to device networks (6) |
| Any host that reaches the UI port | Try passwords, read `/api/health` | TLS proxy, rate limits, SSO, firewall (3) |
| Holder of the secret key and a database copy | Decrypt every stored credential | key custody and separate backup (4, 9) |
| Holder of an edge's token or certificate | Send events as that edge | mutual TLS, revoke the edge (7) |
| Code execution as the service user | Everything the service can read | unit and container confinement (10) |

## 2. Deployment checklist

1. **Key**: generate `openssl rand -base64 48`, store it as in section 4, and **back it up separately from
   the data**. Never run production with `SESHAT_DEV=1`.
2. **TLS**: terminate TLS in a reverse proxy in front of 8080 and 8081 (section 3); bind Seshat to loopback
   or a private interface; set `SESHAT_TRUSTED_PROXIES` and `SESHAT_PUBLIC_URL`.
3. **First start**: create the administrator with the **setup token printed in the log on first start**
   (section 5), then enable single sign-on or add a second administrator and keep one break-glass account.
4. **Firewall**: allow each telemetry port only from the networks that send to it (section 6). Do not publish
   57400/tcp unless a device uses it; if you do, configure TLS and a client CA.
5. **Edges** (if used): use the dedicated mutual-TLS listener, enrol with a short-lived token, remove the
   token from the environment afterwards (section 7).
6. **HA** (if used): peer link and VRRP on a private segment only (section 8).
7. **Run confined**: use the shipped systemd units or the hardened compose files unchanged (section 10).
8. **Backups**: database yes, key separately, restore test (section 9).
9. **Monitoring**: scrape `/metrics` with the metrics token, alert on `seshat_output_blocked`, queue growth,
   login lockouts and drops (section 11).
10. **Verify** what you installed (section 13), and upgrade in the order of section 12.

## 3. TLS proxy

Seshat's HTTP listeners speak plain HTTP. Run Caddy, nginx, HAProxy or your load balancer in front, on the
same host (proxy reaches `127.0.0.1:8080`) or on a private network. Then tell Seshat who the proxy is, so the
client address in the sign-in rate limit and the audit log is the real one and not the proxy's:

```sh
SESHAT_TRUSTED_PROXIES=127.0.0.1          # the proxy's address as Seshat sees it (list or CIDRs)
SESHAT_PUBLIC_URL=https://seshat.example.com
SESHAT_COOKIE_SECURE=always               # session cookie only over HTTPS
```

* Seshat believes `X-Forwarded-For` / `X-Forwarded-Proto` **only** from a trusted proxy address, and takes the
  right-most entry that is not itself a trusted proxy. The proxy must therefore **overwrite or append**,
  never pass a client-supplied value through unchecked.
* In Docker the proxy on the host reaches the published loopback port, and Seshat inside the container sees
  the network's gateway address (typically `172.x.0.1`) as the peer. Find it with
  `docker network inspect seshat_default` and put that address in `SESHAT_TRUSTED_PROXIES`.
  Leave `SESHAT_BIND` at its `127.0.0.1` default (compose publishes the UI on loopback only).
* `SESHAT_TRUST_PROXY=1` is the old switch; it trusts every private and loopback address. Do not use it.

Minimal Caddy (automatic certificates; Caddy sets the forwarding headers itself):

```caddyfile
seshat.example.com {
    encode zstd gzip
    reverse_proxy 127.0.0.1:8080
}
```

Minimal nginx:

```nginx
server {
    listen 443 ssl;
    http2 on;
    server_name seshat.example.com;
    ssl_certificate     /etc/ssl/seshat/fullchain.pem;
    ssl_certificate_key /etc/ssl/seshat/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    client_max_body_size 64m;                       # MIB and pack uploads

    location / {
        proxy_pass         http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Forwarded-For   $remote_addr;   # overwrite, do not append client input
        proxy_set_header   X-Forwarded-Proto $scheme;
        proxy_read_timeout 300s;
        proxy_buffering    off;                     # live event tail
    }
}
server { listen 80; server_name seshat.example.com; return 301 https://$host$request_uri; }
```

The Device Tracker portal (8081) is put behind a proxy in the same way. Do **not** terminate TLS in front of
the edge listener (8443): edges authenticate with a client certificate, which a terminating proxy would
hide. Expose 8443 directly (or pass it through at layer 4) and restrict it by source address.

## 4. The secret key

* Generate: `openssl rand -base64 48` (at least 32 bytes are required; a shorter key is refused and a
  low-entropy one is logged as a warning).
* Provide it in **one** of these, in this order of preference:
  1. a file, `SESHAT_SECRET_KEY_FILE=/path/to/secret.key`, mode `0600` or `0400`, owned by the service user.
     It is read once at start; the server warns when the file is readable by group or others. Works with
     Docker secrets (`compose.keyfile.yaml`) and Kubernetes Secrets mounted as files;
  2. a root-only environment file read by systemd (the packages generate `/etc/seshat/secret.env`, mode
     `0600`, root-owned: the service user cannot read the file, only its own process environment);
  3. `SESHAT_SECRET_KEY` in `.env` (compose) or a Kubernetes Secret via `secrets.existingSecret`.
  When both a file and the variable are set the file wins and a warning is logged.
* Development mode (`SESHAT_DEV=1`) generates a key into the data directory next to the database it
  protects (on an edge it also enables profiling endpoints on the status page) and logs a warning on
  every start. It is for a throwaway evaluation only. Neither compose nor `.env.example` enables it.
* **Every node of a cluster needs the same key.** The Device Tracker portal has its own key unless it runs
  in mode `shared`, where it must equal the gateway's.
* **Back it up separately** from the data (section 9). Losing it makes every stored credential
  unrecoverable; storing it with the database backup defeats the sealing.
* **Rotate** with `seshat secrets rekey --from-key-file OLD [--to-key-file NEW] [--dry-run]` (see
  [`secrets.md`](secrets.md)): stop Seshat, back up the database, run it, then start Seshat with the new
  key. It refuses to run, writing nothing, if any sealed value cannot be read, and writes in one transaction.
  Plan a rotation after anyone with access to the key leaves, and after any suspected exposure. A cluster on
  PostgreSQL is rekeyed once; SQLite nodes each hold their own database, so run it on every node. Starting
  with a different key signs every user out once.

## 5. First-run setup token

Until the first administrator exists, the setup page is open to anyone who can reach it. Seshat therefore
requires a **setup token** to create that administrator: it is printed once in the log at the first start
(`journalctl -u seshat | grep setup_token`, `docker compose logs seshat | grep setup_token`), or you set it
yourself with `SESHAT_SETUP_TOKEN` (32 or more characters; needed when several replicas start together).
Enter it in the setup page. Complete the setup immediately after the first start, over TLS. Existing
installations that already have an administrator are unaffected.

## 6. Listener exposure and firewall rules

Defaults: compose publishes the UI on `127.0.0.1:8080` and the portal on `127.0.0.1:8081`, and does **not**
publish 57400/tcp (add `compose.telemetry.yaml`). The packages listen on all interfaces unless you set
`SESHAT_LISTEN=127.0.0.1:8080`; with a proxy on the same host do that.

| Port | Purpose | Authentication | Allow from |
|---|---|---|---|
| 8080/tcp | UI and API (plain HTTP) | login, SSO, API tokens | the TLS proxy only; HA peers if you use the peer link |
| 8081/tcp | Device Tracker portal | login, SSO | the TLS proxy only |
| 162/udp (1162 in a container) | SNMP traps and informs | v3 users; v1/v2c community is **not** checked | device networks (and the optional trap allow-list, `inputs/snmp.md`) |
| 514/udp, 514/tcp (1514) | syslog | none | device networks |
| 6514/tcp | syslog over TLS | server cert; optional client certificates | device networks |
| 2055, 4739, 6343/udp | NetFlow/IPFIX/sFlow | none | exporters |
| 57400/tcp | gRPC dial-out telemetry | **none** unless `SESHAT_TELEMETRY_TLS_*` is set | device networks; leave closed if unused |
| 8443/tcp | edge collectors, mutual TLS | client certificate | edge networks |
| 179/tcp | BGP (anycast HA only) | TCP-MD5 password | your routers |
| IP protocol 112 | VRRP (HA modes 1 and 2) | optional signature | the HA segment |
| 5432/tcp | PostgreSQL | scram + TLS | Seshat nodes only, never published |

**Active SNMP polling** is off until you enable it for a site, and a forged source address in traffic cannot
make Seshat send a community string to an arbitrary host (`device-kb.md`, "Where polling is allowed to go"):
an address seen only in a syslog, trap or flow packet is polled only if it falls inside the profile's
**Allowed networks** (`allowed_cidrs`); with an empty list nothing is polled on the strength of a packet, and
only devices an operator adopted, an inventory connector listed or the Device Tracker enrolled are polled.
Loopback, link-local (including cloud metadata), multicast and other reserved addresses are never polled, and
polls are rate limited. List only the device networks you own.

Example host firewall (nftables; adapt the sets to your networks):

```sh
nft add table inet seshat
nft add set inet seshat devices '{ type ipv4_addr; flags interval; elements = { 198.51.100.0/24, 203.0.113.0/24 } }'
nft add set inet seshat edges   '{ type ipv4_addr; flags interval; elements = { 192.0.2.0/24 } }'
nft add chain inet seshat input '{ type filter hook input priority -10; policy accept; }'
nft add rule inet seshat input udp dport { 162, 514, 2055, 4739, 6343 } ip saddr != @devices drop
nft add rule inet seshat input tcp dport { 514, 6514, 57400 } ip saddr != @devices drop
nft add rule inet seshat input tcp dport 8443 ip saddr != @edges drop
```

Docker publishes ports through NAT, so those packets traverse the `FORWARD` path, not `INPUT`. Put the same
rules in the `DOCKER-USER` chain and match the **original** destination port with conntrack, for example
`iptables -I DOCKER-USER -p udp -m conntrack --ctorigdstport 514 ! -s 198.51.100.0/24 -j DROP`. On
Kubernetes use `intake.service.loadBalancerSourceRanges` and a NetworkPolicy
(`deploy/k8s/examples/networkpolicy.yaml`, which also ships a default-deny policy and covers 6514 and 8443).

## 7. Edge collectors

Use the dedicated listener (`SESHAT_EDGE_LISTEN=:8443`): the edge authenticates with a certificate from
the edge CA, bound to its identity; bearer tokens are refused on that listener, and
`SESHAT_EDGE_REQUIRE_MTLS=1` refuses them on every listener (it needs `SESHAT_EDGE_LISTEN`). Bearer tokens
that are accepted (behind a proxy) expire after `SESHAT_EDGE_TOKEN_MAX_AGE` (default 400 days, `0` = never);
edges of this release rotate theirs automatically. Enrol with the one-time token from the Edges page, deliver it
through a file (`SESHAT_EDGE_ENROL_TOKEN_FILE`, or `seshat edge enroll --token-file`) rather than the command
line, and **delete it from the environment after the first start**: the identity lives in `edge.json` (0600). Pin the server certificate chain with
`SESHAT_EDGE_CA_FILE` when it is private. Revoke an edge from the Edges page the moment its host is
retired or suspected; rotate the edge CA on a schedule ([`edge.md`](edge.md)). The edge's status page
(`127.0.0.1:8082`) has no login: leave it on loopback.

## 8. High availability

The peer protocol (SQLite mode) and VRRP are only authenticated with a shared secret
(`SESHAT_CLUSTER_SECRET`, 16 or more characters, set VRRP `auth` on). Run both on a **private, isolated
segment**; use `https://` peer URLs through a proxy if the link crosses anything shared. VRRP and BGP
anycast need extra capabilities (`CAP_NET_ADMIN`, `CAP_NET_RAW`) and in Docker run as root on the host
network ([`ha.md`](ha.md), `deploy/compose/ha-pair.example.yaml`): put those hosts in your trusted tier.
BGP: peer only with routers you control, set a neighbour password, keep the speaker off
(`SESHAT_BGP_DISABLE=1`) on nodes that should never announce.

## 9. Backups

* **Back up**: the database (SQLite: the files under `/var/lib/seshat` taken with the service stopped or via
  an online backup of the database; PostgreSQL: `pg_dump` or your usual physical backup), and your
  configuration (`/etc/seshat/*.env`, TLS files, the compose `.env`).
* **Not in the same set**: the secret key. A database backup contains the sealed credentials, the sealed
  edge CA key, password hashes and the audit log; without the key it cannot be turned into credentials.
  Keep the key in your secret store or a separately protected location, and **test a restore** including
  the key.
* Protect backup storage as you would the live system, and encrypt it.
* The disk queue under `<data dir>/queue` is transient delivery state; it is not a backup target, but it is
  sensitive while it exists.

## 10. Confinement that ships

| Artifact | What it does | Check |
|---|---|---|
| `seshat.service` | own user `seshat`; only `CAP_NET_BIND_SERVICE`; `NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`, `PrivateDevices`, `ProtectProc=invisible`, `MemoryDenyWriteExecute`, `SystemCallFilter=@system-service ~@privileged @resources`, restricted address families and namespaces, `UMask=0077`, state dir `0700` | `systemd-analyze security seshat.service` (exposure 1.5) |
| `seshat-device-tracker.service` | its **own user** `seshat-tracker`, own state directory, own secret key file, no capabilities, same sandbox | exposure 1.3 |
| `seshat-edge.service` | transient user (`DynamicUser`), `CAP_NET_BIND_SERVICE` only, same sandbox | exposure 1.6 |
| compose files | non-root user (65532), `read_only: true` with a tmpfs `/tmp`, `cap_drop: [ALL]`, `no-new-privileges`, `pids_limit` | `docker inspect` |
| Helm chart | non-root 65532, read-only root, no privilege escalation, all capabilities dropped, seccomp `RuntimeDefault`, no service-account token unless leader election needs it | `helm template` |
| images | distroless static base (no shell, no package manager), digest-pinned bases, one binary, empty `/data` created `0700` | `docker inspect`, `docker run --rm IMAGE --version` |

The VRRP, anycast and relay drop-ins (`/usr/share/seshat/systemd/drop-ins/`) add exactly the capability and
address family each feature needs and nothing else. The HA compose examples are the one place that runs as
root in a container (VRRP needs the host network namespace): they drop every capability except the named few.
Resource limits are not imposed (they depend on your load): see the commented `mem_limit`/`cpus` in
`compose.yaml` and the `resources` values of the Helm chart, and pair a memory limit with `GOMEMLIMIT`.

## 11. Logs, audit and monitoring

* Seshat logs JSON to standard error: the journal for the packages, `docker compose logs` for containers.
  Ship it to your log platform. Credentials are masked in log lines, but the setup token is logged once at
  first start, so restrict who can read that log on a new install.
* The audit log (sign-ins, lockouts, configuration changes, token and edge operations) is in the database.
  Retention is `audit_days` (default 365, never below 30; `storage.md`). Export or forward it if your policy
  needs longer.
* `/metrics` and the detail of `/api/ready` need authentication; give Prometheus the bearer token
  `SESHAT_METRICS_TOKEN`. Useful alerts: `seshat_output_blocked`, destination errors, queue size, edge link
  down, `seshat_login_lockouts_total`, and the `*_dropped_total` counters of the inputs.

## 12. Upgrading

1. Read the release notes' "Changed (action required)" items; take a backup (section 9).
2. **Server first, then edges.** A new server keeps serving edges enrolled with 0.1.0, which cannot rotate
   their bearer token until upgraded (it expires after `SESHAT_EDGE_TOKEN_MAX_AGE`, 400 days by default,
   unless you set `0` or enrol them again); upgrade the edges afterwards. An edge newer than its server is
   not a tested combination. In SQLite clusters upgrade the nodes back to back (until all run the new
   release, nodes refuse each other's drain calls and sync pauses, then resumes). The Device Tracker portal
   comes last. Every login session ends once at this upgrade (session ids are now derived from the key):
   users sign in again.
   Create **`tracker:read`** API tokens only after every replica runs the release that introduced them, and revoke
   them before rolling back: an older binary does not know the role and treats the token as an ordinary signed-in
   caller on routes without a role list (the lookup, the export, the account routes). Rolling back does not narrow
   the database constraint that allows the role.
3. Packages keep your `*.env` files; `systemctl restart` happens only if the unit was running. Containers:
   pull or rebuild, `docker compose up -d`. Helm: `helm upgrade` (the migration hook runs first).

## 13. Verifying a release

Every release attaches `SHA256SUMS`, its signature `SHA256SUMS.sig`, the public key `cosign.pub` and SPDX
SBOMs for the source tree and both images. The same `cosign.pub` is committed in the repository root. Take it
from the repository (or from a release you verified earlier), not from the download you are checking, and keep
a copy: a key that changes between releases is a reason to stop and ask.

```sh
# 1. the checksums file is signed by the release key (no network lookup: keys are not in a public log)
cosign verify-blob --key cosign.pub --signature SHA256SUMS.sig --insecure-ignore-tlog=true SHA256SUMS
# 2. the files you downloaded are the ones that were signed
sha256sum -c --ignore-missing SHA256SUMS
# 3. the container images: signature, SBOM and build-provenance attestations (the tag resolves to the signed digest)
cosign verify --key cosign.pub --insecure-ignore-tlog=true ghcr.io/root-chain-ventures-llc/seshat:<version>
cosign verify-attestation --key cosign.pub --insecure-ignore-tlog=true --type spdxjson ghcr.io/root-chain-ventures-llc/seshat:<version>
cosign verify-attestation --key cosign.pub --insecure-ignore-tlog=true --type slsaprovenance1 ghcr.io/root-chain-ventures-llc/seshat:<version>
# the same three for ghcr.io/root-chain-ventures-llc/seshat-device-tracker:<version>
```

`--insecure-ignore-tlog=true` is expected: signatures are made with a key pair, offline, and are not
uploaded to a public transparency log, so authenticity rests on the custody of the private key. A release
that has no `SHA256SUMS.sig` is not a Seshat release: do not install it. The build pins every GitHub Action
by commit, builds with the committed `go.sum`, and uses digest-pinned base images.

## 14. Known limitations

* **Inputs accept any sender.** UDP sources can be spoofed and the unauthenticated listeners can be
  flooded; Seshat bounds memory and counts drops but cannot tell a real device from a forged one. Network
  controls (section 6) are the mitigation.
* **SNMPv3 replay.** Authenticated messages are checked against the RFC 3414 time window (150 s;
  `v3_time_window`, on by default; drops are counted as `v3_not_in_time_window`). What remains: an exact
  replay of a captured trap **inside the 150 s window** is accepted, and devices that do not keep a monotonic
  engine boots counter and clock (many do not persist `engineBoots`) are dropped by design until they
  resynchronise. Switching `v3_time_window` off removes the protection altogether. Keep the trap path on a
  network where an attacker cannot capture and re-inject packets (`inputs/snmp.md`).
* **GoBGP advisory (GO-2026-4736).** The BGP library used by the anycast speaker has a denial-of-service
  advisory with no upstream fix. The speaker is off unless configured and talks only to the neighbours you
  list; peer with routers you control and watch for a fix.
* **Plain HTTP and the streaming-telemetry dial-out port** need TLS added by you (proxy, or
  `SESHAT_TELEMETRY_TLS_*`).
* **One key seals everything**; there is no hardware-backed key store. Protect it as the root secret.
* **Release signatures are key-based.** There is no transparency log; a leaked signing key must be revoked
  by publishing a new `cosign.pub` through your vendor channel.
