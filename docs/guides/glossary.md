# Glossary

The words Punch's guides and messages use, one definition each. Where a word has an everyday meaning too, the guides use it only in the sense given here. Each term links to the guide that teaches it; the guide links on to the reference.

## The app and its code

**App binary.** The program `crystal build` makes from an app: it serves requests and answers commands such as `bin/roster db:migrate` and `bin/roster routes`. Compare *tool*. ([`punch check` and the Command Line](punch-check-and-the-command-line.md#two-binaries-one-entry-point))

**Entity.** A namespace that owns tables: it maps them in its `columns.cr`, and everything about it lives in its directory, such as `app/billing/invoices/`. ([Application Structure](application-structure.md#slices-namespaces-and-entities))

**Generated file.** A file a `punch` command writes from a source, named `*.gen.cr` or `openapi.json`. It is committed and never edited by hand: change the source and run the command again. `punch check` fails when one is out of date. ([`punch check` and the Command Line](punch-check-and-the-command-line.md#generated-files-are-committed))

**Namespace.** A directory under `app/` and the Crystal module of the same name: `app/accounts/sign_up/` holds `Accounts::SignUp`. Directories of a kind, such as `operations/` and `pages/`, add no namespace. ([Application Structure](application-structure.md#slices-namespaces-and-entities))

**Outline.** The file beside a namespace directory, named like it (`app/billing/invoices.cr`): one documented module that says in plain words what the concept means and is for. ([Application Structure](application-structure.md#outlines-what-a-namespace-means))

**Reference app.** The invoicing app in Punch's repository (`reference/`). The guides quote it as the finished example of every feature it uses.

**Slice.** A directory directly under `app/`, a bounded part of the domain such as `billing` or `accounts`. Another slice uses its data only through its operations. ([Application Structure](application-structure.md#slices-namespaces-and-entities))

**Tool.** The standalone `punch` program. It creates, generates, checks, and builds apps (`punch new`, `punch db:generate`, `punch check`) and passes commands it lacks to the app binary. Compare *app binary*. ([`punch check` and the Command Line](punch-check-and-the-command-line.md#two-binaries-one-entry-point))

## Operations

**Command.** An operation that changes state: a subclass of `Punch::Command`, whose `call` receives a `Punch::Writer` and runs in one transaction. "Command" with a capital letter always means this; a program you type in a shell is a *CLI command*. ([Operations and Routing](operations-and-routing.md#queries-read-commands-write))

**Endpoint.** The HTTP side of an operation: its method and path. ([Operations and Routing](operations-and-routing.md#how-a-name-becomes-a-route))

**Input.** An operation's `Input` struct, which includes `Punch::Input`. Parsing a request into it yields every field typed, or a rejection. ([Input and Domain Types](input-and-domain-types.md#declaring-an-input))

**Operation.** A Query, a Command, or a Page: business logic with a typed input and a typed result, free of HTTP. Its name decides its route. Never shortened to "ops". ([Operations and Routing](operations-and-routing.md#queries-read-commands-write))

**Page.** An operation that answers people with HTML: a subclass of `Punch::Page` that reads, calls other operations, and returns a component. ([Pages and Components](pages-and-components.md#a-page-calls-operations-and-renders-components))

**Query.** An operation that only reads: a subclass of `Punch::Query`, whose `call` receives a `Punch::Reader`. Capitalised and in code when it means the type; SQL in a `.sql` file is a *named query*. ([Operations and Routing](operations-and-routing.md#queries-read-commands-write))

**Surface.** One of the three forms an app answers in: HTML for people, markdown for agents, JSON for programs. ([How a Punch App Works](how-a-punch-app-works.md#three-surfaces-from-one-set-of-operations))

## Results and failures

**Invalid.** One value that failed to parse, as a `Punch::Invalid`: a code and its parameters, never a sentence. ([Input and Domain Types](input-and-domain-types.md#what-a-refused-input-looks-like))

**Problem.** A failure result an endpoint answers with, rendered as Problem Details (RFC 9457) with a snake_case `code`. A problem type includes `Punch::Problem`. ([Results, Errors, and Status Codes](results-errors-and-status-codes.md#problem-details))

**Rejection.** A whole input that failed to parse, as a `Punch::Rejection`: every error, each at its path. It answers 422. ([Input and Domain Types](input-and-domain-types.md#what-a-refused-input-looks-like))

**Result.** What `call` returns: one type, or a union of the outcomes it can have (`Sent | AlreadySent | NoLines`), each with its status. Expected failures are results, never exceptions. "Error" in the guides means a bug or an exception. ([Results, Errors, and Status Codes](results-errors-and-status-codes.md#every-outcome-is-a-type))

**Violation.** A write the database refused because a unique index already holds the value, returned as a typed struct such as `EmailTaken` instead of raised. ([Results, Errors, and Status Codes](results-errors-and-status-codes.md#violations-what-only-the-database-can-decide))

## Types

**Domain primitive.** A type for one kind of value, such as `Punch::Email` or `Punch::Money`, that can only be made by parsing: once you hold one, it is valid. ([Input and Domain Types](input-and-domain-types.md#domain-primitives))

**Public ID.** The form a typed ID with `public_id` shows in paths, forms, and JSON, such as `inv_gLW26G63FZp`: the rowid through a keyed permutation, so it neither counts records nor tells the next one. Queries keep the rowid. ([Input and Domain Types](input-and-domain-types.md#typed-ids))

**Secret.** A value wrapped in `Punch::Secret(T)`, which prints as `[REDACTED]` and cannot be serialized or used as a hash key; `unwrap` it at the point of use. ([Input and Domain Types](input-and-domain-types.md#secrets))

**Typed ID.** A record's ID as its own type, a subclass of `Punch::TypedID`, so an invoice's ID cannot be passed where a customer's is expected. ([Input and Domain Types](input-and-domain-types.md#typed-ids))

## Data

**Composite.** A value type of named fields declared with `Punch.composite`, such as an address, and stored on a row as a group of prefixed columns or as one JSON document. Made only by `build`, so it is always valid. ([Composites](composites.md#a-composite-is-a-value-type-declared-once))

**Declared clause.** A line in a named query's header that adds an optional filter (`-- when status:`) or a sort order (`-- order issued:`), chosen at the call by a typed `Filter` and an order enum instead of SQL assembled in Crystal. ([Keeping SQL Safe and Fast](keeping-sql-safe-and-fast.md#choices-without-sql-text))

**Keyset page.** One page of a list, read after the last row of the previous page (its cursor) rather than at an offset. A `:page` query returns `Punch::Paged`. ([Queries](../queries.md#pages-keyset-pagination))

**Migration.** A plain SQL file in `db/migrations/` that changes the schema, applied once and never edited afterwards. ([Migrations](migrations.md#writing-a-migration))

**Named query.** SQL in a `.sql` file under a `-- name:` header, which `punch db:generate` turns into a typed method. Punch has no ORM and no query builder. ([Named Queries and Generated Code](named-queries.md#a-named-query))

**Record.** The struct `punch db:generate` writes for a row of a mapped table, reused by every query that selects the whole row. ([Named Queries and Generated Code](named-queries.md#records-and-table))

**Row.** The struct generated for one result row of a named query that selects something other than a whole record. ([Named Queries and Generated Code](named-queries.md#a-named-query))

**State type.** One hand-written type per state of an entity's lifecycle, such as `Invoice::Draft` and `Invoice::Sent`, so only a draft has the methods a draft allows. ([Domain Models](domain-models.md#tier-2-one-type-per-state))

**Store.** The module that loads an entity's rows into its state types and saves them back. ([Domain Models](domain-models.md#the-store))

**Storage.** The directory named by `PUNCH_STORAGE` that holds an app's four database files: `primary.db`, `queue.db`, `ops.db`, and `cache.db`. ([SQLite in Punch](sqlite-in-punch.md#the-storage-directory))

## Access

**Actor.** Whoever a request acts for, as the app's own type: a signed-in user, a token's owner, or nobody. ([Authentication](authentication.md#the-actor))

**Grant.** A `Punch::Grant(O)`: proof that operation *O*'s policy allowed the call. A Command with a policy cannot run without one. Compare *upload grant*. ([Authorization and Roles](authorization-and-roles.md#grants-commands-cannot-skip-their-policy))

**Policy.** The rule that decides who may run an operation. Every operation declares one, or says it is public. ([Authorization and Roles](authorization-and-roles.md#policies))

**Role.** A named set of permissions held by a user, in one organization or for the whole app. ([Authorization and Roles](authorization-and-roles.md#roles))

## Files

**Claim.** A Command taking a checked upload for the app with `Punch::Upload.claim`. It gets the kept file, and the ticket is spent. ([Uploading Files](uploading-files.md#claiming-the-file))

**Kept file.** What a record keeps of a claimed upload, as a group of columns: `Punch::Upload::File`, or `PrivateFile`, `ImageFile`, or `PrivateImageFile`, composites Punch ships. ([Uploading Files](uploading-files.md#claiming-the-file))

**Kind of upload.** A type that includes `Punch::Upload::Kind`, with its rules: the largest file and the content types it takes. ([Uploading Files](uploading-files.md#declaring-a-kind-of-upload))

**Ticket.** The secret that names one upload until the app claims it, sent in a form's hidden field as a `Punch::Upload::Ticket`. ([Uploading Files](uploading-files.md#a-file-field-in-a-form))

**Upload grant.** What a Command hands out for one upload, as a `Punch::Upload::Grant`: a ticket and a signed `PUT` URL. It proves nothing about a policy. Compare *grant*. ([Uploading Files](uploading-files.md#granting-an-upload))

**Upload key.** Where a checked file is in the storage, as a `Punch::Upload::Key`. It comes from a kept file, never from a request. ([Uploading Files](uploading-files.md#common-mistakes))

## Configuration

**Credentials.** What the app declares it needs from its deployment, API keys and its own settings alike, as a type that includes `Punch::Credentials`. Values come from the environment or an encrypted file. ([Credentials and Keys](credentials-and-keys.md#declaring-what-the-app-needs))

**Blind index.** A column holding a keyed hash of an encrypted value, which finds a row by that exact value and keeps values unique. ([Column Encryption and Blind Indexes](column-encryption.md#finding-an-encrypted-value-blind-indexes))

**Encrypted column.** A `BLOB` column mapped as `Punch::Encrypted(T)`: generated code encrypts on write and decrypts on read, and the record holds a `Punch::Secret(T)`. ([Column Encryption and Blind Indexes](column-encryption.md))

**Key ring.** The app's root secret and the keys derived from it, for values that must be signed or encrypted. ([Credentials and Keys](credentials-and-keys.md#the-key-ring))

**Settings.** The `PUNCH_*` environment variables that configure Punch itself, such as `PUNCH_STORAGE` and `PUNCH_ENV`. Compare *credentials*. ([Configuring Punch Applications](configuring-punch-applications.md#settings-and-credentials))

## Background work

**Event.** A typed fact a Command publishes in its transaction (`InvoiceSent`), named in the past tense. Subscribers react to it after the commit. ([Domain Events](domain-events.md#an-event-is-a-fact))

**Idempotency key.** A client's name for one attempt at a Command, sent as the `Idempotency-Key` header, so a retry gets the stored answer instead of running twice. ([Building a JSON API](building-a-json-api.md#safe-retries-with-idempotency-keys))

**Job.** A typed struct stored in `queue.db` and run by a worker outside the request, retried when it fails. ([Background Jobs](background-jobs.md#what-a-job-is))

**Outbox.** The table a Command writes its events and jobs to in its own transaction, so they are delivered only if it commits, and always then. ([Background Jobs](background-jobs.md#enqueuing-from-a-command-the-outbox))

**Payload lock.** The committed file `payloads.lock.json` with the shape of every job payload, checked so a deploy can still read the jobs already queued. ([Background Jobs](background-jobs.md#the-payload-lock))

**Subscriber.** Code that reacts to an event, run after the publishing Command has committed. ([Domain Events](domain-events.md#three-deliveries))

## Running

**Ops.** What operators need: the console at `/_punch`, the `punch ops` commands, and `ops.db`, where errors, job runs, and slow requests are recorded. ([The Ops Console and `punch ops`](the-ops-console.md))

**Wide event.** The one record per request (or job) that carries everything about it: route, outcome, status, database totals, and any field the code adds. It is also the root span of the request's trace. ([Tracing and Metrics](tracing-and-metrics.md#one-wide-event-per-request))
