# Securing Punch Applications

Applies to Punch 0.1.

Most security mistakes in web apps are not exotic. They are an unescaped value in a page, a value pasted into SQL, a form another site can submit, a secret in a log, an operation nobody remembered to protect. Punch is built so that each of these is a type error, a failed check, or not possible at all, and so that a convention you break is reported before the code ships. This guide is the overview: what Punch does for you, what remains yours, and where each topic is covered in depth.

After reading this guide, you will know:

- the threats Punch handles for you, and how;
- the threats it cannot handle, which stay yours;
- which checks fail when a convention is broken;
- what to check before an app goes live.

Before you start: this guide links to the security guides for the details: [Authentication](authentication.md), [Authorization and Roles](authorization-and-roles.md), [Credentials and Keys](credentials-and-keys.md), and [Rate Limits](rate-limits.md).

## What Punch does for you

| Threat | What Punch does | Where |
|---|---|---|
| Cross-site scripting | every text and attribute value in a page is escaped; markup as-is needs a `SafeHTML` from a literal; a Content-Security-Policy blocks inline scripts | [Views and pages](../views.md#the-view) |
| SQL injection | values are bound parameters; SQL text from a value is reported; sorts and filters are declared choices | [Keeping SQL Safe and Fast](keeping-sql-safe-and-fast.md) |
| Cross-site request forgery | Commands from another site's pages are refused by the browser's `Sec-Fetch-Site` and `Origin` headers, without tokens to forget | [Authentication](authentication.md#requests-from-other-sites) |
| Stolen sessions and tokens | random values, stored only as digests; `__Host-` cookies, `Secure`, `HttpOnly`, `SameSite=Lax` | [Authentication](authentication.md#sessions-and-api-tokens) |
| Password cracking and guessing | PBKDF2 at 600,000 iterations, outside the transaction; the same answer for every refused sign-in; durable limits per address | [Authentication](authentication.md#checking-a-password), [Rate Limits](rate-limits.md) |
| Missing access checks | every operation declares a policy or `@[Punch::Public]`, or does not compile; Commands need a grant | [Authorization and Roles](authorization-and-roles.md) |
| Leaked secrets | `Punch::Secret` prints as `[REDACTED]` and does not serialize; credentials are encrypted at rest; key files are never committed | [Credentials and Keys](credentials-and-keys.md) |
| Abuse of open endpoints | every Command without a signed-in user is rate limited, or says why not | [Rate Limits](rate-limits.md) |
| Harmful uploads | files bypass the app and are served from the storage's origin; a kind takes only types Punch can check, never HTML, SVG, or script; a scanned kind's files get no link until your scan passes them | [Uploading Files](uploading-files.md) |
| Forged webhooks | by default (`:edge`) signatures checked before anything is stored; `:deferred` stores first and checks in the job, `:none` never checks; duplicates processed once | [Inbound Webhooks](inbound-webhooks.md) |
| Clickjacking, sniffing, referrer leaks | security headers on every response | below |

### Escaping is the default

A page is written element by element, and every value in it is text: `v.p customer.name` escapes whatever the name holds. There is no template language in which to forget a filter. The only way to write markup as it is goes through `Punch::SafeHTML.trusted`, which takes a string literal; `punch check` reports anything else (`Punch/TrustedHTML`), whatever name or macro the call goes through, and so it does a `text/html` response built by hand. Inline event handlers and `style` attributes are not offered, and the Content-Security-Policy would block them anyway.

### Security headers

Every response carries:

| Header | Value |
|---|---|
| `Content-Security-Policy` | `default-src 'self'`, with the hashes of the import map and Turbo's progress bar; `base-uri 'none'; object-src 'none'; frame-ancestors 'none'; form-action 'self'` |
| `X-Content-Type-Options` | `nosniff` |
| `X-Frame-Options` | `DENY` |
| `Referrer-Policy` | `strict-origin-when-cross-origin` |
| `Strict-Transport-Security` | `max-age=63072000`, when the request came over HTTPS through a trusted proxy |

With uploads in a bucket, the policy also allows that bucket for `connect-src`, `img-src`, and `media-src`. An app can change or remove a header for the whole app ([HTTP kernel](../http.md)).

### Uploads go around the app

[Uploading Files](uploading-files.md) has the whole path. Multipart requests are refused with 415 before any handler runs. Files go from the browser straight to object storage through a URL signed for one file of the size and type the app allowed; Punch checks what arrived by its size, type, and first bytes before the app may keep it, and the storage, not the app, serves it ([Uploads](../uploads.md)). A file's name is cleaned before the app sees it, and a name that is personal data stays encrypted in a `PrivateFile`. A kind with `scan: true` keeps its files from people until your job has scanned them.

## What remains yours

Punch cannot know the app's rules. These are yours:

- **Who may do what.** A policy decides, but you write it. A policy that returns `allow` for everyone compiles. Test each one through its operations, with users who may and users who may not ([Authorization and Roles](authorization-and-roles.md#testing)).
- **Lists.** A policy decides about one call; a list query must select only what the viewer may see.
- **What `@[Punch::Public]` exposes.** Public means anyone on the internet.
- **What a signed link reveals.** Signing does not hide its payload. Sign IDs, never secrets.
- **What leaves through your own code.** A secret unwrapped and put into a result, a mail, or another system's request is out of Punch's hands.
- **What is in a file.** Punch reads a file's first bytes and no further. Scanning is your job, and so is what a tool that opens a file can reach ([Uploads: Processing uploaded files](../uploads.md#processing-uploaded-files)).
- **Personal data.** Stored webhook bodies, idempotency answers, file names, and the app's own tables can hold it. Know what you keep, and for how long.
- **Calls to other systems.** What a job sends to a provider, and what it trusts in the answer.
- **Your dependencies and your server.** Shards you add, the operating system, the proxy's TLS settings.

## The checks that fail

When a convention is broken, something fails before the code ships:

| Broken convention | Caught by |
|---|---|
| an operation without a policy or `@[Punch::Public]` | the compiler; `punch check`, step `policies` |
| a Command open to anyone without a limit | the compiler; `punch check`, step `limits` |
| a Command with a policy called without a grant | the compiler |
| SQL text built from a value | `punch check`, lint `Punch/SQLText` |
| a `LIKE` on user text without `ESCAPE` | `punch db:generate` |
| markup from data instead of elements | `punch check`, lint `Punch/TrustedHTML` |
| reading `ENV` instead of declaring a credential | `punch check`, lint `Punch/EnvAccess` |
| checking a password around `PasswordCheck` (`verify_now`) | `punch check`, lint `Punch/PasswordCheck` |
| reading another slice's tables | `punch check`, lint `Punch/SliceBoundary` |
| a `Punch::Secret` serialized, cached, or on a span | the compiler |
| a committed or unignored key file | `punch check`, step `creds` |
| a provider without verification | `punch check` lists it, `punch webhooks` too |
| a sign-in without a per-address limit | the compiler |
| a file's key or scan state taken from a request | the compiler |
| a kind of upload that takes HTML, SVG, or script | the compiler |
| a private file's name in an answer or a job payload | the compiler |

Never make a check pass by loosening it: an exemption, a `@[Punch::Public]`, or a disabled lint rule is a statement that the convention does not apply here. Write each one with a true reason, or fix the code.

## Behind a proxy

A Punch app runs behind a reverse proxy that terminates TLS. Two settings make it see the real client:

- `PUNCH_TRUSTED_PROXIES` lists the proxies whose `X-Forwarded-For` and `X-Forwarded-Proto` are believed. Nothing is trusted by default, and `0.0.0.0/0` is refused, since it would let any client choose its address. Without it, every client looks like the proxy, and limits by address count the proxy.
- The proxy must pass the original `Host`, which the cross-site check compares with `Origin`.

The recipes `punch new` writes set both ([Deployment](../deployment.md)).

## Before going live

- [ ] `PUNCH_ENV=production`, `PUNCH_MASTER_KEY` set from a secret store, `PUNCH_PUBLIC_URL` set to the HTTPS address.
- [ ] `PUNCH_TRUSTED_PROXIES` names exactly the proxy in front of the app.
- [ ] Every production value is set with `punch creds:set --env production`, and `bin/<app> creds:check --env production` passes.
- [ ] Production credentials are started, once, before the first deploy: `punch creds:init --env production`, then `punch keys:rotate --env production` for the key ring.
- [ ] Every `@[Punch::Public]` and `@[Punch::RateLimitExempt]` has been read again, with its reason.
- [ ] Each policy has a spec with a user who may and one who may not, including one from another organization.
- [ ] Backups are on, and a restore drill has passed ([Backup and Restore](backup-and-restore.md)).
- [ ] An upload bucket is private, with keys of its own and a lifecycle rule on `pending/` ([Uploading Files](uploading-files.md#settings-and-the-bucket)).
- [ ] An operator holds `Accounts::Roles::Operator`, given on the box, and nobody else does.
- [ ] `punch check` passes, with no step skipped that applies.

## Common mistakes

**Marking an operation public to make it compile.** An operation without a policy does not compile:

```text message=src/punch/routing.cr
Error: Notes::Index needs a policy, @[Punch::Authorize(Policy)], or @[Punch::Public]: an operation without either would run for anyone (lib/punch/docs/authorization.md).
```

`@[Punch::Public]` makes the message go away and opens the operation to anyone on the internet. Write the policy that says who may run it, and keep `@[Punch::Public]` for what really is public, such as a sign-in form.

**Exempting an open Command from rate limits without a reason.** A Command that runs without a signed-in user needs a limit:

```text message=src/punch/routing.cr
Error: Notes::Create is a Command that runs without a signed-in user, so it needs a rate limit, @[Punch::RateLimit(5, per: 1.minute, by: :ip)], or @[Punch::RateLimitExempt("reason")] (lib/punch/docs/rate-limits.md).
```

Give it `@[Punch::RateLimit(...)]` ([Rate Limits](rate-limits.md)). `@[Punch::RateLimitExempt("reason")]` is for a Command something else protects, such as a provider's signature, and its reason is read in review.

**Unwrapping a secret to put it in a result.** A `Punch::Secret` does not serialize, so returning one does not compile:

```text message=src/punch/core/secret.cr
Error: Punch::Secret cannot be serialized to JSON. Call `unwrap` explicitly if the value really must leave the process (lib/punch/docs/core-types.md).
```

Calling `unwrap` and returning the `String` compiles, and sends the secret to whoever called the operation. Return what the caller needs to know about the secret, such as when it was made, never the value.

**Markup from data through `SafeHTML.trusted`.** `punch check` reports it (`Punch/TrustedHTML`):

```text message=src/punch/ameba/trusted_html.cr
`SafeHTML.trusted` takes a string literal; build markup from data with the view's elements, which escape (lib/punch/docs/views.md)
```

Build the markup with the view's elements. Disabling the rule on that line says the value can never come from a user; write that only when it is true.

## Limits

- Punch 0.x has not yet had an independent security review.
- Column encryption covers the fields you map as `Punch::Encrypted(T)` ([Column Encryption and Blind Indexes](column-encryption.md)), nothing else; a column converted from plaintext needs the clean-up steps there, and old backups keep what they held. Everything else relies on the backup bucket's encryption at rest.
- There are no passkeys and no API token scopes.

## Rules

- Write pages with elements; never build markup from data. ([Escaping is the default](#escaping-is-the-default))
- Bind every value in SQL. ([The checks that fail](#the-checks-that-fail))
- Give every operation a policy, and every open Command a limit; test each policy with users who may not. ([What remains yours](#what-remains-yours))
- Keep secrets in `Punch::Secret` and credentials; never read `ENV`. ([The checks that fail](#the-checks-that-fail))
- Never take a file's key or scan state from a request. ([The checks that fail](#the-checks-that-fail))
- Never loosen a check to make it pass. ([The checks that fail](#the-checks-that-fail))
- Set `PUNCH_TRUSTED_PROXIES` to exactly the proxy in front of the app. ([Behind a proxy](#behind-a-proxy))

## Reference

- [HTTP kernel](../http.md): security headers, body limits, and proxies.
- [Assets](../assets.md#content-security-policy): the Content-Security-Policy and its hashes.
- [Views and pages](../views.md): escaping and `SafeHTML`.
