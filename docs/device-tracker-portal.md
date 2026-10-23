# Device Tracker portal: operator guide

The portal (`device-tracker`, one small container) is the lookup page for people outside the
collectors' network: sign in with your organisation's identity provider, type a MAC, IP, hostname
or user, see where the device is and how old each fact is. It is read-only. The data contract with
Seshat is [`schema/tracker.md`](schema/tracker.md).

Contents: [Choosing a data mode](#choosing-a-data-mode), [Mode setup](#mode-setup),
[Single sign-on](#single-sign-on), [Scoping, redaction, rate limit](#scoping-redaction-and-rate-limit),
[Audit](#audit), [API tokens](#api-tokens), [Settings reference](#settings-reference).

## Choosing a data mode

Set `SESHAT_PORTAL_MODE` on the portal. The portal refuses to start when a mode lacks its settings.

| Mode | Value | Pick it when | Freshness | Needs |
|---|---|---|---|---|
| A. Push sync (default) | `push` | The portal is outside the collector network and must not reach in. | Seconds behind; keeps answering, with "data as of", when Seshat is down. | Portal reachable by HTTPS from Seshat. A "sync" token. |
| B. Lookup API | `api` | The portal can reach Seshat, and you want one source of truth with nothing copied. | Live. Shows "unavailable" when Seshat is down. | Seshat URL and an API token (role `user`). |
| C. Direct database | `db` | Seshat uses PostgreSQL and the portal may reach it. | Live. | PostgreSQL only; a read-only role (`deploy/postgres/tracker_public_role.sql`). |
| D. Shared database | `shared` | The portal runs next to Seshat on one database: a PostgreSQL cluster (the Helm chart's default) or one SQLite file on a volume both containers mount. | Live. | The same `SESHAT_DATABASE_URL` (or `/data` volume) as Seshat. |

In every mode the portal applies its own user scoping, redaction, rate limit and audit, and the answer has the shape of
Seshat's own `/api/tracker/lookup` (one set of types; the portal adds only the optional `notices`
and `portal` keys). Modes C and D read only the `tracker_public` views, never the tables. Mode A stores what Seshat pushes in the
interval tables the Device Tracker uses (migration 0040) and reads them through the same views, so a portal database and a Seshat database
have the same schema. The portal accepts the interval ids that Seshat's views publish (`iv-loc-000123`, `iv-l3-...`, `iv-wl-...`,
`iv-user-...`); `sightings_current` records are accepted and not stored, because the view derives that table from the intervals.

## Mode setup

### A. Push sync

On the **portal**:

```
SESHAT_PORTAL_MODE=push
SESHAT_PORTAL_ADMIN_EMAIL=breakglass@example.com     # created on first start when the database has no users
SESHAT_PORTAL_ADMIN_PASSWORD=<at least 10 characters> # remove both lines after the first start if you like
SESHAT_PUBLIC_URL=https://tracker.example.com
```

1. Sign in (`/login?local=1` if SSO is already on), open **Settings > API tokens**, create **one token per sender** with role **sync**,
   the sender's **stream** and the **sites and tenants** it may write, and copy it. A token without a scope still works but may write any
   site or tenant (the token list and the portal log warn about it); a sender can never overwrite or sweep another sender's rows.
   (`SESHAT_PORTAL_SYNC_TOKEN` is a deprecated legacy single-sender credential: it can only write rows that belong to no stream. Use per-sender tokens.)
   (A value of at least 32 random characters, e.g. `openssl rand -hex 32`, is required for `SESHAT_PORTAL_SYNC_TOKEN`; shorter values stop the portal at start.)
2. On **Seshat**, open **Settings > Portal sync**, add a portal: its URL, the token. Use **Test connection**, then Save.
   The stored token stays when you save without one, with two exceptions: ticking *Remove the stored token*
   (`"clear_token": true` in the API) removes it, and changing the portal URL to another scheme, host or port removes it, so enter the
   token again with the new URL.
   Seshat sends a full snapshot, then changes every few seconds, and a heartbeat every 30 s so "data as of" stays honest.
3. mTLS instead of (or with) a token: on the portal set `SESHAT_PORTAL_TLS_CERT`, `_KEY`, `SESHAT_PORTAL_TLS_CLIENT_CA` and
   `SESHAT_PORTAL_SYNC_MTLS=1`; on Seshat give the target a client certificate and key (absolute paths).

What to expect: the sender queues changes on disk (`$SESHAT_DATA_DIR/tracker-sync/<target>`) while the portal is unreachable and
retries with exponential backoff. If the queue passes its cap (512 MiB) or the portal reports a sequence gap that the queue cannot fill, Seshat
sends a snapshot and the portal becomes an exact copy again. **Settings** on the portal shows each stream's last sequence and lag.
Run the sender on one replica only (role `all` or `console`): a stream has one writer.

### B. Lookup API

On Seshat, create a token (**Settings > API tokens**, role `user`, scope `*` or the sites the portal's users may need). On the portal:

```
SESHAT_PORTAL_MODE=api
SESHAT_PORTAL_API_URL=https://seshat.example.com
SESHAT_PORTAL_API_TOKEN=tkr_...
```

Calls time out after 8 s; five failures in a row open a circuit breaker for 30 s so a down Seshat does not make every page hang.
The banner reads "Live data" or "unavailable". The portal sends the signed-in user's scope with the request (`site=` and `tenant=`,
repeated) and Seshat applies it on top of the token's own scope, fact by fact, so both sites and tenants are honoured. Limitation: the
lookup response carries sites, not tenants, so the portal's own second check (a site filter on the answer) can only run for site-only
scopes; for a scope that includes tenants the portal relies on Seshat's filtering. Give the API token a scope that covers every site and
tenant the portal's users may need; a user can never see more than the token.

### C. Direct database

Run `deploy/postgres/tracker_public_role.sql` against Seshat's database, then:

```
SESHAT_PORTAL_MODE=db
SESHAT_PORTAL_DB_URL=postgres://tracker_portal:<password>@db.example.com:5432/seshat?sslmode=verify-full
```

The portal checks that the schema declares contract version 1, opens its connections read-only, and issues only `SELECT` on the views.
It keeps its own users, sessions and settings in its own store (`SESHAT_DATABASE_URL` empty = SQLite in `/data`).

### D. Shared database (same cluster, or one SQLite volume)

```
SESHAT_PORTAL_MODE=shared
SESHAT_DATABASE_URL=postgres://...      # the same URL Seshat uses; empty with the same /data volume for SQLite
```

The portal runs the same migrations (once per cluster, advisory lock) and keeps its users in the same database (so Seshat's administrator
signs in to the portal as well, and the portal has no bootstrap account of its own); tracker data comes only from the `tracker_public`
views (on SQLite the `tracker_public_*` views, WAL mode lets both processes share the file). To read the views through the least-privilege role, also set `SESHAT_PORTAL_DB_URL` as in mode C.
The Helm chart deploys both apps with `SESHAT_PORTAL_MODE=shared` and the same database URL secret.

On a Linux host the portal package runs as its own user (`seshat-tracker`) with its own state directory and its own secret key (`/etc/seshat/device-tracker-secret.env`, root-only), separate from the gateway's, because the portal is the component meant for users outside the collectors' network. Mode `shared` on one host therefore needs PostgreSQL, and the portal must be given the gateway's key (`SESHAT_SECRET_KEY` in `device-tracker.env`, or `SESHAT_SECRET_KEY_FILE`); a package upgrade copies the key the two used to share into the portal's new file once.

`compose.portal.yaml` passes `SESHAT_PORTAL_MODE` through (default `push`); see its header for one command per mode.

## Single sign-on

OpenID Connect with any provider that publishes a discovery document: authorization code with PKCE, state and nonce, ID-token
verification (signature, issuer, audience, expiry). Configure it in **Settings > Sign-in** (both apps) or with `SESHAT_OIDC_*`
variables (those fields then show read-only). In the provider, register this redirect URI:
`https://<your host>/api/auth/oidc/callback` (set `SESHAT_PUBLIC_URL` behind a proxy so the portal knows its address).

| Setting | Env | Meaning |
|---|---|---|
| Issuer, client ID, client secret | `SESHAT_OIDC_ISSUER`, `_CLIENT_ID`, `_CLIENT_SECRET` | The secret is stored encrypted. Issuers must be `https` (`http` only for localhost). Leaving the secret empty keeps it; changing the issuer or client ID removes it (enter the new one); `"clear_client_secret": true` (the *Remove the stored client secret* box) removes it. |
| Scopes | `SESHAT_OIDC_SCOPES` | Default `openid profile email`; add the one your provider needs for groups. |
| Groups claim | `SESHAT_OIDC_GROUPS_CLAIM` | Default `groups`. If the ID token lacks it, the userinfo endpoint is asked. |
| Group to role | `SESHAT_OIDC_ADMIN_GROUPS`, `_OPERATOR_GROUPS`, `_USER_GROUPS` | Comma separated. The highest matching role wins. |
| Anyone else | `SESHAT_OIDC_DEFAULT_ROLE` | `user` (default), `operator`, or `deny`. |
| Group to scope | `SESHAT_OIDC_SCOPE_MAP` | `group=site:a\|site:b\|tenant:c;other=*`. Rules add up. |
| Password sign-in | `SESHAT_OIDC_LOCAL_LOGIN` | Off hides the password form. |

Behaviour worth knowing:

- First sign-in creates the user (just-in-time), bound to the provider and subject. Role and scope are recomputed from the groups at every sign-in, so a group change applies at the next one.
- A local account with the same email is never adopted; the person is told to use the password or ask an administrator.
- The portal has no user-management screen. In `shared` mode its accounts live in Seshat's database: disable, re-role or reset them in Seshat's **Settings > Users** (disabling ends the account's portal sessions too). In the other modes, revoke access at the identity provider; the break-glass administrator comes from `SESHAT_PORTAL_ADMIN_*`.
- Administrators see all sites. Everyone else sees what their groups map to (see below).
- **Break-glass**: local administrators can always sign in with a password at `/login?local=1`, even when password sign-in is off. Create one on the portal with `SESHAT_PORTAL_ADMIN_EMAIL` and `_PASSWORD`.
- Sign out uses the provider's `end_session_endpoint` when it offers one (RP-initiated logout), otherwise ends the session here only.

### Provider examples

All values are placeholders; use your own tenant, realm or domain.

**Microsoft Entra ID.** App registration, "Web" platform, redirect URI as above, create a client secret. Issuer
`https://login.microsoftonline.com/<tenant-id>/v2.0`. Under Token configuration add a groups claim (security groups, "Group ID"). Groups then
arrive as object IDs, so use those IDs in the mappings. Keep the default scopes (do not add `groups`). With many groups Entra sends a
reference instead of a list; assign the app to a few groups and emit "groups assigned to the application" only.

**Okta.** Create an OIDC Web app, redirect URI as above. Issuer `https://<org>.okta.com` (or the custom authorization server,
`https://<org>.okta.com/oauth2/default`). Add a Groups claim on the authorization server (name `groups`, filter `Matches regex .*` or a prefix). Scopes: `openid profile email groups`.

**Google Workspace.** OAuth client of type "Web application", redirect URI as above. Issuer `https://accounts.google.com`. Google does not release groups in the token, so group mapping is not available: everyone signs in with the default role, and the sites they see come from turning on "Let people with no assigned site or tenant see everything" (only if every signed-in person may see everything) or from a provider that does release groups.

**Authentik.** Create an OAuth2/OpenID provider (confidential) and an application, redirect URI as above. Issuer
`https://<authentik host>/application/o/<application slug>/`. The default `profile` scope mapping includes `groups`; scopes `openid profile email`.

**Keycloak.** Client "OpenID Connect", client authentication on, valid redirect URI as above. Issuer
`https://<host>/realms/<realm>`. Add a "Group Membership" mapper to the client's dedicated scope (token claim name `groups`, full group path off, add to ID token on).
Scopes `openid profile email`.

## Scoping, redaction and rate limit

All three are server-side and apply to every lookup in every mode (**Settings > Scoping, redaction and limits** on the portal):

- **Scoping.** A lookup only returns devices whose site or tenant is in the caller's scope (the SSO group mapping, or an API token's scope). An account
  with no scope sees nothing, and the page says why, unless **Let people with no assigned site or tenant see everything** is on (default off).
- **Redaction.** Hide user names, hide IP addresses (current and history), hide history older than N days, hide inventory custom fields
  (patch panel, jack, room). Hidden facts are omitted from the response and listed in `redactions`, and the page shows "hidden by policy".
- **Rate limit.** Lookups per minute per user (default 60). Over the limit the answer is `429` with `Retry-After`.

## Audit

Every lookup writes an audit row: who (email, or `token:<name>`), the normalised query, the scope applied, how many results, the mode, and the latency; refused lookups
(rate limit, source unavailable) are recorded too. Admins read it on the **Audit** page or
`GET /api/audit?action=tracker.lookup&actor=&since=&until=&limit=&offset=`, and export it with `&format=csv`.
Sign-ins, token changes and settings changes are in the same log.

## API tokens

`POST /api/tokens` (admin) creates a token with a role (`admin`, `operator`, `user`, or `sync` for push-sync senders), an optional site/tenant scope and an optional
expiry; the secret (`tkr_...`) is returned once and only its SHA-256 is stored. Use it as `Authorization: Bearer tkr_...`. `GET /api/tokens` lists them
(without secrets; an unscoped sync token carries a `warnings` entry), `DELETE /api/tokens/{id}` revokes. A `sync` token can only call the ingest endpoint; other tokens cannot.
For a `sync` token the scope is the set of sites and tenants the sender may write, and a scoped sync token must name its `stream_id`
([sender isolation](schema/tracker.md#sender-isolation)).

## Settings reference

| Variable | Purpose |
|---|---|
| `SESHAT_PORTAL_MODE` | `push` (default), `api`, `db`, `shared` |
| `SESHAT_PORTAL_API_URL`, `SESHAT_PORTAL_API_TOKEN` | mode `api` |
| `SESHAT_PORTAL_DB_URL` | mode `db` (required), mode `shared` (optional read-only role) |
| `SESHAT_PORTAL_SYNC_TOKEN` | **deprecated** static pre-shared token accepted by ingest (mode `push`), at least 32 characters: one shared, unscoped legacy credential that can only write rows belonging to no stream; prefer per-sender sync tokens |
| `SESHAT_PORTAL_SYNC_MTLS`, `SESHAT_PORTAL_TLS_CERT`, `_KEY`, `_CLIENT_CA` | serve TLS and accept verified client certificates for ingest |
| `SESHAT_PORTAL_ADMIN_EMAIL`, `SESHAT_PORTAL_ADMIN_PASSWORD` | break-glass administrator, created when the database has no users |
| `SESHAT_PUBLIC_URL` | external base URL (SSO redirect and logout addresses) |
| `SESHAT_OIDC_*` | see the table above |
