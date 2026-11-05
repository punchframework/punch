# Authentication

Learn it in: [Authentication](guides/authentication.md).

Who a request acts for. Punch has the primitives: sessions, API tokens, one-time tokens, email identities, password hashing, the cross-site check, and the actor in the request. Sign-up, sign-in, and the other flows are the app's own operations over them; the reference app's `app/accounts/` is the slice to copy, mail-based flows included.

Sessions and tokens are random values stored as a SHA-256 digest. A leaked database or replica holds nothing that signs anyone in, every session and token can be listed and revoked one by one, and none depends on the key ring, so rotating keys signs nobody out.

## Tables

The tables are in the app's own migrations, so they can reference its users table and go with a deleted user. Their columns are Punch's. `punch db:migration --punch auth [--users TABLE]` writes the migration (the SQL is `Punch::Auth::Schema.sql("users")`), and `punch check` compares the tables in `db/schema.sql` with what this Punch expects (step `punchtables`); `serve` refuses to start when a column is missing or of another type.

```sql
CREATE TABLE punch_sessions (
  id               INTEGER PRIMARY KEY,
  token_hash       BLOB    NOT NULL UNIQUE,
  user_id          INTEGER NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  method           TEXT    NOT NULL,
  authenticated_at TEXT    NOT NULL,
  created_at       TEXT    NOT NULL,
  last_seen_at     TEXT    NOT NULL,
  expires_at       TEXT    NOT NULL,
  ip               TEXT,
  user_agent       TEXT
) STRICT;

CREATE INDEX punch_sessions_by_user ON punch_sessions (user_id);

CREATE TABLE punch_api_tokens (
  id           INTEGER PRIMARY KEY,
  token_hash   BLOB    NOT NULL UNIQUE,
  user_id      INTEGER NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  name         TEXT    NOT NULL,
  created_at   TEXT    NOT NULL,
  expires_at   TEXT    NOT NULL,
  last_used_at TEXT
) STRICT;

CREATE INDEX punch_api_tokens_by_user ON punch_api_tokens (user_id);

CREATE TABLE punch_one_time_tokens (
  token_hash BLOB    PRIMARY KEY,
  purpose    TEXT    NOT NULL,
  user_id    INTEGER REFERENCES users (id) ON DELETE CASCADE,
  subject    TEXT,
  created_at TEXT    NOT NULL,
  expires_at TEXT    NOT NULL
) STRICT, WITHOUT ROWID;

CREATE INDEX punch_one_time_tokens_by_user ON punch_one_time_tokens (user_id, purpose);
```

The migration also creates `punch_email_identities` and `punch_passwords` (`Punch::Auth::Schema.identities_sql("users")` alone, for apps that have the other tables already):

```sql
CREATE TABLE punch_email_identities (
  id          INTEGER PRIMARY KEY,
  user_id     INTEGER NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  email       TEXT    NOT NULL UNIQUE,
  verified_at TEXT,
  created_at  TEXT    NOT NULL
) STRICT;

CREATE INDEX punch_email_identities_by_user ON punch_email_identities (user_id);

CREATE TABLE punch_passwords (
  user_id    INTEGER PRIMARY KEY REFERENCES users (id) ON DELETE CASCADE,
  hash       TEXT    NOT NULL,
  created_at TEXT    NOT NULL,
  updated_at TEXT    NOT NULL
) STRICT;
```

The users table is the app's and holds no secrets and no sign-in columns. Never query the `punch_` tables from app SQL; use the functions below.

## The actor

The app declares one type that includes `Punch::Auth::Actor` and loads itself from a `Punch::Auth::Principal` (the user ID and the session or token that proved it):

```crystal
struct Invoicing::Actor
  include Punch::Auth::Actor

  getter user : Accounts::Users::Record
  getter principal : Punch::Auth::Principal

  def initialize(@user, @principal)
  end

  # nil when the user no longer exists
  def self.load(principal : Punch::Auth::Principal, db : Punch::Reader | Punch::Writer) : self?
    Accounts::Users::Table.find(db, principal.user_id(Accounts::Users::ID)).try { |user| new(user, principal) }
  end
end
```

An operation asks for it in `call`, after the input and the handle, by type:

```crystal
def call(input : Input, db : Punch::Writer, actor : Invoicing::Actor) : Result   # signed in, else 401
def call(input : Input, db : Punch::Reader, actor : Invoicing::Actor?) : Result  # anyone
def call(input : Input, db : Punch::Reader) : Result                             # does not look
```

- The session or token is looked up and the actor loaded **in the operation's own transaction**, so the operation sees the user as of the same snapshot, and a Command's write cannot race a revocation.
- Without a session cookie or `Authorization` header, an operation that needs an actor answers 401 before opening a transaction. A 401 carries `WWW-Authenticate: Bearer`, and `Bearer error="invalid_token"` when a token was presented.
- A bearer token that does not work is refused with 401 even where the actor is optional: the client meant to authenticate.
- **Browsers go to the sign-in page.** A page or form that needs an actor answers a browser without one with `303 See Other` to the app's sign-in page, once the app names it at boot: `Punch::Pages.sign_in = Accounts::Sessions::CreatePage.href` in `app/setup.cr`. Without one, and for any request that presented a bearer token, the answer is the 401 page. JSON clients always get the 401. The browser is not brought back to where it was after signing in; the sign-in page's `redirect` decides where it lands.
- `load` returning `nil` counts as no actor.
- The request's wide event gets `user.id` and `punch.auth` (`session`, `token`, `expired`, `refused`).
- `openapi.json` lists the `session` and `bearer` security schemes on each operation that takes an actor, `{}` as well where it is optional, and the 401 problem.

Any other extra parameter, an untyped one, two actors, or `Punch::Auth::Authentication` in a Query does not compile.

## Sessions

A session is a row in `punch_sessions`; its ID travels in the cookie `__Host-session`: `Path=/; Secure; HttpOnly; SameSite=Lax`, kept by the browser until the session's lifetime ends. The `__Host-` prefix makes browsers refuse a cookie from a subdomain or without `Secure`.

| Setting (`Punch::Auth::Config`) | Default | |
|---|---|---|
| `session_idle_timeout` | 7 days | Ends after this long without a request |
| `session_lifetime` | 30 days | Ends this long after sign-in, whatever happens |
| `touch_interval` | 5 minutes | The last-seen time is written at most this often |
| `token_prefix` | `punch` | Start of every API token: `inv_…` |
| `token_max_lifetime` | 366 days | An API token must expire within this span |

```crystal
Punch::Auth.config = Punch::Auth::Config.new(token_prefix: "inv")
```

A Command that signs in or out takes `Punch::Auth::Authentication`:

```crystal
def call(input : Input, db : Punch::Writer, auth : Punch::Auth::Authentication) : SignedIn | Rejected
  # ... check the password
  auth.sign_in(user.id, method: "password")
  SignedIn.new
end
```

- `sign_in(user_id, method:)` creates a session and ends the one the request came with, so a session ID never survives a sign-in.
- `sign_out` deletes the session and clears the cookie.
- `renew(method: nil)` gives the session a new ID after a change of privilege; with `method`, the user has just proved who they are again, and `authenticated_at` moves.
- Cookie changes reach the response only if the Command commits.

`Punch::Auth::Sessions` works on any handle: `list`, `revoke(id)`, `revoke_all(user_id, except:)` (after a password change), `purge` (expired rows; the recurring job `Auth::Purge` runs it hourly). A cookie that names no live session is cleared in the response.

## API tokens

For API clients and agents: `Authorization: Bearer inv_<49 characters>`. A token acts as its user, always expires, is shown once, and records when it was last used.

```crystal
case created = Punch::Auth::APITokens.create(db, user.id.value, "CI deploy", Time.utc + 90.days)
in Punch::Invalid                                 then # blank, too_long, out_of_range
in Tuple(Punch::Auth::APIToken, Punch::Secret(String)) then token = created[1].unwrap # show once
end
```

The token is the prefix, 256 random bits in base62, and a CRC-32 checksum: a mistyped or made-up token is refused without a lookup, and secret scanners can recognize a real one. `find`, `list`, `revoke(id, user_id:)`, `revoke_all`, `purge`.

### Tokens for agents

Users make tokens for their agents and scripts themselves, on a page of the app. The reference app's `app/accounts/tokens/` is the slice to copy:

| Operation | Does |
|---|---|
| `Tokens::Index`, `GET /accounts/tokens` | The user's live tokens: name, created, last used, expiry, and whether the request came with it; never the token |
| `Tokens::IndexPage`, the same path in a browser | The list with a Revoke button per token, the form for a new one, and a new token once, right after it was made |
| `Tokens::Create`, `POST /accounts/tokens` | A name and a lifetime the page offers (7, 30, 90, or 366 days); 201 with the token in `secret` for a JSON client |
| `Tokens::Destroy`, `DELETE /accounts/tokens/:token_id` | Revokes one: the next request with it is a 401 |

- **Making one needs a recent sign-in** (`Punch::RecentlyAuthenticated`): an API token can never qualify, so a token cannot make another token, and a session left open for a while asks for the password again. Limited per user in the durable store, as security limits are (`docs/rate-limits.md`).
- **The user is told** by mail when a token is made (`Accounts::TokenCreated`, `Tokens::NotifyCreated`), and a password reset revokes every token: whoever knew the old password may have made one.
- **A token sees and does what its user may** (no scopes); revoking it or letting it expire is the control. Revoking is the `Own` policy: another user's token is not found.
- **Expiry is mandatory** (`Auth::Config#token_max_lifetime`, 366 days); expired rows go with the hourly purge.

### Showing a new token once

A form's success is a `303 See Other`, which Turbo Drive requires, so the page that shows the new token is a second request. `Punch::Auth::Reveal` carries the token there: a Command takes `reveal : Punch::Auth::Reveal` and calls `reveal.once(secret)`; the page the browser lands on takes one too and calls `reveal.take`:

```crystal
def call(input : Input, db : Punch::Writer, actor : Invoicing::Actor, reveal : Punch::Auth::Reveal, _grant : Punch::Grant(Create)) : Created | Punch::Rejection
  ...
  reveal.once(secret)                        # for the browser, on the next page
  Created.new(Entry.new(token), secret.unwrap) # for a JSON client, in the answer
end

# IndexPage
def call(input : Input, db : Punch::Reader, actor : Invoicing::Actor, reveal : Punch::Auth::Reveal) : ListView
  ListView.new(..., reveal.take.try(&.unwrap))
end
```

- **A cookie, not a row:** after the Command committed, the browser gets `__Host-reveal` (`Secure; HttpOnly; SameSite=Strict`, one minute: enough for the redirect to the page that shows it), the token encrypted with the key ring (purpose `punch.reveal`) together with the session's ID and the expiry. Nothing is stored on the server; the token's row holds only its digest, as before.
- **Once:** the page that takes it clears the cookie, whatever it held. Another session, an altered or expired cookie, or no cookie: `take` is `nil`. A failed Command sets nothing. A bearer client gets no cookie: the token is in its answer.
- **No idempotency key:** a Command that takes `Punch::Auth::Reveal` refuses `Idempotency-Key` (400 `idempotency_key_not_accepted`), and `@[Punch::Idempotency]` on it does not compile, because the stored answer would hold the token. Only Commands and pages take it, and only with the app's actor.

## One-time tokens

For password reset, email verification, and magic links: random, single use, with a purpose and an expiry.

```crystal
token = Punch::Auth::OneTimeTokens.issue(db, "password_reset", 1.hour, user_id: user.id.value) # Secret(String), for the link only
Punch::Auth::OneTimeTokens.find(db, "password_reset", token)    # the page behind the link: look, do not use
Punch::Auth::OneTimeTokens.consume(db, "password_reset", token) # the Command behind its button: works once
```

Mail scanners fetch links before people click them, so the page behind a link only `find`s its token and shows a button; the Command `consume`s it. `subject` records what a token vouches for beyond the user, such as the address a verification was sent to; compare it with the current value when the token is used. `revoke_all(purpose, user_id)` withdraws older links.

## Identities and passwords

Three things are kept apart: the **user** (the app's table: who someone is), the **identity** (an email address they are known by, verified or not), and the **authenticator** (what proves it is them: a password; TOTP later). A user can have several identities, and a user without a password is normal.

```crystal
Punch::Auth::EmailIdentities.add(db, user.id, email)  # EmailIdentity | EmailIdentities::EmailTaken (422, taken at email)
Punch::Auth::EmailIdentities.find(db, email)          # whoever's it is
Punch::Auth::EmailIdentities.list(db, user.id)
Punch::Auth::EmailIdentities.verify(db, email)        # from a verification, reset, or sign-in link
Punch::Auth::EmailIdentities.verified?(db, user.id)   # whether any address of the user is verified
Punch::Auth::EmailIdentities.remove(db, user.id, id)  # EmailIdentity | LastSignInMethod (409) | nil (not theirs)
Punch::Auth::Passwords.set(db, user.id, input.password.hashed)
Punch::Auth::Passwords.set?(db, user.id)
```

**An account belongs to an address's owner only once they follow a link.** Anyone can sign up with someone else's address, so the template's sign-in refuses a password for an account with no verified address (`verified?`, 403 `not_verified`). The first address an account verifies ends what came before it: `verify` then deletes the user's other unverified addresses and revokes every session and API token, whatever someone who signed up with the address first may have set up.

**A user keeps one way to sign in.** `Auth::EmailIdentities.remove` refuses, inside the Command's transaction, to take a user's last address, and once one of them is verified, their last verified address (an unverified one may be mistyped): `Punch::Auth::LastSignInMethod`, 409 `last_sign_in_method`, which rolls the Command back. Add and verify another address first.

### Password fields

| Type | For | Parsing |
|---|---|---|
| `Punch::Auth::Password` | Signing in | NFKC, surrounding spaces kept, not blank, at most 256 characters (so at most 1,024 bytes); no control characters |
| `Punch::Auth::NewPassword` | Sign-up, change, reset | The same, and at least 12 characters (`too_short`) |

Both print as `[REDACTED]`, do not compile into JSON, have JSON Schema `format: password`, and are written as `<input type="password">` with `autocomplete` `current-password` or `new-password`; a refused form never shows them again. In specs, send them with `submit(..., form: {...})`.

### Hashing happens before the transaction

PBKDF2-HMAC-SHA256 at 600,000 iterations costs about 70 ms. Inside a Command's transaction that would hold the database's one writer, so Punch never does it there. The router does it first, on the hasher (an execution context with its own threads and a bounded queue):

- **A `Auth::NewPassword` field** in a Command's input is hashed before the transaction; `input.password.hashed` is then a `Punch::Auth::PasswordHash`, ready to store. (Outside a request, `hashed` hashes on the calling fiber.)
- **A sign-in** takes `password : Punch::Auth::PasswordCheck` in `call`. Its input must have `email : Punch::Email` and `password : Punch::Auth::Password`, and it must have a rate limit by `:email`; both are compile errors otherwise. Before the transaction, the router looks up the hash behind the address, verifies it on the hasher, and passes the outcome. Inside, `password.confirm(db, Users::ID)` returns the user, after checking that the address still belongs to them and the hash is unchanged; `nil` otherwise.

```crystal
@[Punch::RateLimit(10, per: 15.minutes, by: :email, store: :durable)]
@[Punch::RateLimit(60, per: 1.minute, by: :ip)]
struct SignIn < Punch::Command
  struct Input
    include Punch::Input

    getter email : Punch::Email
    getter password : Punch::Auth::Password
  end

  alias Output = SignedIn | Punch::Auth::InvalidCredentials

  def call(input : Input, db : Punch::Writer, auth : Punch::Auth::Authentication, password : Punch::Auth::PasswordCheck,
           events : Punch::Events(Punch::Auth::SignInSucceeded | Punch::Auth::SignInFailed)) : Output
    user_id = password.confirm(db, Users::ID) || return Punch::Auth::InvalidCredentials.new
    session = auth.sign_in(user_id, method: "password")
    events.publish(Punch::Auth::SignInSucceeded.new(user_id.value, session.id, "password"))
    SignedIn.new(user_id)
  end
end
```

A refused sign-in rolls the Command back, its events with it, so **Punch publishes `Punch::Auth::SignInFailed`** (the address, and its owner when it has one) in a transaction of its own after the Command answered `invalid_credentials`. A Command that takes `Auth::PasswordCheck` must list `SignInFailed` in its `Punch::Events(...)`; otherwise it does not compile.

- **The user's own password** (changing it, and re-authenticating a user without an app): the Command takes `password : Punch::Auth::OwnPasswordCheck`, has `current_password : Punch::Auth::Password` in its input, a required actor, and a rate limit `by: :actor`; all are compile errors otherwise. Before the transaction and before any hashing, a new password's included, the router finds the user from the session (401 without a working session or token) and applies the actor's limits, so neither a stranger nor a limited user causes any; then it verifies on the hasher; inside, `password.confirm(db)` is true when it matched and the stored hash is unchanged.

```crystal
@[Punch::Authorize(Punch::SignedIn)]
@[Punch::RateLimit(10, per: 15.minutes, by: :actor, store: :durable)]
struct Change < Punch::Command
  struct Input
    include Punch::Input

    getter current_password : Punch::Auth::Password
    getter password : Punch::Auth::NewPassword
  end

  alias Output = Changed | Punch::Auth::InvalidCredentials

  def call(input : Input, db : Punch::Writer, actor : App::Actor, auth : Punch::Auth::Authentication, _grant : Punch::Grant(Change),
           password : Punch::Auth::OwnPasswordCheck, events : Punch::Events(...)) : Output
    return Punch::Auth::InvalidCredentials.new unless password.confirm(db)

    Punch::Auth::Passwords.set(db, actor.user.id, input.password.hashed)
    Punch::Auth::Sessions.revoke_all(db, actor.user.id.value, except: auth.session.try(&.id))
    auth.renew # a new session ID after a change of privilege
    ...
```

- **Same answer, same work.** An unknown address, an address without a password, and a wrong password all verify against a hash (a stand-in when there is none) and answer 422 `invalid_credentials`. Sign-up still says `taken` for an address in use; hiding that needs a confirmation mail first.
- **Old parameters are replaced at sign-in.** A hash with fewer iterations than configured verifies, is hashed again on the hasher, and `confirm` stores the new one.
- **A full hasher answers 503** `passwords_busy` with `Retry-After` at once, before any transaction, instead of queueing work. `openapi.json` lists the 503 on every Command that hashes.
- The wide event gets `punch.password` (`valid`, `rehashed`, `invalid`, `busy`); spans `password.hash` and `password.verify` show the time on the hasher.

```crystal
Punch::Auth::Passwords.config = Punch::Auth::Passwords::Config.new(threads: 2, queue: 16)  # the defaults; iterations: at least 600,000
```

Each hashing thread manages about 14 passwords a second. The per-address limit caps the work any one account can cause; the per-IP limit caps one client.

The hash string is versioned (PHC format): `$pbkdf2-sha256$i=600000$<salt>$<hash>`. Raising the iterations is a change of configuration followed by rehashing at each user's next sign-in. The prefix leaves room for another algorithm such as Argon2id, which would need a hasher Punch does not have yet; stored hashes would then move over the same way.

## Second factor

An authenticator app (TOTP, RFC 6238: six digits every 30 seconds) with recovery codes. Once confirmed, signing in takes two steps.

```sql
CREATE TABLE punch_totp_authenticators (
  user_id      INTEGER PRIMARY KEY REFERENCES users (id) ON DELETE CASCADE,
  secret       BLOB    NOT NULL,
  confirmed_at TEXT,
  last_step    INTEGER NOT NULL,
  unseen_codes BLOB,
  created_at   TEXT    NOT NULL
) STRICT;

CREATE TABLE punch_recovery_codes (
  code_hash  BLOB    PRIMARY KEY,
  user_id    INTEGER NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  created_at TEXT    NOT NULL
) STRICT, WITHOUT ROWID;

CREATE INDEX punch_recovery_codes_by_user ON punch_recovery_codes (user_id);
```

`Punch::Auth::Schema.second_factor_sql("users")` returns them for apps that have the other tables. The secret is encrypted with the key ring (`column:punch_totp_authenticators.secret`, the format of column encryption), so the app needs `secret_key_base` in its credentials; keep a retired key in the ring while secrets encrypted with it remain. `keys:rotate --revoke` therefore stops every authenticator app: its secret no longer decrypts (`SecondFactors::Undecryptable`), and the user cannot finish signing in with it until its row in `punch_totp_authenticators` is deleted and they set one up again. Recovery codes are stored as HMACs under the key ring (purpose `punch.recovery_code`), so a copy of the database alone cannot test guesses against them; `keys:rotate --revoke` ends them along with the authenticator's secret.

```crystal
Punch::Auth::SecondFactors.start(db, user.id)           # TOTPSetup | SecondFactorEnabled: a new secret and 10 recovery codes
Punch::Auth::SecondFactors.setup(db, user.id)           # the waiting setup, for an hour: secret_text, href(issuer:, account:), recovery_codes
Punch::Auth::SecondFactors.confirm(db, user.id, code)   # the app's first code: from now on it counts
Punch::Auth::SecondFactors.enabled?(db, user.id)
Punch::Auth::SecondFactors.find(db, user.id)            # TOTPAuthenticator: confirmed_at, recovery codes left, unseen_codes?
Punch::Auth::SecondFactors.regenerate(db, user.id)      # a new set; shown by new_recovery_codes until seen
Punch::Auth::SecondFactors.remove(db, user.id)
```

The code typed is a `Punch::Auth::OneTimeCode`: six digits, or a recovery code (`abcd-efgh-ijkl-mnop`; spaces, hyphens, and case do not matter). Like a password it is redacted, does not serialize, and is not written back into a form; its input has `autocomplete="one-time-code"`. An app's code works once (the last step used is stored), one step either side of now is accepted, and a recovery code is deleted when used.

### Signing in

`auth.sign_in` returns `Punch::Auth::Session | Punch::Auth::SecondFactorRequired`. For a user with a confirmed app there is no session yet: the browser gets a challenge (a one-time token for 10 minutes, `Auth::Config#second_factor_timeout`) in the cookie `__Host-second-factor`, and the session it came with ends. Every sign-in Command handles both, so a magic link is a first step too:

```crystal
case session = auth.sign_in(user_id, method: "password")
in Punch::Auth::SecondFactorRequired then session # the page redirects to the second step
in Punch::Auth::Session              then SignedIn.new(user_id)
end
```

The second step takes `Punch::Auth::SecondFactorCheck`, together with `Punch::Auth::Authentication`, an input with `code : Punch::Auth::OneTimeCode`, and a rate limit `by: :challenge` (per user whose challenge the browser holds); each is a compile error when missing:

```crystal
@[Punch::Public]
@[Punch::RateLimit(5, per: 15.minutes, by: :challenge, store: :durable)]
struct SignIn < Punch::Command
  struct Input
    include Punch::Input

    getter code : Punch::Auth::OneTimeCode
  end

  alias Output = SignedIn | Punch::Auth::InvalidCode | Punch::Auth::SecondFactorExpired

  def call(input : Input, db : Punch::Writer, auth : Punch::Auth::Authentication, second_factor : Punch::Auth::SecondFactorCheck) : Output
    case session = second_factor.sign_in(db, auth)
    in Punch::Auth::InvalidCode, Punch::Auth::SecondFactorExpired then session
    in Punch::Auth::Session                                   then SignedIn.new(session.user_id(Users::ID))
    end
  end
end
```

The session's method names both steps: `password+totp`, `magic_link+recovery_code`. A wrong code (422 `invalid_code`) rolls back and leaves the challenge for another try; without a challenge the answer is 422 `second_factor_expired`.

### Recent authentication

Sensitive changes need a session that proved who the user is within 15 minutes, with the app if the user has one (docs/authorization.md, "Recent authentication"). The app's re-authentication Commands renew the session after a check: `Auth::OwnPasswordCheck` (for users without an app) or `Punch::Auth::OwnSecondFactorCheck` (required actor, input `code`, a limit `by: :actor`):

```crystal
factor = second_factor.confirm(db) || return Punch::Auth::InvalidCode.new
auth.renew(method: factor) # totp or recovery_code
```

Changes to the factor publish `Punch::Auth::SecondFactorChanged` (`Enabled`, `Removed`, `RecoveryCodes`). In specs, `Punch::Spec.second_factor(user.id)` gives a user a confirmed app and returns its secret, and `Punch::Spec.totp_code(secret)` its current code.

## Events

The domain events of authentication are Punch's, so audit trails, the ops console, and notification mails read the same types in every app. The app's Commands publish them; user IDs are plain `Int64`.

| Event | Published by | Fields |
|---|---|---|
| `Punch::Auth::SignInSucceeded` | Sign-in, sign-up, magic-link Commands | `user_id`, `session_id`, `method` |
| `Punch::Auth::SignInFailed` | **Punch**, after a `Auth::PasswordCheck` Command answered `invalid_credentials` | `email`, `user_id` (the address's owner, or `nil`) |
| `Punch::Auth::PasswordChanged` | Change and reset Commands | `user_id`, `reset?` |
| `Punch::Auth::SessionRevoked` | Sign-out, ending a session, password change and reset | `user_id`, `session_id` (`nil`: every other session), `reason` |
| `Punch::Auth::SecondFactorChanged` | Confirming, removing the app, new recovery codes | `user_id`, `change` |

A deferred subscriber mails the notice: `Accounts::Passwords::NotifyChanged` in the reference app.

## The flows that need mail

The reference app's auth slice (`reference/app/accounts/`) is the pattern to copy; every link is a one-time token (above) mailed by a job.

| Flow | Pages and Commands | Token |
|---|---|---|
| Verify an address | Sign-up and `Emails::Create` publish `EmailAdded`; `SendVerification` mails `Emails::VerifyPage`, whose button is `Emails::Verify`. Sign-up does not sign in, and a password signs in only once one of the account's addresses is verified (`EmailIdentities.verified?`, 403 `not_verified`) | `verify_email`, 3 days |
| Reset the password | `Passwords::RequestResetPage` and `RequestReset` (the same answer, and the same write, for every address: a job is enqueued for each, and mails only an account's), `ResetPage` and `Reset` (sets it, verifies the address, ends every session and every API token) | `password_reset`, 1 hour, earlier ones revoked |
| Sign in by mail | `MagicLinks::CreatePage` and `Create`, `SignInPage` and `SignIn` (verifies the address); no account for an unknown address | `magic_link`, 15 minutes, earlier ones revoked |
| Change the password | A form on the account page, `Passwords::Change` with `Auth::OwnPasswordCheck`; ends every other session, and every API token when `revoke_tokens` is checked | |
| Add or remove an address | Forms on the account page, behind a recent authentication (`Punch::RecentlyAuthenticated`); removing honours the invariant above; the other verified addresses, or the removed one, are told | |

Rules the slice follows:

- **The token travels in the query string** (`?token=…`), never in the path: request paths are on every wide event, queries are not. The page behind the link only `find`s it; the Command behind its button `consume`s it, from a hidden field.
- **The token is made by the job,** not the Command, so it exists only in the mail, never in `queue.db`, and a request for an unknown address takes as long as one for a known one.
- **A page that holds such a form takes the token as optional:** a refused form is shown again from the path alone (`docs/views.md`), with the token in the submitted values.

## Cross-site requests

Every Command (any method but GET, HEAD, OPTIONS) from a browser page on another site is refused with 403 `cross_origin_request` before it runs, by request headers instead of form tokens:

1. `Sec-Fetch-Site: same-origin` or `none` passes; `cross-site` and `same-site` fail unless `Origin` is trusted.
2. Without it, `Origin` must match `Host` or be trusted.
3. With neither, the request is not from a current browser's page and passes, unless it carries the session cookie: old browsers (Internet Explorer, Edge's IE mode) send neither header on a cross-site form, but do send the cookie.

Requests with `Authorization: Bearer` are not checked: they carry no ambient credentials (a browser adds other schemes, such as `Basic`, by itself, so those are), and the session cookie is ignored on them. Other origins that may send Commands go in `PUNCH_TRUSTED_ORIGINS` (`https://admin.example.com`, comma-separated). The proxy must pass the original `Host`.

## Commands

In application binaries, against `$PUNCH_STORAGE/primary.db`, all with `--json`:

| Command | |
|---|---|
| `sessions [--user ID]` | Live sessions: ID, user, method, last seen, expiry, IP, browser |
| `sessions:revoke ID \| --user ID` | Ends one session, or every session of a user |
| `tokens [--user ID]` | Live API tokens, never the tokens themselves |
| `tokens:create --user ID --name NAME [--days 30]` | Creates a token and shows it once |
| `tokens:revoke ID` | |
| `passwords` | Hashing settings, and stored hashes counted by parameters (how many still need a rehash) |
| `identities --user ID` | A user's email identities, verified or not, and whether they have a password |

## Testing

```crystal
client = Punch::Spec.client.sign_in(user.id)    # a session in Punch::Spec.db, its cookie in the client
client.get(Accounts::Users::Me.path)

Punch::Spec.password_account(user.id, "ada@example.org", "correct horse battery")  # identity + password
client.submit(Accounts::Sessions::Create.action, form: {"email" => "ada@example.org", "password" => "correct horse battery"})

token = Punch::Spec.api_token(user.id)
Punch::Spec.client.get(Accounts::Users::Me.path, headers: Punch::Spec.bearer(token))
```

The client keeps cookies the app sets and sends them back, as a browser does; `sign_out` forgets them. `sign_in(..., now:)` backdates a session. `punch/spec` hashes with 1,000 iterations, so passwords cost microseconds in specs; the format is the same.

## Not yet

Sign-up still says `taken` for an address in use (hiding it means mailing the existing owner instead); a QR code on the setup page (the `otpauth:` link and the key as text only); token scopes (a token acts fully as its user). Expired rows stay until the hourly `Auth::Purge` removes them.
