# Installing an edge collector

A small box (a small VM or a mini PC; the process uses roughly 45 to 65 MB of memory) in the network whose
devices should send traps and syslog to it. It only ever dials out to the main server. Background and the
protocol: [`docs/edge.md`](../../docs/edge.md).

## 1. Install

The `seshat-edge` package (.deb or .rpm, attached to every release; [`docs/packaging.md`](../../docs/packaging.md))
installs the binary as `/usr/bin/seshat-edge`, the fallback packs under `/usr/share/seshat-edge/packs`, the unit
[`deploy/systemd/seshat-edge.service`](../systemd/seshat-edge.service) and an `/etc/seshat/edge.env` to fill in:

```
apt install ./seshat-edge_<version>-1_amd64.deb        # or: dnf install ./seshat-edge-<version>-1.x86_64.rpm
```

By hand instead (`make edge` produces `bin/seshat-edge`; it is the normal binary, `--role edge` is the only
difference):

```
install -m 0755 bin/seshat-edge /usr/bin/seshat-edge
mkdir -p /usr/share/seshat-edge && cp -r packs /usr/share/seshat-edge/packs      # fallback until the server's packs arrive
cp deploy/systemd/seshat-edge.service /etc/systemd/system/
install -d -m 0755 /etc/seshat
```

## 2. Add the edge on the server

Edges page, *Add edge*: site (required), VRF, name. Copy the one-time token (valid 24 hours, shown once). If the
server's web certificate comes from a private CA, save that CA's PEM on the edge box (for example
`/etc/seshat/server-ca.pem`).

## 3. Configure and start

```
cat > /etc/seshat/edge.env <<'ENV'
SESHAT_EDGE_SERVER=https://seshat.example.com
SESHAT_EDGE_ENROL_TOKEN=sht_enr_REPLACE_ME
# or, to keep the token out of the environment: SESHAT_EDGE_ENROL_TOKEN_FILE=/etc/seshat/enrol.token
# SESHAT_EDGE_CA_FILE=/etc/seshat/server-ca.pem
ENV
chmod 0600 /etc/seshat/edge.env
systemctl daemon-reload && systemctl enable --now seshat-edge
```

(Installs made before the packages existed keep `/etc/seshat-edge/edge.env`; the unit still reads it, and
`/etc/seshat/edge.env` wins where both set a variable.)

The first start enrols with the token and stores the identity in `/var/lib/seshat-edge/edge.json`. **Remove the
two `SESHAT_EDGE_*` token lines from `edge.env` afterwards** (a used token is harmless, but there is no reason to
keep it). Without systemd, enrol by hand and start the process:

```
install -m 0600 /dev/null /etc/seshat/enrol.token; echo 'sht_enr_...' > /etc/seshat/enrol.token   # keeps the token out of the process list and shell history
SESHAT_DATA_DIR=/var/lib/seshat-edge seshat-edge edge enroll --server https://seshat.example.com --token-file /etc/seshat/enrol.token [--ca FILE]
SESHAT_DATA_DIR=/var/lib/seshat-edge seshat-edge --role edge
```

The unit runs as a transient unprivileged user (`DynamicUser`), keeps only `CAP_NET_BIND_SERVICE` (so it can bind
UDP 162 and 514), makes the file system read-only except `/var/lib/seshat-edge`, and restarts on failure. A local
raw relay with `preserve_source` also needs `CAP_NET_RAW`: install the drop-in
`/usr/share/seshat-edge/systemd/drop-ins/nms-relay-preserve-source.conf` as described in that file.

## 4. Verify

```
curl -s http://127.0.0.1:8082/api/ready                       # {"ready":true,...}
curl -s http://127.0.0.1:8082/api/status | head                # link_state "connected", queue_depth 0
journalctl -u seshat-edge -n 20
logger -n 127.0.0.1 -P 514 "edge test message"                 # appears on the server within a second
```

On the server the edge shows `online` on the Edges page within 30 seconds (its first heartbeat).

Point the devices at this box (UDP 162 for traps, 514 for syslog). Everything else (listeners, rate limits, local
relay to a site NMS) is configured on the server, in the edge's drawer.

## Containers

`compose.edge.yaml` at the repository root runs the same image with `--role edge`:

```
printf 'SESHAT_EDGE_SERVER=https://seshat.example.com\nSESHAT_EDGE_ENROL_TOKEN=sht_enr_...\n' > .env.edge
docker compose -f compose.edge.yaml --env-file .env.edge up -d --build
```

## Revoking, replacing, moving

Revoke on the Edges page (the box keeps buffering locally, the server accepts nothing more). *Rotate credentials*
revokes the certificate and token and gives a new enrolment token; delete `edge.json` (keep `queue/`) and enrol
again to continue delivering what was buffered.
