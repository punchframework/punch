# Rate limits

Learn it in: [Rate Limits](guides/rate-limits.md).

How often an operation may run for one key. Declared on the operation, counted by GCRA, answered with 429.

```crystal
@[Punch::RateLimit(5, per: 1.minute, by: :ip)]
@[Punch::RateLimit(20, per: 1.hour, by: :email, store: :durable)]
struct Accounts::Sessions::Create < Punch::Command
  struct Input
    include Punch::Input

    getter email : Punch::Email
    getter password : Punch::Auth::Password
  end

  def call(input : Input, db : Punch::Writer, auth : Punch::Auth::Authentication, password : Punch::Auth::PasswordCheck,
           events : Punch::Events(Punch::Auth::SignInSucceeded | Punch::Auth::SignInFailed)) : Output
    # ...
  end
end
```

## Declaring a limit

| Argument | Means |
|---|---|
| first | how many requests, a positive number |
| `per:` | the period, such as `1.minute` |
| `by:` | the key: `:ip`, `:actor`, `:token`, or a field of the input |
| `store:` | `:memory` (default) or `:durable` |
| `name:` | defaults to the operation and the key, `accounts.sessions.create.ip`; unique in the app |

- **`:ip`** is the client address, behind a trusted proxy the forwarded one (`PUNCH_TRUSTED_PROXIES`, `docs/http.md`). IPv6 counts by /64, since one client usually holds the whole prefix. Checked before the body is read.
- **A field** (`:email`) is checked after the input parsed, by the field's text, so an email address counts once in any case. An absent optional field is not limited. Limiting a sign-in by the address being tried stops guessing spread over many clients.
- **`:actor`** is the signed-in user, **`:token`** the API token a request came with (not checked for a session). Both need the operation to take the app's actor; they are checked after authentication, inside the transaction, so a refused Command writes nothing.
- A key that is not one of these, `:actor` without an actor, and a limit together with an exemption do not compile.

Several limits on one operation are all checked, in order; the first that refuses answers.

## Stores

| Store | Where | For |
|---|---|---|
| `:memory` | this process, in 16 locked shards, at most 100,000 keys per limit (recovered keys go first when full, then the half closest to recovery) | throttles: per address, per user, per token |
| `:durable` | the `punch_rate_limits` table in `cache.db`, one small write per check | security limits: sign-in, reset and sign-in links per address, second-factor codes, password changes and re-authentication, token creation. Survives restarts, shared by two processes |

A limit per address can be used against its owner: anyone who knows a user's address can spend its sign-in budget (one request every 90 seconds keeps the template's sign-in limit full), and the password stops working for them until it recovers. A mailed link (reset or sign-in) still works, and the limit applies per address, so other users are not touched. Every alternative, such as a budget per address and client network, gives an attacker with many networks more guesses.

`cache.db` is not replicated, so durable limits start over after a restore. Durable limits do not depend on the cache being on: `PUNCH_CACHE=off` turns off caching, not limiting.

## The algorithm

GCRA keeps one time per key: when the key will be back to its full limit. Each allowed request moves it by period / limit. A key may make `limit` requests at once, then one per period / limit; there is no burst at a window's edge, as fixed windows have. `5 per 1.minute` allows five at once and then one every 12 seconds.

## Answers

A refused request gets **429** with `Retry-After` (seconds):

```json
{"type": "about:blank", "title": "Too Many Requests", "status": 429, "code": "rate_limited",
 "retry_after": 12, "limit": "accounts.sessions.create.ip", "request_id": "…"}
```

A browser (`Accept: text/html`) gets Punch's problem page instead; a refused form is shown again with `rate_limited` as the form's error when the limit is `:actor` or `:token`.

Every request to a limited operation gets `RateLimit-Policy` (every limit checked, `"name";q=5;w=60`) and `RateLimit` (the limit with the fewest requests left, `"name";r=3;t=24`), as in draft-ietf-httpapi-ratelimit-headers, which is still a draft. The wide event records `punch.rate_limit` and the outcome `rate_limited`. `openapi.json` documents the 429, naming the limits, on every limited operation.

## Every unauthenticated Command is limited

The build fails, at the Command, when a Command that runs without a signed-in user (no actor, or an optional one) has no limit (`punch check`, step `limits`, still reports it in the same words). A Command that must stay open says why:

```crystal
@[Punch::RateLimitExempt("signed by the payment provider, which retries")]
struct Payments::Receive < Punch::Command
```

Queries and pages need no limit, and `punch check` does not ask for one. Give one to a public Query or page that costs more than a few reads, a text search or a long list, with `@[Punch::RateLimit(60, per: 1.minute, by: :ip)]`: the `:ip` limit runs before any work.

## Outside operations

`Punch::RateLimits::Limiter` is a plain object, for jobs and outbound calls:

```crystal
GEOCODER = Punch::RateLimits::Limiter.new("geocoder", 10, per: 1.second)

case result = GEOCODER.check("global")
in Punch::RateLimits::Limiter::Allowed then lookup
in Punch::RateLimits::Limiter::Limited then retry_in(result.retry_after)
end
```

`reset(key)` lets a key start over; `keys` counts keys that are limited or recovering.

## Commands

| Command | Does |
|---|---|
| `bin/app limits` | every operation's limits and exemptions; for durable limits the keys held in `cache.db` |
| `bin/app limits:reset NAME [KEY]` | lets one key, or every key, of a durable limit start over, such as a user locked out of signing in. Memory limits reset with the server |
| `bin/app routes` | shows `(limited: …)`; `--json` has `rate_limits`, `actor`, and `rate_limit_exempt` |

All take `--json`.

## Specs

Every example starts with every key at its full limit. `Punch::Spec.clock` stops time, so a spec can let a limit recover:

```crystal
clock = Punch::Spec.clock
5.times { client.post(Accounts::Sessions::Create.path, json: attempt) }
client.post(Accounts::Sessions::Create.path, json: attempt).should be_rate_limited("accounts.sessions.create.ip")
clock.advance(12.seconds)
client.post(Accounts::Sessions::Create.path, json: attempt).status.should eq(HTTP::Status::OK)
```

## In action blocks

An agent-readable page states each limit of an operation in its action block, `at most 30 per 1 h per user` (`docs/views.md`).

## Not yet

- The ops console's list of the most limited keys, and a `RateLimitExceeded` event for alerting.
- A recurring purge of recovered durable keys; until then every 1,024th durable check of a limit removes them.
