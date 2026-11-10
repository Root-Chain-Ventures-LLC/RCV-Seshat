# Alert notification channels

Seshat delivers alert notifications to channels. The alert engine queues each notification; everything after that is
asynchronous and independent of the engine.


`Status` is `firing`, `resolved`, `acknowledged`, `escalated` or `test`; `Severity` is `critical`, `major`,
`minor`, `warning` or `info`. Queueing does no network I/O: it writes one outbox row per enabled channel.
The same `Key` sent twice to a channel is queued once. A missing or disabled channel is skipped (counted in
`seshat_alert_notifications_skipped_total`), not an error.

## Channel types

| Type | Needs | Notes |
|------|-------|-------|
| `email` | SMTP host, from, recipients | Implicit TLS (`tls`) or STARTTLS (`starttls`, default); optional AUTH PLAIN/LOGIN; text and HTML parts; a password is never sent over an unencrypted connection |
| `webhook` | URL | JSON body (`alert.notification` v1) or a body template; custom headers; optional HMAC-SHA256 signature (`sha256=<hex>`, header configurable) |
| `discord` | webhook URL | Embed coloured by severity; `username` and `avatar_url` are left out unless set |
| `fluxer` | server URL, webhook id and token | Its own type with its own base-URL field (self-hosted). The URL is `<server><prefix>/webhooks/<id>/<token>` with prefix `/api/v1` by default (what a live Fluxer instance serves). Shares the Discord renderer. Fluxer rejects an empty `avatar_url`, so the field is omitted unless set |
| `irc` | server, nick, target | TCP or TLS, server password, SASL PLAIN (TLS only), channel key, flood control |
| `slack`, `teams`, `matrix`, `telegram`, `pagerduty`, `ntfy` | see `GET /api/alerting/channel-types` | PagerDuty uses Events API v2 with a stable dedup key (`alert-<id>`), so a `resolved` notification resolves the incident the `firing` one opened |


Every outbound HTTP request carries a normal product `User-Agent` built from the branding values
(`<OrgShort>-Seshat/<version>`); some public edges reject an empty or unusual one.

## Delivery

* **Outbox.** Table `alert_outbox` (migration 0310, both backends): one row per (channel, key). Finished
  rows stay as the delivery history for 30 days.
* **Leader only.** Every replica runs the loop; only the replica that holds the cluster lease scans the
  outbox and sends, and it checks the lease (fencing token) just before sending. A new leader continues from
  the stored rows. A fail-over can repeat one notification whose answer was lost (at-least-once); the
  Matrix transaction id and the PagerDuty dedup key make those repeats harmless.
* **Retries.** A transient failure (network error, timeout, 408/425/429/5xx, SMTP 4xx) retries with
  exponential backoff (10 s doubling to 10 min; `Retry-After` is honoured) until the give-up time (24 h),
  then the row becomes `dead`.
* **Permanent failures.** 3xx answers (a redirect is never followed), 400, 401, 403, 404, 410 and other 4xx answers, SMTP 5xx, refused credentials,
  an IRC refusal (no such nick, banned, bad key) and SASL failures stop retrying: the row becomes `failed`
  and the channel shows `needs_attention` with the error until a later delivery succeeds.
* **One delivery at a time.** A pass claims each row (a conditional update that also moves its next attempt a
  few minutes ahead as a lease) before sending it, so two passes never send the same row. If the
  database write that records a delivery fails, the row is remembered as delivered and only the record is
  retried. The lease is checked before every send.
* **Whole-channel hold.** A failure that is the channel's own (a 429 or `Retry-After`, no connection, DNS, timeout,
  TLS, SMTP 421, or settings that cannot be built) holds the channel until that row's next attempt. A failure of
  one message (a 5xx that comes back for that payload) holds only that notification's own backoff and the later
  notifications of the same alert; other alerts go on. A successful test send or an edit clears the hold; the hold is kept in memory, so a new leader falls back to the
  per-row times. A channel whose settings cannot be built (for example a secret that no longer opens after a
  change of the instance key) keeps its rows and retries until the give-up time.
* **Scan window.** Per tick, for each enabled channel that is not on hold, at most 20 due rows are read through a
  partial index over the ready pending rows (migrations 0311-0312), so the cost follows the batch, not the backlog
  (about 1 ms with 250,000 rows, and under 1 ms with 30,000 notifications blocked behind a dead endpoint, on SQLite
  and PostgreSQL). Only the oldest pending notification of an alert is eligible (its `ready` marker is set when it is
  queued, and passes to the next one when it leaves the queue), so an alert's notifications go out one per pass, in order. The state change and the hand-over of the marker are one
  transaction, and a sweep about once a minute (leader only, migration 0313) restores the marker of a waiting
  notification that has no earlier pending notification and is over a minute old (a lost promotion, or a queue-and-deliver
  race on PostgreSQL); it counts them in `seshat_alert_notifications_healed_total`.
* **Circuit breaker.** After 5 consecutive 5xx answers for notifications of distinct alerts, the channel is held for
  60 seconds (in memory), then one notification is sent as a probe: success closes the breaker, another 5xx opens it
  again. One alert that keeps failing never opens it.
* **Size limits.** When a notification is queued its text is cut: title 512 bytes, summary 8 KB, device, interface,
  site, tenant and rule 512 bytes, label keys 128 and values 1 KB, at most 50 labels (the first 50 by name), a link 2 KB;
  a key over 512 bytes is refused.
* **At least once.** Delivery is at-least-once. The memory of a notification that was sent but whose record could not
  be written lives in the process only; after a restart or a change of leader that notification can be sent again
  (the Matrix transaction id and the PagerDuty dedup key make that harmless there).
* **Rate limit.** Per channel, `rate_per_min` (default 60). Rows over the limit wait for the next pass
  without an attempt being counted.
* **Order.** Notifications of one alert on one channel are delivered in order: a later row waits while an
  earlier one is pending or being retried. Other alerts are not held up.
* **History.** `GET /api/alerting/deliveries` (filters `alert_id`, `channel_id`, `state`, `before`,
  `limit`) and `GET /api/alerting/channels/{id}/deliveries`.

Metrics: `seshat_alert_notifications_total{type,result}` (`sent`, `retry`, `failed`, `dead`),
`seshat_alert_notifications_enqueued_total`, `seshat_alert_notifications_skipped_total`.

## Templates

Each channel can override the title and body templates (`text/template`); otherwise the type's default is
used. The data is the notification plus `.Started`, `.Ended` and `.Duration`. Functions: `upper`, `lower`,
`title`, `trim`, `join`, `default`, `truncate`, `replace`, and the safe builtins (`index`, `len`, `eq`, ...).
Limits: 4096 bytes of source, 64 KB of output, then cut to the channel's limit (Discord 4000 characters,
IRC lines, and so on). The template is checked against an allow-list when the channel is saved: only text, reads of the notification's
fields and variables, `if`/`with`/`range`, variables declared with `:=` (assigning with `=` is refused), the functions
`upper`, `lower`, `title`, `trim`, `join`, `default`, `truncate`, `replace` and the builtins `and`, `or`, `not`, `eq`,
`ne`, `lt`, `le`, `gt`, `ge`, `len`, `index` (the comparisons, `len` and `index` are charged against the render budget like the other functions). `define`, `block`, `template`, `print`, `println`, `printf`, `html`, `js`,
`urlquery`, `call` and `slice` are refused. `range` is only allowed over `.Labels` (no nesting), with the
labels capped at 50 (the first 50 by name). Each render also has a budget: at most 5000 function calls and 4 MB of text
handled, a 2 second limit, and it stops with the request, so a template's total work is bounded whatever it says.
Every string function fails once its result would pass 64 KB (`replace` also refuses an empty search text). There are no file or network functions. Values from alerts are data: `{{` inside a label is not evaluated.

## Security

* **Secrets** are sealed with `secrets.Box` (purpose `alert-channels`) field by field, as the form schema
  flags them (`secret: true`). The API returns `***` for a stored secret; sending `***` back on update keeps
  the stored ciphertext as it is, but only while every other setting of the channel (address, port, TLS
  options, the other secrets) is unchanged; if anything else changed the API answers with a field error and
  the secret has to be entered again, so a channel cannot be re-aimed at another server with a secret it
  was not given. Name, rate and enabled may change freely. The error text of a failed delivery and of a test send has every secret
  value (and the token at the end of a webhook URL) removed.
* **netguard** applies to every connection. HTTP channels use the guarded client (no proxy, connect-time
  address check, redirects only within the same host). SMTP and IRC are raw TCP, so they dial through a
  guarded dialer: loopback, link-local, multicast and cloud-metadata addresses are refused at connect time
  (metadata even when `SESHAT_ALLOW_LOCAL_TARGETS=1`), and the host is also checked when the channel is
  saved. A blocked target is a permanent failure.
* **Injection.** Email addresses with CR, LF or NUL are refused, the subject and every header value are built
  from parsed or sanitised text, and the body is quoted-printable (a leading dot cannot end the DATA).
  IRC strips CR, LF and NUL (and other control characters) from every field, and every configured nick,
  target, key and password is checked when saved. HTTP header values from templates have control characters
  removed; custom header lines are validated by name.

## Email

The client is written for this package (about 250 lines): `net/smtp` is frozen, cannot take a connection
that was dialled through the netguard guard, and has no deadline. It does EHLO, STARTTLS (required unless
`security` is `none`), AUTH PLAIN or LOGIN, MAIL/RCPT/DATA and QUIT. If some recipients are refused the mail
goes to the others and the failure is reported.

## IRC

**First design: a short-lived connection per batch of notifications.** Each delivery pass for the channel
connects, registers, joins, says the lines, sends `QUIT` and closes. There is no session to keep alive, no
reconnect logic and no state shared between replicas. The cost is a login per batch; a pass sends up to 20
notifications over one connection.

* A server password needs TLS, the target is at most 64 characters, and a transport failure fails only the
  messages not yet written (earlier ones stay delivered).
* Registration: optional `PASS`; `CAP REQ :sasl` and `AUTHENTICATE PLAIN` when SASL is on (TLS required);
  `PING` is answered at any point, including during registration; a nick in use (433) is retried with a
  `_` suffix up to three times; a banned or erroneous nick, a refused server password and a SASL failure
  are permanent.
* Channels (`#`, `&`, `+`, `!`) are joined with the key if set and the pass waits for the end of the names
  list; a nick target is messaged without joining. `NOTICE` by default.
* Flood control: a pause (`flood_delay_ms`, default 600) between lines, at most `max_lines` (default 6)
  lines per notification with the rest cut (`(more lines cut)`), lines split under 512 bytes on character
  boundaries.

## API

All under `/api/alerting`. Administrators and operators change, viewers read, the `user` role and tokens of
other roles get 403. Every change is audited (`alert.channel.create|update|delete|test`, without secrets).

| Route | |
|-------|-|
| `GET /channel-types` | The form schema: per type its label, fields (`name`, `label`, `kind`, `required`, `secret`, `default`, `help`, `options`) and default templates, plus the severities and the template data and functions |
| `GET /channels`, `GET /channels/{id}` | Channels with secrets masked and the delivery state (`last_success_at`, `last_error`, `needs_attention`, counters) |
| `POST /channels`, `PUT /channels/{id}`, `DELETE /channels/{id}` | Create, update (`***` keeps a secret), delete (the outbox goes with it) |
| `POST /channels/{id}/test` | Real delivery of a test notification; `{"ok":false,"error":"..."}` carries the redacted error text |
| `POST /channels/test` | The same for a channel that is not saved yet (a secret cannot be `***` there) |
| `GET /channels/{id}/deliveries`, `GET /deliveries` | Delivery history |

A panic inside a delivery fails that row (`internal`) and is logged; it does not stop the process.

Validation errors are `400 validation_failed` with a `fields` object keyed by the form field names.

## In the console

The Alerts page (Channels tab) generates each channel's form from `GET /api/alerting/channel-types`, so a new type needs no UI
code. Stored secrets are never shown; leaving a secret field empty keeps it. If you change where the channel sends (the address,
the server, any other setting), the form asks for every kept secret again before it saves, matching what the API enforces.
