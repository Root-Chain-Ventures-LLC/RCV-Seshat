# Security and access

How Seshat decides who is calling, how long a sign-in lasts, and what an unauthenticated visitor can
learn. Everything here applies to Seshat and to the Device Tracker portal unless it says otherwise.
Variables are listed in `.env.example`.

## Behind a reverse proxy: `SESHAT_TRUSTED_PROXIES`

Seshat needs the real client address for the sign-in rate limit, the audit log and
`Secure`/HSTS decisions. A proxy reports it in `X-Forwarded-For` and `X-Forwarded-Proto`, but any client
can send those headers too, so they are believed **only when the TCP peer is a proxy you named**:

```sh
SESHAT_TRUSTED_PROXIES=192.0.2.10,198.51.100.0/24     # addresses and/or CIDRs, comma separated
```

* Nobody is trusted by default: headers from everyone are ignored and the client is the TCP peer.
* For a request from a trusted proxy the client is the **right-most** `X-Forwarded-For` entry that is not
  itself a trusted proxy. Entries further left are client-supplied and never used, so rotating a forged
  `X-Forwarded-For` does not change the key the rate limit uses.
* `X-Forwarded-Proto: https` makes the session cookie `Secure` (with `SESHAT_COOKIE_SECURE=auto`) and
  turns on HSTS only when it comes from a trusted proxy.
* Your proxy must **append** to `X-Forwarded-For` (nginx `$proxy_add_x_forwarded_for`, Caddy and Traefik
  do by default) and must set `X-Forwarded-Proto`.
* Without any trusted proxy, behind a proxy, every client shares the proxy's address. Seshat still works
  but the per-address limit then counts all users together (and a lock on the shared address applies to
  all of them): set the variable.
* A prefix shorter than /8 (IPv4) or /32 (IPv6), such as `0.0.0.0/0`, is refused at start: it would make
  the whole internet a "proxy" and the client address whatever a client claims.
* Set `SESHAT_PUBLIC_URL` to the external URL. SSO callback and logout-return addresses are built from it;
  without it they are derived from the request's `Host` header.

`SESHAT_TRUST_PROXY=1` still works for existing installs, with weaker semantics, and logs a warning at start.
It trusts **one hop**: when the TCP peer is a private or loopback address (127.0.0.0/8, ::1, 10/8,
172.16/12, 192.168/16, fc00::/7, link-local), the client is the right-most `X-Forwarded-For` entry (what a
single proxy appends), and nothing further left is ever read. It cannot tell a proxy from a client in the
same range, so **a client that can reach Seshat directly from a private network can claim any address**
(the per-address limit and the audit address are then forgeable for it; the per-address lock still applies
to the address it really has). `SESHAT_TRUSTED_PROXIES` closes that: list the proxies. If both are set the
list wins.

## Signing in

* **Per-address limit:** ten attempts, one more every six seconds, per client address (an IPv6 address
  counts as its /64). A successful sign-in gives its token back, so normal use never spends it.
* **Per-account lock, per address:** failures are counted per (normalised email, client address). Five are
  free; each further failure from that address locks that email **for that address** for 30 s, doubling to a
  ceiling of 15 minutes per lock; a success from the address clears its count, and a quiet half hour does
  too. While locked, every attempt from that address (even with the right password) gets `429` with
  `Retry-After`. Another address is not affected, so somebody who knows an administrator's email cannot lock
  that administrator out from their own address, and a person at their desk can still sign in.
  A shared address (a NAT, or a proxy you did not list) shares the lock among everyone behind it.
* **Slow-down across addresses:** when failures for one email come from several addresses, every attempt for
  that email (including a correct one) is delayed by 100 ms per failing address beyond the second, up to
  2 s. Guessing from many addresses is throttled to a few dozen tries a minute per email, and nobody is ever
  locked out by it.
* The counts are kept per email whether or not an account exists, so the response never says which emails are
  accounts. They live in memory per process: a restart clears them, and with several replicas each keeps its
  own. A determined attacker who controls many addresses is slowed, not stopped: use a strong password, and
  alert on `seshat_login_lockouts_total` and on bursts of `login.failed` in the audit log.
* **Unlock:** an administrator can clear an email's lock and slow-down at once: Settings > Users > "Clear
  sign-in lock", `POST /api/users/{id}/unlock` (audited as `user.unlock`), or on the server
  `seshat users unlock <email> [--data-dir DIR] [--database-url URL]`, which works while the server runs
  (it writes a marker to the database that the server honours at the account's next locked attempt, on any
  replica). Restarting the server also clears every lock.
* Audit: `login.failed` for each failure and `login.locked` when a lock starts or grows. Prometheus:
  `seshat_login_lockouts_total`, `seshat_login_blocked_total`.
* Failed sign-ins always answer after one bcrypt comparison, whatever the reason (unknown email, an email
  with control characters, disabled account, SSO-only account, wrong password), so timing says nothing about
  the account.
* Attempted emails and other attacker-supplied text are cut to 254 bytes before they are written to the
  audit log.

## Sessions

| Setting | Default | Meaning |
|---|---|---|
| `SESHAT_SESSION_TTL` | `24h` | absolute lifetime of a password session |
| `SESHAT_SSO_SESSION_TTL` | `8h` | absolute lifetime of a session started through single sign-on (never longer than the line above) |
| `SESHAT_SESSION_IDLE_TIMEOUT` | `2h` | a session with no request for this long ends; `0s` turns the idle limit off |

Set `SESHAT_SESSION_IDLE_TIMEOUT=0s` for a wallboard or NOC display that shows a page unattended: left
alone it signs out after two hours (the absolute limit still applies). Sessions that were already idle
for longer than the limit when you upgrade end once.

Any request made with the cookie counts as activity, except the web UI's own background polling while
nobody has touched the page for a minute (it sends `X-Seshat-Background: 1`), so a forgotten tab does not
keep a session alive. **Sign out everywhere** (Account page, `POST /api/account/logout-everywhere`) ends every session
of the signed-in user, including the current one. Changing your own password already ends the others.

### Single sign-on

* Role and site scope are read from the identity provider's groups **at sign-in** and again at every
  sign-in. Removing someone from a group (or disabling them at the provider) therefore takes effect when
  their Seshat session ends: at the latest after `SESHAT_SSO_SESSION_TTL`, sooner with the idle limit.
  To cut a person off immediately, disable the account in Settings > Users (that ends its sessions at once).
* A provider that sends `email_verified: false` is **refused** (`sso_email_unverified` on the login page);
  nothing is created or updated from an address the provider itself calls unverified. Providers that do not
  send the claim at all are accepted.

## First-run setup token

`POST /api/setup` creates the first administrator, so whoever reaches an un-set-up instance first would own
it. While no administrator exists the call therefore needs a **setup token**, sent as the
`X-Setup-Token` header or the `setup_token` body field (the setup page has a field for it):

* `SESHAT_SETUP_TOKEN=<at least 32 characters>` (for example `openssl rand -hex 32`): that value is the token.
* Otherwise the server generates a random token at start and writes it **once, at WARN level**, to the log:
  `journalctl -u seshat | grep setup_token` (packages) or `docker compose logs seshat | grep setup_token`.
  A restart before setup generates a new one.
* With several replicas (Kubernetes, clusters) set `SESHAT_SETUP_TOKEN`, from a Secret (`extraEnvFrom` in the
  Helm chart): each replica would otherwise generate its own.
* The token is discarded when setup completes, and nothing is generated at start once an administrator exists.
* Attempts are rate limited and wrong tokens are audited (`setup.rejected`).
* `SESHAT_SETUP_ALLOW_LOOPBACK=1` (off by default) lets a plain request from the machine itself skip a
  *generated* token (never a configured one): the TCP peer is loopback, there is no forwarding header and
  `Host` is `localhost`/`127.0.0.1`. Leave it off if a reverse proxy runs on the same host: such a proxy can
  make a remote request look local.

Still never expose an instance that has not been set up: complete setup before opening the port.

## Metrics and API description

`/metrics` and `/api/openapi.json` need a signed-in administrator or operator (session or API token).
For Prometheus use a dedicated bearer token instead of an account:

```sh
SESHAT_METRICS_TOKEN=$(openssl rand -hex 32)       # at least 32 characters
```

```yaml
scrape_configs:
  - job_name: seshat
    metrics_path: /metrics
    scheme: https
    authorization: { type: Bearer, credentials_file: /etc/prometheus/seshat-metrics-token }
    static_configs: [{ targets: ["seshat.example.com:443"] }]
```

The metrics token opens `/metrics` and the detail of `/api/ready` only; it is not an API credential.
`GET /api/health` (`{"ok":true}`) and `GET /api/ready` stay open for load balancers and probes. Anonymous
callers get only the verdict, `{"ready":true|false}` (and the status code); the per-check detail (listener
addresses, output counts, `source_ip`) is returned to administrators, operators and the metrics token.

## API tokens

New tokens expire after **90 days** unless the request says otherwise: `expires_in_days` between 1 and 3650,
or `0` for a token that never expires (an explicit choice; avoid it for the `admin` role). A token stops
working when the administrator who created it is disabled, demoted or no longer exists; re-issue it from a
current administrator. This also applies to push-sync (`sync`) tokens. **A token cannot create tokens**:
`POST /api/tokens` needs an administrator's signed-in session (403 `token_cannot_create_token` otherwise), so
no credential can outlive the administrator behind it. Tokens that an earlier version let a token create live
only while a live token of the parent's name does (a best-effort rule: names are not unique and the parent was
not recorded), and tokens from before creators were recorded have no creator and are not tied to an account.

A token's **role** decides which routes it opens (`admin`, `operator`, `user`), and its **scope** (sites and
tenants) decides which Device Tracker data it sees: an unscoped token sees none. Two roles exist for tokens only:
`sync` (push-sync ingest) and `tracker:read` (lookup, export, the device list, ports, port history and poll-now,
read-only; every other route is 403). Routes that merely require a signed-in caller (the account routes) refuse both.
See [`device-tracker.md`](device-tracker.md#read-only-integration-tokens-trackerread).

**What a scope does not limit.** The scope of an `admin` or `operator` token is enforced on the lookup, the
export and the Device Tracker device routes (device list, ports, port history, poll-now, `PUT
/api/tracker/devices/{id}`). It is **not** enforced elsewhere, because those routes are written for operators:

* A scoped operator token can still **read** the whole device inventory (`/api/devices`, `/api/devices/summary`,
  `/api/devices/{id}`), the tracker status, settings, watch list and approved list, the API sources, and the
  other administrative views its role opens.
* It can still **do** what an operator does: for example set any credential profile name on a device in its scope
  (`PUT /api/tracker/devices/{id}`), which makes Seshat poll that device with that profile's credentials, whatever
  site the profile belongs to.

So for an integration that only needs to read, use a **`tracker:read`** token with a scope, not an operator token:
it opens only the lookup, the export, the device list, ports, port history and poll-now, and answers 403 everywhere
else. Poll-now by any API token (this role included) is limited further: a device an operator switched off is
refused (409 `device_disabled`) and one device is polled at most once a minute per instance (429 with
`Retry-After`); a signed-in session is not limited.

## Cross-site request forgery

State-changing requests that rely on the session cookie must come from this site: an `Origin` header naming
this host (and, when a trusted proxy or our own TLS says what the request's scheme is, the same scheme), or
without `Origin` a `Referer` for this host or the header `X-Requested-With: seshat` (the web UI sends it on
every call). Anything else gets `403 cross_origin`. A foreign `Origin` is refused even when the custom header
is present, and so is a cookie-authenticated write the browser marks `Sec-Fetch-Site: cross-site`. Requests
that carry a **Bearer** token (API tokens, the edge protocol) are authenticated by the token alone, never by
the cookie, and are not affected (another `Authorization` scheme does not exempt a request), and neither are sign-in and setup from a client that has no
cookie yet (curl, scripts). If you script the API with a session cookie, add `-H 'X-Requested-With: seshat'`.
Single-sign-on sign-out is `POST /api/auth/oidc/logout` (the web UI does this); a `GET` only redirects to the
login page.

## Accounts and what they can see in Device Lookup

An account with the `user` role sees only the Device Lookup page, and **only the sites and tenants it has been
given**. An account with no scope sees nothing, never everything. Scope comes from single sign-on group mapping
(Settings > Sign-in) or from an API token's scope. **A local `user` account has no way to carry a scope, so it
always sees nothing:** give people who need scoped lookups single sign-on groups or a scoped token, and use
`operator` or `admin` for staff who should see everything. Settings > Users says so next to such accounts.

## Audit log

`audit_days` (Settings > Storage, `PUT /api/retention`) must be `0` (keep forever) or at least **30**; shorter
values are rejected, and a shorter value stored by an earlier version is raised to 30 when the job runs.
Rows written by unauthenticated requests are bounded in size.

## Push-sync token

`SESHAT_PORTAL_SYNC_TOKEN` must be at least 32 characters; a shorter value stops the portal at start with an
error that says so. Failed credential checks on the sync endpoints are rate limited per client address (ten, then
one every six seconds); correct credentials are unaffected until that budget is spent.
