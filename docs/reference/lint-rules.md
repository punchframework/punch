# Lint rules

<!-- Written by `punch docs:check --write` from src/punch/ameba/. Do not edit: change the source and run it again. -->

Punch's own Ameba rules, which `punch check` runs (its `lint` step). Each reports code that compiles but breaks a convention the docs explain. A rule is turned off for one line only with `# ameba:disable Punch/<Rule>` and a comment saying why.

## Punch/CipherUse

Keeps encryption in `Punch::Crypto`: `OpenSSL::Cipher` appears only under `src/punch/crypto/`, where the tag length is fixed (`gcm_tag=` accepts truncated tags) and every key is derived for one purpose. Everything else seals and opens through `Punch::Crypto` or the formats built on it.

- `` `OpenSSL::Cipher` is used only inside Punch::Crypto, which fixes the tag length and derives a key per purpose (lib/punch/docs/keys.md) ``

## Punch/ConstraintRescue

Keeps constraint violations values: hand-written code under `app/` does not rescue `Punch::Database::ConstraintError`. A unique violation is returned by the generated write that can cause it, as a type in its result; any other constraint failure (a foreign key, a `CHECK`) means a check the Command should have made, which is a bug. Generated files are skipped.

- `` Do not rescue ConstraintError: a generated write returns unique violations as values (`in EmailTaken`), and other constraints are checked in the Command first (lib/punch/docs/queries.md#violations) ``

## Punch/DriverTypes

Keeps SQLite behind Punch's driver interface: `DB::`, `SQLite3::`, and the C bindings appear only in `src/punch/database/driver.cr` and `src/punch/database/shell.cr`, and only those require the `db` and `sqlite3` shards. Application code and generated code use `Punch::Reader`, `Punch::Writer`, and generated query methods, so the implementation underneath can change without touching them.

- `` `%s` is a SQLite driver type. Use Punch::Reader, Punch::Writer, or generated queries (lib/punch/docs/persistence.md) ``
- `` Requiring `%s` reaches SQLite past Punch's driver interface (lib/punch/docs/persistence.md) ``

## Punch/EnvAccess

Keeps app settings and secrets in the declared credentials: hand-written code under `app/` does not read `ENV`, nor the process environment through `LibC.getenv`. A value read there would be unchecked at boot, invisible to `creds:check`, and a plain `String` instead of a `Punch::Secret`.

- `Declare this setting in the app's credentials type (Punch::Credentials) instead of reading ENV (lib/punch/docs/credentials.md)`

## Punch/EventsHandle

Keeps `punch events` true: a Command publishes through the `Punch::Events(...)` its `call` asks for, which the router makes and whose type is the declaration the event graph prints. A handle made by hand, with `Events(...).for_transaction`, publishes events nobody can see in the graph. Specs use `Punch::Spec.events(Command, writer)`. The same holds for the outbox handle `Punch::Jobs(...)`: its type is what tells which Commands enqueue which jobs (`Punch::Spec.jobs`).

- `` Ask for `events : Punch::Events(...)` in the Command's `call` instead of making a handle: the type in `call` is what `punch events` shows (lib/punch/docs/events.md) ``

## Punch/MailDelivery

Keeps mail behind `Punch::Mailer`: a mail is a component that includes `Punch::Mail`, delivered by a job. Outside `src/punch/mail/` this reports `Carbon::Email` (Carbon's own email class, whose ECR templates and `deliver` bypass Punch), Carbon's development and SMTP adapters (unsafe in parallel and silent on failure), and any `deliver_later`, which spawns a fiber instead of going through the outbox. Carbon's provider adapters stay allowed, wrapped in `Punch::Mailer::CarbonAdapter`.

- `Send mail through Punch::Mailer: a struct that includes Punch::Mail, delivered from a job with Punch::Mailer.deliver (lib/punch/docs/mail.md)`

## Punch/ModelDatabase

Keeps database handles out of models: a model decides, an operation orchestrates. In app code (files under `app/`), `Punch::Reader`, `Punch::Writer`, `Punch::Database`, and `Punch::Databases` appear only inside an operation (a subclass of `Command`, `Query`, or `Page`) and inside a store (a type named `Store` or ending in `Store`), which loads and saves models with the generated queries, inside the app's actor (a type that includes `Punch::Auth::Actor`), whose `load` runs in the operation's transaction (docs/auth.md), and inside a policy (a type that includes `Punch::Policy`), which decides in it (docs/authorization.md), and inside an inbound webhook provider (a subclass of `Inbound`), whose `process` writes like a Command (docs/webhooks.md), and inside a subscriber (a type that includes `Punch::Subscriber(Event)`), whose inline `call` writes in the Command's transaction (docs/events.md). Generated files are skipped.

- `` `%s` outside an operation or a store: models never take a database handle; load and save in the operation or a Store (lib/punch/docs/models.md) ``

## Punch/NamespaceFile

Keeps namespaces and directories one (docs/structure.md):

## Punch/NotNil

Keeps `nil` a value the compiler checks (docs/guides/crystal-for-punch-developers.md): hand-written code under `app/` does not call `not_nil!`, which turns a compile error into a crash at run time. Handle the `nil` first, with a result such as `NotFound` or `|| return`, and the compiler knows the value is there after that line.

- `` Handle the `nil` instead of `not_nil!`: return a result (`\|\| return NotFound.new`), and the compiler knows the value is there after that line (lib/punch/docs/guides/crystal-for-punch-developers.md) ``

## Punch/OperationFile

One file per type a tool shows by name, named after it: a Query or Command in its namespace's `operations/` directory (`Billing::Invoices::Send` in `…/billing/invoices/operations/send.cr`), a Page in `pages/` (`…/pages/show_page.cr`), a job (`include Punch::Job`) in `jobs/`, a mail (`include Punch::Mail`) in `mail/`, a subscriber (`include Punch::Subscriber(…)`) in `subscribers/`. A name in a trace, a route table, the ops console, or an error then says which file to open, and listing `operations/` lists the namespace's API. Types only that one uses go in its file too; shared ones in the namespace's `results.cr` and `components.cr` (docs/structure.md). Applies to app code (files under `app/`).

- `` `%s` belongs in `%s`: one file per operation, page, job, mail, and subscriber, named after it (lib/punch/docs/structure.md) ``

## Punch/OperationOutput

Names what an operation answers: a Query, Command, or Page declares `alias Output = …`, the union of everything its `call` can return, right above `call`, and `call` returns `: Output`. The operation's answers are then one line to read, the same in every operation, and the name pages and specs use (`Send::Output`). Applies to app code (files under `app/`); Punch derives the contract from whatever `call` declares, so this is a convention, not a compile error (docs/operations.md).

- `` `%s` declares what `call` returns as `alias Output = A \| B`, above `call` (lib/punch/docs/operations.md) ``
- `` `%s#call` returns `: Output`, the operation's declared alias (lib/punch/docs/operations.md) ``

## Punch/OutsideCalls

Keeps calls to other systems out of requests (docs/jobs.md): an operation (a `Command`, `Query`, or `Page` in app code) does not make HTTP requests, open sockets, start processes, or deliver mail. Inside `call` such a call holds the transaction, and the database's one writer, for as long as the other system takes, and happens even when the Command then rolls back. Enqueue a job through `jobs : Punch::Jobs(...)`, or publish an event with a `:deferred` subscriber: it runs after the commit and is retried.

- `` `%s` in an operation calls another system inside the request: enqueue a job (`jobs : Punch::Jobs(...)`) or publish an event to a `:deferred` subscriber, which run after the commit and are retried (lib/punch/docs/jobs.md) ``

## Punch/PasswordCheck

Keeps sign-ins on the checked path (docs/auth.md): a password is checked through a Command whose `call` takes `Punch::Auth::PasswordCheck` or `OwnPasswordCheck`. The compiler then requires the rate limit by address or by actor, and the router hashes on the hasher before the transaction, so one writer is never held for the hashing. Outside Punch's own code this reports the functions underneath, which skip both: `verify_now` and `hash_now` on any receiver, and `Passwords.hasher`, `Passwords.lookup`, and `Passwords.stored`. A new password is hashed by `Punch::Auth::NewPassword`.

- `` Check a password by taking `password : Punch::Auth::PasswordCheck` (or `OwnPasswordCheck`) in the Command's `call`: the compiler then requires the rate limit, and the hashing runs before the transaction (lib/punch/docs/auth.md) ``

## Punch/PayloadFields

Keeps stored payloads to IDs and small values (docs/jobs.md): a field of a job or an event (a `record` or type that includes `Punch::Job` or `Punch::Event`) is not a collection: `Array`, `Hash`, `Set`, `Deque`, `Tuple`, `NamedTuple`, `Bytes` or `Slice`, or `JSON::Any`. Every payload is a row in the outbox and the queue, read again on every attempt; a list in it grows with the data, and the job then runs on a copy as it was when enqueued. Store the IDs that find the rows, and read them when the job runs. (A whole record in a payload does not compile.) A job that really carries a short list says why, with `# ameba:disable Punch/PayloadFields`.

- `` `%s` holds a collection in a stored payload: store the IDs that find the rows and read them when the job runs, so the payload stays small (lib/punch/docs/jobs.md) ``

## Punch/RecordFile

Keeps a record's behaviour where the generated file says it is: a struct named `Record` is reopened only in the file named after it, as Crystal names any type's file. `Billing::Customers::Record` lives in `…/billing/customers/record.cr`, so `records.gen.cr` can point there and readers find every rule about customers in one place. Generated files are skipped.

- `` `%s` belongs in `%s`, the file named after it, where the generated record points (lib/punch/docs/models.md) ``

## Punch/SetupFile

Keeps app-wide declarations where people and agents look for them (docs/structure.md): `Punch.assets`, `Punch.translations`, `Punch.migrations`, `Punch.credentials`, a console's `mount`, and every `Punch::….config =` in `app/setup.cr`; `Punch.table` in a `columns.cr`, the only files `punch db:generate` reads. Checks statements at the top level and in module bodies of files under `app/`, not code in methods.

## Punch/SliceBoundary

Keeps slices apart (docs/structure.md): code in one slice (a directory under `app/`) does not reach into another's data access, its generated `Table` and `Queries` and its `Store` (or any type named `…Store`). How a slice keeps its rows is its own; another slice uses its operations, policies, IDs, records, events, and results, or a function it offers for the purpose (`Accounts::Mailing`). Files directly in `app/` (the actor, settings) belong to no slice and are not checked; nor are generated files and specs.

- `` `%s` reaches into the %s slice's data: use its operations or policies, or a function it offers for this, instead of its tables, queries, or store (lib/punch/docs/structure.md) ``

## Punch/SQLText

No SQL injection: the SQL argument of every database method is text written in the source, never a value. Accepted, as the first argument of `exec`, `query_all`, `query_one?`, and the other methods named in `Methods`:

- `SQL text from a value: pass a literal or a constant, or build the statement from constants only, and bind every value as a parameter (lib/punch/docs/queries.md#sql-text-is-never-built-from-values)`
- `` `%s` passes SQL from its caller to `%s`: name it in Punch/SQLText's methods so its callers are checked, or take a constant (lib/punch/docs/queries.md#sql-text-is-never-built-from-values) ``
- `A database call in macro code this rule cannot read: write it outside the macro, with SQL text from the source (lib/punch/docs/queries.md#sql-text-is-never-built-from-values)`

## Punch/StatusComparison

Keeps status checks out of operations. An entity whose state decides what may happen to it has a type per state, and an operation branches on those types (`case invoice in Invoice::Sent`), so adding a state breaks every place that must handle it. Comparing a status (`invoice.status == …`, `row.status.sent?`, `case row.status`) inside a `Command`, `Query`, or `Page` subclass in app code (under `app/`) is reported. For an entity without state types, a status check showing up in an operation is the sign to give it some (docs/models.md); until then, disable the rule on that line.

- `` Compares `%s` in an operation: branch on the state types instead (`case invoice in Invoice::Sent`) (lib/punch/docs/models.md) ``

## Punch/TrustedHTML

Keeps unescaped markup visible in review: the argument of `SafeHTML.trusted` is a string literal, written by the programmer, so nothing from a request, the database, or a file can reach a page unescaped. Markup built at run time is built with the view's elements, which escape. A real exception says why, with `# ameba:disable Punch/TrustedHTML` on the line before.

- `` `SafeHTML.trusted` takes a string literal; build markup from data with the view's elements, which escape (lib/punch/docs/views.md) ``
- `` Reopening `SafeHTML` can make markup from any string: build markup with the view's elements, which escape (lib/punch/docs/views.md) ``
- `` A `text/html` response built by hand sends the string unescaped: answer with a page, or `Response.html`, which takes a `SafeHTML` (lib/punch/docs/views.md) ``
