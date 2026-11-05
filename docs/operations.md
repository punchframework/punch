# Operations and routing

Learn it in: [Operations and Routing](guides/operations-and-routing.md), [Results, Errors, and Status Codes](guides/results-errors-and-status-codes.md).

An operation is business logic without HTTP. There are two kinds, enforced by types:

| Kind | Receives | Answers |
|---|---|---|
| `Punch::Query` | a `Punch::Reader`, which cannot write | `GET` |
| `Punch::Command` | a `Punch::Writer`, inside one transaction | `POST`, `PATCH`, `DELETE` |

```crystal
module Billing::Invoices
  struct Send < Punch::Command
    struct Input
      include Punch::Input

      @[Punch::PathParam]
      getter invoice_id : ID

      getter recipient : Punch::Email
    end

    alias Output = Sent | NotFound | AlreadySent

    def call(input : Input, db : Punch::Writer) : Output
      # ...
    end
  end
end
# POST /billing/invoices/:invoice_id/send
```

Every operation declares an `Input` (`docs/input.md`), empty if it takes nothing, its `Output`, and a `call`. `Output` is the union of everything `call` can return, an alias right above `call`, which returns `: Output`. The answers are one line to read, in the same place in every operation, and pages and specs can name them (`Send::Output`); Punch derives the route's responses and `openapi.json` from it like from any other return type. `Punch/OperationOutput` reports an operation in app code without it. A Query whose `call` takes a `Writer` does not compile, and neither does a Command whose `call` takes a `Reader`.

## Where operations live

One file per operation, named after it: Queries and Commands in the `operations/` directory of their slice, pages in its `pages/` directory. The name says where the file is, and listing `operations/` lists the slice's API. `Punch/OperationFile` reports a Query, Command, or Page anywhere else under `app/`.

```
app/billing/invoices/
  operations/
    index.cr      Billing::Invoices::Index     GET    /billing/invoices
    show.cr       Billing::Invoices::Show      GET    /billing/invoices/:invoice_id
    create.cr     Billing::Invoices::Create    POST   /billing/invoices
    send.cr       Billing::Invoices::Send      POST   /billing/invoices/:invoice_id/send
    ...
  pages/
    index_page.cr Billing::Invoices::IndexPage GET    /billing/invoices (browsers)
    show_page.cr  Billing::Invoices::ShowPage  GET    /billing/invoices/:invoice_id
    create_page.cr Billing::Invoices::CreatePage GET  /billing/invoices/new
    ...
  inputs.cr       input types several operations take (LineInput)
  results.cr      result types several operations return (Detail, NotFound)
  components.cr   components and helpers several pages render (LinesTable)
  policies.cr     the slice's policies (ByRole)
  invoice.cr      the model (Billing::Invoices::Invoice); store.cr, queries.sql, jobs/ ...
```

- **An operation's file** holds its annotations, `Input`, `Output`, and `call`, and the result types only it returns (`NoLines` in `send.cr`): open one file and see everything the operation can answer. A page's file holds the components only it renders (`DetailView` in `show_page.cr`), and app settings that name it (`Punch::Pages.sign_in` in `sign_in_page.cr`).
- **Shared types** go in the slice's `results.cr` (and `inputs.cr`), shared components in `components.cr`; policies in `policies.cr`. Type names stay at the slice's module (`Billing::Invoices::NoLines`), not inside the operation, so moving a type between files changes neither code nor `openapi.json`.
- **A nested namespace is a nested directory:** `Accounts::Sessions::Destroy` is in `app/accounts/sessions/operations/destroy.cr`, which is also its route's prefix.
- **Requires are generated:** `app/requires.gen.cr` requires every file under `app/` in the order of its kind, so adding an operation, a page, or a slice is adding files (`docs/structure.md`).

## Routes, three rules

1. **The namespace is the path.** `Billing::Invoices` becomes `/billing/invoices`; names are underscored (`LineItems` becomes `line_items`).
2. **Reserved names have REST shapes.** `Index` is `GET`, `Show` is `GET`, `Create` is `POST`, `Update` is `PATCH`, `Destroy` is `DELETE`. `Index` and `Show` must be Queries, the others Commands. Any other name is appended as a segment: `GET` for a Query, `POST` for a Command (`SendReminder` becomes `.../send_reminder`).
3. **Path parameters become segments.** A parameter named `customer_id` goes right after the namespace segment `customers` (or `customer`), so `Billing::Customers::Invoices::Index` with `customer_id` is `GET /billing/customers/:customer_id/invoices`. Other path parameters are appended in declaration order.

`@[Punch::Route("POST", "/webhooks/:provider")]` replaces all three. Its `:name` segments must be exactly the input's path parameters, and a Command cannot take `GET`.

Two operations with the same method and path shape do not compile; the error names both. `punch routes` prints the table, with `--json` for programs.

Operation IDs, used by OpenAPI (`docs/openapi.md`) and markdown action blocks (`docs/views.md`), come from the name: `billing.invoices.send`.

## Matching

- A literal segment wins over a parameter, so `GET /invoices/export` and `GET /invoices/:invoice_id` can coexist.
- Segments are percent-decoded after splitting, so `%2F` stays inside its segment.
- An empty segment never matches: `/invoices/` and `//invoices` are 404.
- A known path with an unknown method is 405 with `Allow`. `HEAD` is answered by the `GET` route.

## Typed URL helpers

```crystal
Billing::Invoices::Send.path(invoice_id: invoice.id)   # => "/billing/invoices/inv_gLW26G63FZp/send"
```

A missing, unknown, or wrongly typed parameter does not compile. Values are escaped; enums appear as their snake_case name, as the input parser reads them.

## Every operation says who may run it

An operation has `@[Punch::Authorize(Policy)]` or `@[Punch::Public]`, and a Command that runs without a signed-in user (no actor, or an optional one) has `@[Punch::RateLimit(...)]` or `@[Punch::RateLimitExempt("reason")]`. Without them the app does not compile; the error is at the operation's `call` (docs/authorization.md, docs/rate-limits.md). Specs' fixture operations declare them too.

## What `call` takes

Besides the input and the handle, `call` takes (in any order, recognized by type): the app's actor (`Punch::Auth::Actor`, nilable when optional), `Punch::Grant(Op)`, `Punch::Locale`, and in a Command `Punch::Auth::Authentication`, `Punch::Auth::PasswordCheck`, `Punch::Auth::OwnPasswordCheck`, `Punch::Auth::SecondFactorCheck`, `Punch::Auth::OwnSecondFactorCheck`, `Punch::Events(...)`, `Punch::Jobs(...)`, `Punch::RawRequest`; in a Command or page `Punch::Auth::Reveal`.

## Where errors are reported

A mistake in an operation is reported in the operation's file, not at the line of the route table or the page that first used it: a `call` parameter the framework does not know is underlined in `call`; a Command with a `Grant` and no `@[Punch::Authorize]`, a missing `Grant`, a rate limit that does not fit, a bad `@[Punch::Route]`, and a policy whose `check` does not take the operation's path parameters (`ByRole.check takes id, but Billing::Invoices::Send has the path parameter invoice_id`) are reported on `call`, on the annotation, or on the policy's `check`. Publishing an event or enqueuing a job the handle's type does not list is reported at the `publish` or `enqueue` call, as a mismatch with the handle's type.

## From request to response

1. Path parameters come from the matched route.
2. A Query parses its input from the query string. A Command reads the body, at most `max_body_size` (1 MiB) unless `@[Punch::BodyLimit(bytes)]` sets another limit, and parses it as JSON. A non-empty body needs a JSON content type (`application/json` or `application/*+json`), otherwise 415.
3. A rejection answers 422 with every error, up to the first 100, as Problem Details. A path parameter that does not parse names no resource, so the answer is 404 `not_found` instead, as for pages: a garbled ID and the ID of no record look the same.
4. `call` runs with a `Reader` or a `Writer`.
5. The result is rendered with the status from `@[Punch::Status(code)]` on its type, 200 by default (a result of several types of the app's states every status, and a failure type includes `Punch::Problem`, which requires one from 400 on): as JSON below 400, as Problem Details from 400 on; `nil` answers 204. A `Punch::Rejection` or a unique violation answers 422 like a rejected input. Details in `docs/openapi.md`.
6. A Command whose result is a failure (from 400 on, a rejection, a violation) has its transaction rolled back instead of committed.

## Idempotency keys

A client that loses the answer to a Command does not know whether it ran. With an idempotency key it names the attempt, and a retry under the same key gets the first answer back instead of running the Command again.

```http
POST /billing/invoices/inv_gLW26G63FZp/send
Idempotency-Key: 8e03978e-40d5-43e8-bc93-6894a57f9324
```

| Situation | Answer |
|---|---|
| First request with a key | The Command runs; its answer is stored with the key in the same transaction |
| Same key, same request | The stored answer, with `Idempotent-Replayed: true`; the Command does not run |
| Same key, other request | 422 `idempotency_key_reused`; nothing runs |
| No key where one is required | 400 `idempotency_key_required` |
| A key that does not parse (1 to 255 visible ASCII characters, bare or quoted) | 400 `invalid_idempotency_key` |
| A key where the Command takes none | 400 `idempotency_key_not_accepted` |

**Which Commands take keys.** Every Command that asks for the actor, required or optional, accepts the header; keys are scoped per signed-in user and operation, so one caller's key never returns another's answer. An anonymous caller of a Command with an optional actor has no scope and gets 400. Commands that sign in or out (`Punch::Auth::Authentication`, `Punch::Auth::PasswordCheck`) take none: their answer sets a cookie, which a replay cannot. Nor do Commands that show a secret once (`Punch::Auth::Reveal`, `docs/auth.md`): the stored answer would hold it. Annotate to change this:

```crystal
@[Punch::Idempotency(:required)]                  # 400 without a key: Commands that move money or send something
@[Punch::Idempotency(scope: :ip)]                 # anonymous callers, keys per client address: everyone behind one address shares them, so only unguessable keys
@[Punch::Idempotency(:required, scope: :anyone)]  # one scope for all anonymous callers: only unguessable keys
```

**"The same request"** is a SHA-256 over the operation, the method, the path with its query, and the body as received (`Punch::Crypto::Fingerprint`).

**What is stored** is the answer as sent: status, `Content-Type`, `Location`, and body, so a deploy that changes the result type in between does not change a replay. Answers from `call` are stored, failures such as `AlreadySent` included: their writes roll back, and the answer is stored right after the rollback, in the same turn of the writer. Answers before `call` are not: input that does not parse, a missing or refused caller, a rate limit. An exception rolls back and stores nothing, so the retry runs.

**No "in progress" state.** The key is looked up inside the Command's write transaction, after authentication and the policy. A second request under the key waits for the writer like any other and then finds the answer. Because the answer commits with the Command's writes and outbox entries, a crash leaves either all of them or none.

**Forms.** `v.form(Command.action, idempotent: true)` writes a generated key into a hidden field (`_idempotency_key`), which makes a double submit harmless: the second gets the first one's 303. A Command that requires a key always gets one in its form. A refused form is shown again with the same key and is not stored, since it changed nothing.

**Storage and retention.** The table `punch_idempotency_keys` lives in the app's migrations; `serve` refuses to start without it when some Command takes keys:

Write it with `punch db:migration --punch idempotency` (the SQL is `Punch::IdempotencyKeys.sql`); `punch check` compares the table in `db/schema.sql` with what this Punch expects (step `punchtables`).

Answers are replayed for `PUNCH_IDEMPOTENCY_RETENTION_HOURS` (24 by default, never less, which `openapi.json` promises); after that a key counts as new. `Punch::IdempotencyKeys::Purge` removes expired ones every hour. Stored answers can hold personal data.

**OpenAPI** documents the `Idempotency-Key` header on every Command that takes keys (required where annotated), and the 400 and 422 answers. **Telemetry:** the wide event has `punch.idempotency` (`stored` or `replayed`).

**Limits.** The guarantee covers what the Command does in its transaction and through the outbox. A Command that calls another system from `call` is outside it; such calls belong in jobs. Jobs and deferred subscribers are not covered: they run at least once.

**Specs:** `first, again = client.twice("POST", path, json: {...})`, then `again.should be_replay_of(first)`; `Punch::Spec.idempotency_key(key)` for the header; `response.replayed?`.

## The request as received

A Command that must check a signature over the exact bytes of its body asks for `request : Punch::RawRequest` in `call`: `request.body` is the body as it arrived, and `request.header(name)` reads a header. Only its path parameters are parsed; the body is the Command's to read, of any content type, once the signature holds (`Input.from_json(request.body)` returns an input or a `Punch::Rejection`). A Query or a page that asks for it does not compile.

Inbound webhooks are built on it: each provider's `Receive` Command takes it (`docs/webhooks.md`). Write a provider rather than a Command of your own for deliveries from another system. Never put a raw request on a trace.

## In an application

```crystal
router = Punch::Routing::Router.new(database)
server = Punch::HTTP::Server.new(config) { |context| router.call(context) }
```

An application binary runs its command line with the application commands, which include `routes`:

```crystal
exit Punch::CLI.run(ARGV, commands: Punch::CLI::APP_COMMANDS)
```
