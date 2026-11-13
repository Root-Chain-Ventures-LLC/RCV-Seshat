# API

Everything the console does is a JSON API under `/api`. This page is the integrator's view: how to authenticate,
what a token may do, the error format, limits, and where the full description lives. The routes themselves are
listed in the OpenAPI description; the model for other apps (clients, capabilities, contracts, signed events) is in
[integrations/README.md](integrations/README.md); the MCP endpoint for assistants is in [mcp.md](mcp.md).

## Where things are

| What | Where | Who may read it |
|---|---|---|
| OpenAPI 3.1 description, generated from the router (a test fails when a route is undocumented) | `GET /api/openapi.json` | Administrator, operator or viewer (session or token), and API and integration-client tokens; not the `user` role |
| Discovery: app id and version, contract version, links, the tools and capabilities of the calling token | `GET /api/integrations` | Same as the OpenAPI description |
| Named, versioned contracts and the versions served | `GET /api/integrations/contracts` | Any authenticated caller |
| MCP endpoint | `POST /mcp` | API tokens only, see [mcp.md](mcp.md) |
| Liveness and readiness | `GET /api/health`, `GET /api/ready` | Anyone (readiness detail needs a sign-in) |

## Authentication

An API token goes in `Authorization: Bearer <token>`. `X-Api-Key: <token>` is accepted as an alias. A request that
carries a token is authenticated by the token and never by a session cookie.

**`X-Api-Key` and cookies.** A request that carries an `X-Api-Key` header (or a Bearer token) is token-authenticated: if the token is wrong the request is `401`, and its session cookie is ignored, not used as a fallback. If a reverse proxy in front of Seshat adds an `X-Api-Key` header of its own, every request through it becomes token-authenticated and browser sessions stop working; strip or do not set that header on the proxy.

- Create tokens under Settings, Tokens (administrator), or for an integration client under Settings, Integrations.
  The secret is shown once and stored hashed. Tokens expire (90 days unless you choose otherwise) and two can be
  live during a rotation. See [security.md](security.md).
- What a token may do is fixed on every request from what is stored now: the token must be live (not revoked, not
  expired); the administrator who created it must still be enabled and still an administrator; a token of an
  integration client takes the client's current definition (capabilities, scope, limits, disabled, expiry); any other
  token carries its own role and scope. Disabling the client, the creator or the token takes effect on the next call.
- An integration client's token opens only the routes that name a capability it holds; any other route answers
  `403 capability_missing`. Capabilities are named `domain.action` for what is allowed (`tracker.read`,
  `alerts.read`, ...); the table is in [integrations/README.md](integrations/README.md) and in the discovery
  document.
- A token cannot create tokens.

## Errors

Every error is `{"error":{"code":"snake_case_code","message":"Human text"}}`. A validation failure (`400
validation_failed`) adds `fields`, a map from field name to message. Codes are stable; messages are for people.
Status 401 means no valid credential, 403 that the credential is valid but not allowed (never an empty list), 404
that the thing does not exist, 429 that a rate limit was reached (`limit_exceeded` for client capability limits and the event inspector, `rate_limited` for sign-in, poll-now, lookups on the portal and enrolment attempts; both come with `Retry-After`), and 503 `unavailable` that the
store is busy for a moment (repeat the request after `Retry-After` seconds).

## Rate limits

A client token is limited per client and capability (a token bucket; defaults in the capability table, adjustable per
client). Over the limit the answer is `429 limit_exceeded` with a `Retry-After` header in seconds. The event inspector's search limit answers the same code per caller. Sign-in attempts
are limited per address and per account.

## Paging

List routes take `limit` and `offset` (or `page` and `page_size`, and `cursor` for the event inspector, whose answer
carries `next_cursor`). The default and the maximum are in the OpenAPI description of each route. A truncated
answer says so (`truncated`).

## Read-only toward devices

Nothing in the API, and nothing in the MCP endpoint, writes to a network device: no SNMP SET, no command-line
changes, no port actions. Polling a device is an SNMP read and is opt-in per site.

## Versioning

Route paths do not carry a version. A named contract (for example the tracker lookup) is versioned, and a version
stays served for at least one minor release after its successor appears. Check `GET /api/integrations/contracts`
at start-up and fail clearly if your version is gone.

## Error format transition

The error format above is the format Seshat already uses on every route; the web console and API-token callers see
the same body, so there is nothing to switch.

## What changed for API clients in this release

- `X-Api-Key: <token>` is accepted wherever `Authorization: Bearer <token>` is, including push-sync ingest and the
  metrics token. A request carrying it is token-authenticated and its cookie is ignored (see above).
- `GET /api/openapi.json` is now readable by API and integration-client tokens, not only by console roles. The
  `user` role still gets `403`.
- New: `GET /api/integrations` (discovery) and `POST /mcp`.
