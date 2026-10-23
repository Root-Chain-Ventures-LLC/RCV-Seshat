# Secrets, keys and file permissions

How Seshat protects the credentials it stores, and what you operate.

## What `SESHAT_SECRET_KEY` protects

Credentials an operator enters (destination passwords and tokens, connector tokens, the OIDC client
secret, SNMPv3 passphrases, BGP neighbour passwords, tracker API-source and portal-sync secrets, the
edge CA's private key) are **sealed** before they reach the database: AES-256-GCM, a fresh random
nonce per value, a key derived from `SESHAT_SECRET_KEY` with HKDF-SHA256 for each purpose, and the
purpose bound as additional data (a value sealed for one purpose cannot be opened as another). The
API never returns them; it reports only `*_set` flags (`secrets_set` names).

Use 32 random bytes: `openssl rand -hex 32`. Seshat logs a warning at start when the key has very few
distinct characters. Keep the key outside the data volume (a Kubernetes Secret, `/etc/seshat/secret.env`
mode 0600, a vault). `SESHAT_DEV=1` generates a key into `$SESHAT_DATA_DIR/dev-secret.key` next to the
database: fine for evaluation, **not** protection, because a copy of the volume contains both.

The same key (through HKDF with separate labels) also keys the session identifiers, the drain token and
the cluster key check. None of them uses the raw key. **Upgrading from 0.1.0 invalidates every login
session once** (users sign in again) and changes the drain token, which the pod's `preStop` hook derives
by itself.

### Where credentials are *not* allowed to live

Anything that is not a declared secret field is stored and shown in clear. Seshat therefore treats these as
secrets and seals/redacts them as well: webhook and other header maps (every value), URL query parameters
named like `token`, `key`, `secret`, `password`, `auth`, `sig`, connector URL templates, and the
credentials embedded in a URL (`user:pass@`). They show as `***` in API responses and are removed from
error messages, status text and logs. Still: put credentials in the secret fields where there is one.

### Clearing a secret

Every write-only secret can be cleared explicitly, and an empty field still means "keep" so a blank form
never wipes a secret by accident: `clear_token`, `clear_webhook_secret`, `clear_auth_value` (connectors),
`clear_community` (SNMP polling profile; it is also dropped when the profile switches to SNMPv3),
`clear_secrets: [...]` (destinations), `clear_secret` (tracker API sources), `clear_client_secret` (single
sign-on) and `clear_token` (portal sync). A secret sent as JSON `null` clears it where the API takes a
secret field. The UI has a "Remove the stored value" control next to each secret that is set. Changing the
host of a destination, API source or portal sync target (or the single sign-on issuer or client ID) also
removes the stored credential unless the same request supplies a new one.

## Changing the key: `seshat secrets rekey`

```
# 1. stop Seshat (every node; SQLite nodes each hold their own database) and back up the database
# 2. put the old and the new key in files (mode 0600)
seshat secrets rekey --from-key-file old.key --to-key-file new.key --data-dir /data --dry-run
seshat secrets rekey --from-key-file old.key --to-key-file new.key --data-dir /data
# 3. start Seshat with SESHAT_SECRET_KEY set to the new key
```

`--database-url` (or `SESHAT_DATABASE_URL`) selects PostgreSQL; without `--to-key-file` the new key is
`SESHAT_SECRET_KEY`. The command finds every sealed value (settings, destinations, edges, SNMPv3 users),
including the credentials embedded in URLs (a destination's `url`/`urls`, a connector's
`url`/`url_template`/`seed_url`, a tracker API source's `base_url`), opens each with the old key under
whichever purpose it was sealed for and seals it again under the new key. `--dry-run` reports what would
change and writes nothing. It **refuses to run** (and writes nothing) if any sealed value, or anything that
looks like one, cannot be read with either key; it checks its own plan before writing; and it writes
everything in a single database transaction, so a failure leaves the database as it was. It is safe to run
again: values already under the new key are recognised and skipped. Changing the key without running it
leaves every sealed value unreadable.

Starting Seshat with a different `SESHAT_SECRET_KEY` signs every user out (session ids are derived from
the key) and changes the drain token; the rekey command itself does not touch sessions.

### Known limitation

A sealed value is bound to its purpose, not to the row and field it sits in. Someone who can write to the
database can therefore move a sealed value between fields of the same purpose (for example swap a
destination's `password` and `token`). Binding values to table, row and field needs every stored value
re-sealed in one migration and is not done in this release; protect write access to the database
(separate roles, no shared accounts) as the storage page describes.

## File permissions

The process runs with umask `077`. The SQLite database and its `-wal`/`-shm` files, the queue and spill
directories and files, generated keys, the node id and the edge's state file are created `0600` in `0700`
directories. Missing directories are created `0700`. A directory that already exists keeps its owner and
group access (a service manager or an operator may have set `0750` so a log shipper in the group can read
`<data>/output`); only access for others is removed. Files written for others to read on purpose are given
their mode explicitly instead of the umask's: **file outputs are `0640` by default** (owner read/write, group
read; set `file_mode` in the destination's settings, for example `"0600"`), uploaded MIBs `0640`. The umask
being 077 means these are no longer widened by accident, and a new file output is no longer `0644` on a
host whose umask is 022. The `node-id` file of an earlier release is tightened to `0600` when read.

## Transport security

The console listener speaks plain HTTP. Logins, session cookies, API tokens, the edge bearer token and the
drain token all cross it: **put it behind a TLS-terminating proxy or load balancer** and reach it only
through that. The same goes for the cluster peer protocol (see `ha.md`) and the Device Tracker portal.
Outbound connections of tracker API sources, connectors and destinations do not use the `HTTP_PROXY` /
`HTTPS_PROXY` environment: a proxy would resolve the checked target itself and the target guard could not
see it. NAT64 addresses (`64:ff9b::/96`, `64:ff9b:1::/48`) are judged by the IPv4 address they embed, and the
Azure wireserver (168.63.129.16) is refused with the other metadata addresses.

Outbound, Seshat verifies server certificates and uses TLS 1.2 or newer; destinations that carry a
credential over `http://`, or have `insecure_skip_verify` on, are flagged in the API (`warnings`), the UI and
the log.

Operator-set outbound URLs (tracker API sources, connectors, destinations) may not point at loopback,
link-local (169.254.0.0/16, fe80::/10), cloud metadata or the unspecified address; private (RFC 1918)
targets are allowed. `SESHAT_ALLOW_LOCAL_TARGETS=1` lifts the restriction for a lab that needs it. Redirects to
another host are not followed with credentials.
