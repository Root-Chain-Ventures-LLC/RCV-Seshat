# Packages (.deb and .rpm)

Seshat ships three Linux packages, each as `.deb` and `.rpm` for `amd64` (`x86_64`) and `arm64`
(`aarch64`). They hold static binaries (the web UI embedded) and depend on nothing but systemd and the
usual base system. Every release attaches them, together with binary tarballs, an install bundle and
`SHA256SUMS`. Containers and Kubernetes are covered by the README and
[`kubernetes.md`](kubernetes.md); a virtual-appliance image is not available yet.

| Package | What it runs | Unit | Configuration | State |
|---|---|---|---|---|
| `seshat` | the gateway and console (`/usr/bin/seshat`) | `seshat.service` | `/etc/seshat/seshat.env` | `/var/lib/seshat` |
| `seshat-device-tracker` | the Device Tracker SSO portal (`/usr/bin/device-tracker`, [`device-tracker-portal.md`](device-tracker-portal.md)) | `seshat-device-tracker.service` | `/etc/seshat/device-tracker.env` | `/var/lib/seshat-device-tracker` |
| `seshat-edge` | an edge collector (`/usr/bin/seshat-edge`, the same binary started with `--role edge`, [`edge.md`](edge.md)) | `seshat-edge.service` | `/etc/seshat/edge.env` | `/var/lib/seshat-edge` |

The three can be installed side by side.

## What is in each package

`seshat`:

| Path | |
|---|---|
| `/usr/bin/seshat` | the binary |
| `/usr/lib/systemd/system/seshat.service` | the unit ([`deploy/systemd/seshat.service`](../deploy/systemd/seshat.service)) |
| `/etc/seshat/seshat.env` | your settings; a configuration file (see upgrades below), mode 0600 |
| `/usr/share/seshat/packs/` | the built-in vendor packs (`SESHAT_PACKS_DIR`) |
| `/usr/share/seshat/systemd/drop-ins/` | optional capability drop-ins (see below) |
| `/usr/share/doc/seshat/` | `LICENSE` and a pristine `seshat.env.example` |

`seshat-device-tracker` has the binary, its unit, `/etc/seshat/device-tracker.env` and its doc directory.
`seshat-edge` has the binary as `/usr/bin/seshat-edge`, its unit, `/etc/seshat/edge.env`, its own copy of the
packs under `/usr/share/seshat-edge/packs` (a fallback until the server's packs arrive), the relay drop-in and
its doc directory.

The install scripts:

* create a system user and group per service: `seshat` for the gateway and **`seshat-tracker` for the portal**
  (different users on purpose: the portal faces users outside the collectors' network, so it must not run as
  the user that owns the gateway's database and key; the edge unit uses a transient user, `DynamicUser`);
* create each service's own key file when it does not hold one yet: `/etc/seshat/secret.env` for the gateway
  and `/etc/seshat/device-tracker-secret.env` for the portal, each a random `SESHAT_SECRET_KEY`, mode 0600,
  readable by root only (systemd hands the value to the process; the service user cannot open the file). They
  are not package files: no upgrade, removal or purge touches them. A `SESHAT_SECRET_KEY` in `seshat.env`
  overrides the generated one, `SESHAT_SECRET_KEY_FILE` overrides both (every node of a cluster needs the same
  key; see [`storage.md`](storage.md)). **Upgrading the portal** from a version that shared `secret.env` copies
  that key into the portal's own file once, so data the portal sealed stays readable, and hands the portal's
  state directory to `seshat-tracker`;
* create the state directories mode 0700 owned by the service user, and take "other" access away from an
  environment file that an administrator left readable by everyone;
* run `systemctl daemon-reload`. A first install does **not** enable or start anything; an upgrade restarts
  a unit that was running.

## Install

```sh
# Debian 12+, Ubuntu 22.04+
apt install ./seshat_<version>-1_amd64.deb
# RHEL / Rocky / Alma 9+, Fedora
dnf install ./seshat-<version>-1.x86_64.rpm

sha256sum -c --ignore-missing SHA256SUMS      # in the directory with the downloaded files
```

Then review `/etc/seshat/seshat.env` and start it:

```sh
systemctl enable --now seshat
curl -s http://127.0.0.1:8080/api/health        # {"ok":true}
seshat --version                                 # seshat X.Y.Z (commit ..., built ...)
```

The first start logs a one-time **setup token** (`journalctl -u seshat | grep setup_token`) that the setup
wizard asks for before it creates the administrator; open `http://<host>:8080` from a trusted network (or
set `SESHAT_LISTEN=127.0.0.1:8080` and put a TLS proxy in front first, [`hardening.md`](hardening.md)). The unit listens on the standard ports:
UI and API on 8080, SNMP traps on 162/udp, syslog on 514/udp and tcp; flows (2055, 4739, 6343/udp) and the
telemetry dial-out listener as documented in `.env.example`. Any of these can be changed in `seshat.env`.

## Configuration and data

| | Path | Notes |
|---|---|---|
| Settings | `/etc/seshat/seshat.env`, `device-tracker.env`, `edge.env` | `KEY=value` lines, the same variables as `.env.example`; read by systemd (as root) before the process starts, so they can stay 0600. Restart the unit after a change. |
| Defaults | the unit's `Environment=` lines | data and packs directories, listen addresses; a line in the env file wins |
| Secret key | `/etc/seshat/secret.env` (portal: `/etc/seshat/device-tracker-secret.env`) | generated once, root-only 0600; **back it up separately from the data** ([`hardening.md`](hardening.md)) |
| Data | `/var/lib/seshat` | SQLite database (unless `SESHAT_DATABASE_URL` points at PostgreSQL), destination queues, MIB uploads (`mibs/`). Owned by `seshat`, mode 0700 (files 0600: the units run with `UMask=0077`). Back it up. |
| Packs | `/usr/share/seshat/packs` | replaced by every upgrade; MIB uploads live in the data directory |
| Logs | the journal | `journalctl -u seshat` |

The units are sandboxed beyond `ProtectSystem=strict` (system-call filter, no new privileges, restricted
address families and namespaces, hidden `/proc` of other users, private `/tmp` and devices; `systemd-analyze
security` rates `seshat.service` 1.5 and `seshat-device-tracker.service` 1.3, the same binary as the edge runs
at 1.6). The whole file system is read-only for the process except its state directory. Certificates and keys you reference (for example `SESHAT_SYSLOG_TLS_CERT`) must be readable
by the `seshat` user; put them under `/etc/seshat/tls/` with group `seshat` and mode 0640.

A path the service must **write** outside its state directory, typically a `SESHAT_OUTPUT_DIR` for file
destinations somewhere else, needs a drop-in; without it the destination reports `read-only file system`
and its events stay queued (nothing is lost):

```ini
# /etc/systemd/system/seshat.service.d/output-dir.conf
[Service]
ReadWritePaths=-/srv/seshat-output
```

The directory must exist and be writable by the `seshat` user (`install -d -o seshat -g seshat -m 0700
/srv/seshat-output`). The leading `-` makes a missing directory a no-op instead of failing the unit with
status 226/NAMESPACE; drop it if you would rather have the unit refuse to start. Then
`systemctl daemon-reload && systemctl restart seshat`.

Do not run these units as root (`User=root` in a drop-in): the system-call filter excludes the privileged
calls, including `fchown`, which SQLite makes when it creates the database as root, so the process would be
killed at its first start. The packages ship dedicated users (`seshat`, `seshat-tracker`) for that reason.

The portal in mode `shared` with SQLite would need the gateway's data directory, which the portal's own user
cannot (and should not) open: on one host use PostgreSQL for mode `shared`.

## Capabilities

By default `seshat` runs as the unprivileged user `seshat` with one capability, `CAP_NET_BIND_SERVICE`
(ports 162 and 514). Some features need more; each has a drop-in under `/usr/share/seshat/systemd/drop-ins/`
that adds exactly that, on top of the unit's own settings:

| Feature | Needs | Drop-in |
|---|---|---|
| Standalone, external load balancer (HA mode 4), edges | nothing more | none |
| VRRP, HA modes 1 and 2 ([`ha.md`](ha.md)) | `CAP_NET_ADMIN`, `CAP_NET_RAW`, `AF_PACKET` | `vrrp.conf` |
| Anycast with BGP, HA mode 3 | `CAP_NET_ADMIN` (addresses on the loopback, TCP-MD5) | `anycast-bgp.conf` |
| Raw relay with `preserve_source` ([`outputs.md`](outputs.md)) | `CAP_NET_RAW` | `nms-relay-preserve-source.conf` (also for `seshat-edge`) |

Install one by copying it into the unit's drop-in directory:

```sh
install -D -m 0644 /usr/share/seshat/systemd/drop-ins/vrrp.conf /etc/systemd/system/seshat.service.d/vrrp.conf
systemctl daemon-reload && systemctl restart seshat
systemctl show seshat -p AmbientCapabilities     # now lists cap_net_admin cap_net_raw
```

Without a capability the feature reports exactly what is missing (Cluster page, destination state) and
everything else keeps running. The Device Tracker portal needs no capabilities at all.

## Upgrade

Take a backup first, upgrade the server before the edges ([`hardening.md`](hardening.md)). Install the newer package the same way (`apt install ./...deb`, `dnf install ./...rpm` or `dnf upgrade`).
Your env files are kept: when the shipped example changed, apt asks or leaves it as `seshat.env.dpkg-dist`,
rpm writes `seshat.env.rpmnew`. A running unit is restarted; migrations run on start (once per cluster).

## Uninstall

```sh
apt remove seshat        # keeps /etc/seshat/seshat.env
apt purge seshat         # also deletes /etc/seshat/seshat.env
dnf remove seshat        # a changed seshat.env is kept as seshat.env.rpmsave
```

Removal stops and disables the unit. **No removal or purge ever deletes `/var/lib/seshat`,
`/etc/seshat/secret.env` or the `seshat` user**: the data and the key that seals the stored credentials are
too valuable to lose to a mistyped command, and a reinstall picks them up again. To remove everything, after
the package is gone:

```sh
rm -rf /var/lib/seshat /var/lib/seshat-device-tracker /var/lib/private/seshat-edge /etc/seshat
userdel seshat
```


| Release asset | Contents |
|---|---|
| `seshat_<v>_linux_<arch>.tar.gz` | `seshat`, `device-tracker`, `packs/`, `LICENSE` |
| `install-bundle.tar.gz` | the compose files, `.env.example`, the systemd units and drop-ins, the env examples |
| `SHA256SUMS` | checksums of every asset |
| `SHA256SUMS.sig`, `cosign.pub` | the signature over `SHA256SUMS` and the public key to check it with (when the release was signed) |
| `*.spdx.json` | SPDX software bills of materials: the source tree and both images |

Verifying the signature: [`hardening.md`](hardening.md), "Verifying a release".
