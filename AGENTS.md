# AGENTS.md

Guide for anyone, person or coding agent, developing the Punch framework itself. For building an app with Punch, read the app's own `AGENTS.md` (rendered from `template/AGENTS.md.ecr`) instead.

## Start here

1. `docs/README.md`: what Punch is, and the guides and reference pages. The reference pages (`docs/*.md`) are the contract for each subsystem; the sections below point to them.
2. `reference/`: the reference app, Punch's first consumer and its end-to-end test.
3. The commands below: `scripts/check.sh` runs everything CI runs.

## Toolchain

The compiler is the Crystal 1.22.0 release, pinned in `toolchain.env`, with its own standard library. 1.22 is the first release with the AES-GCM tag accessors. `toolchain.env` also pins the SHA-256 of each release archive the script (and an app's devcontainer) installs: move them with the version, from the release's asset digests.

```sh
eval "$(scripts/setup-toolchain.sh)"   # installs the release, prints PATH
shards install
```

`scripts/build-sqlite.sh` builds the vendored SQLite (`vendor/sqlite/`) into `build/sqlite/`: the static library and the SQLite shell as a library for `punch db:shell`. Punch's `@[Link]` annotation runs it, so no link flags are needed.

**Databases on local disk only.** WAL snapshots break on shared or network filesystems. When the project folder is a shared mount (a Docker or VM folder shared with the host), databases for tests and benchmarks go under `$HOME` or `/tmp`, never inside the repository.

Leave `CRYSTAL_PATH` unset (or at the compiler's default, `crystal env CRYSTAL_PATH`), so Punch compiles against the pinned release's standard library.

The markdown escaping specs render through `cmark-gfm` (`apt install cmark-gfm`), a development dependency only: no Punch or app binary uses it. Without it those examples are pending, so install it wherever specs run, CI included.

## Commands

| Command | Does |
|---|---|
| `scripts/check.sh` | Builds the CLI and runs `punch check`: everything CI runs (format, Ameba, build with statistics in `tmp/build-stats/`, specs on 4 threads) |
| `punch typecheck` | The standalone tool's fast type check of an app (`--no-codegen`, about a third of a build); after regenerating queries and translations |
| `crystal spec` | Specs only. `CRYSTAL_WORKERS` sets the thread count |
| `crystal tool format src spec` | Format |
| `bin/ameba` | Lint with Punch's rules (built from `tools/ameba.cr` by `punch check`) |
| `punch docs:check` | The documentation's code blocks, quoted messages, links, and index (the `docs` step of `punch check`); `--write` refreshes quoted code |

The full check takes about 90 s; the specs build three fixture apps (`spec/cli/`).

## CLI conventions

Every `punch` command is a `Punch::CLI::Command` listed in `CLI::COMMANDS`. Its result is a `Report`, which must render both as text and as JSON, or an expected `Failure`. With `--json`, stdout carries exactly one JSON document, also on failure (`{"error": {"code", "message"}}`). Exit codes: 0 success, 1 failure, 2 usage error. A spec checks every registered command against this. `punch` forwards a command it lacks but an application binary has (`APP_COMMANDS`) to the app's binary, and names the closest commands for a typo; a new command goes in `COMMANDS`, `APP_COMMANDS` or `TOOL_COMMANDS`, and the docs name it as `punch <command>`.

## Type names

Apps write every Punch type in full (`Punch::X`), so a name directly under `Punch` is vocabulary every app sees. The rule:

- A type sits directly under `Punch` only if app code writes it often, it cannot be misread without context, and it is core vocabulary (operations, views, outcomes, authorization entry points, primitives). Anything else goes in its subsystem's module, named with the word the docs use: `Punch::Job::Retry`, `Punch::Auth::Session`, `Punch::Database::Driver`.
- An annotation on a subsystem's type lives in that subsystem (`@[Punch::Job::Options]`, `@[Punch::Subscriber::Delivery]`); only operation annotations stay at the top (`@[Punch::Authorize]`, `@[Punch::Status]`).
- A type nested in a mixin (`Job`, `Policy`, `Mail`, `Subscriber`) is visible bare in every type that includes it, and wins over the app's own name there. Nest only names about that mixin.
- A problem's wire code is its type's last segment (`Punch::Auth::InvalidCode` answers `invalid_code`): move a problem type freely, but renaming its last segment changes the API.
- Renaming a job type changes what `queue.db` stores: drop the old name from the lock with `punch jobs:lock --drop`.

## Names in macros

Code a macro writes is resolved where it expands, and that is often inside Punch: a method of a Punch module or class (also when an app type includes or inherits it), a generic method with `forall`, a `macro finished` in a Punch module, or a macro called as `Punch::X.mount(...)`. There, an app's `Mailer::Welcome` finds `Punch::Mailer` first. An app module named like one of Punch's (`Auth`, `Mailer`, `Events`, …) would then fail to compile, or silently reach Punch's type of the same name.

- Every type a macro writes goes through `Punch::NAME_STARTS`: `{{ type.stringify.gsub(::Punch::NAME_STARTS, "::").id }}` writes every name in it global, generic arguments and union members included (`::Punch::Paged(::Mailer::Row) | ::Nil`). A list of types: `{{ types.map(&.stringify.gsub(::Punch::NAME_STARTS, "::")).join(" | ").id }}`. A type the app passes to a macro by path (`Punch.credentials`, `Punch.translations`, `Ops::Console.mount`) is written the same way, so it names the app's type from the top level.
- To read a constant or an alias of an app type in macro code, write `parse_type("::#{O}::Input").resolve`, never without `::`. A type variable in a method body is used as itself (`O::Input`, `T.new`), not written out.
- An alias the app's own type declares (`PunchCallExtras`, `PunchPolicy`, `PunchForms`) keeps the paths the developer wrote; it is defined in the app type, so it resolves there.
- `spec/core/app_names_spec.cr` type-checks the reference app with its top-level modules renamed to `Auth`, `Mailer`, and `Events`, plus an operation under each other top-level name of Punch's. A new kind of generated code that the reference app does not use needs an example there too.

## Code layout

The formatter (`crystal tool format`) owns spacing inside a line. Blank lines it leaves alone follow these rules, in Punch, the template, and apps' hand-written code (the generators' output, `*.gen.cr`, does not follow them yet); no tool checks them:

- A blank line after a guard clause (`return … if …`, `return … unless …`, or an `if` whose body only returns), and after a run of them, before the code they guard.
- A blank line after the `include` and `extend` lines that open a type's body. A `record` whose fields span lines and whose block starts with a method gets a blank line before it.
- In an `Input`, path parameters come first, then a blank line, then the other fields.
- A blank line before and after a `case`, unless it opens or closes a method or block (or a branch of another `case`). Comments directly above a `case` stay with it.
- A long `raise` in a branch moves into a private method returning `NoReturn`, named for what is wrong (`invalid_status_choice(id)`).

## Core types

Details in `docs/core-types.md`.

- Expected failures are union members, handled with `case … in`; no `Result` type.
- One value fails as `Punch::Invalid` (code and params, never a sentence); a whole input fails as `Punch::Rejection` with every error and its path.
- A domain primitive includes `Punch::Primitive(T)`, defines `self.parse`, and keeps `initialize` private. The compiler checks both. A primitive that declares `json_schema` restates its `parse`: spec the two with `Punch::Spec.schema_agrees(Type, valid:, invalid:)`.
- A list's page size is a `Punch::PageSize` field of its input (`getter limit : Punch::PageSize = Punch::PageSize.of(50)`), not an `Int32` with a hand-written `check`: the bounds then reach OpenAPI and forms (`docs/queries.md`, "Pages").
- Record IDs subclass `Punch::TypedID`; `public_id "inv"` gives one a public form, `inv_…`, while queries and stored JSON keep the rowid (`docs/core-types.md`).
- Amounts are `Punch::Money`: integer minor units, a JSON integer on the wire, with the currency (`Punch::Currency`) once per document. Bound whatever feeds a sum; arithmetic beyond ±(2^53 − 1) raises.
- Anything that must not leak is a `Punch::Secret(T)`. Serializing one does not compile; `unwrap` at the point of use.
- An operation's input includes `Punch::Input` (`docs/input.md`). `@[Punch::PathParam]` marks path fields; nilable or defaulted fields are optional; `Bool` fields use `getter?`; cross-field rules go in `check`. Specs build inputs with `Punch::Spec.input`.
- Misuse that must not compile gets a file in `spec/fail/` and an entry in `spec/core/compile_errors_spec.cr`.
- A message for app developers (a compile error, a check, a lint, a boot refusal) cites the doc by its path from the app's root, `(lib/punch/docs/operations.md)`, never `docs/…`: that is where an app has it. Comments in Punch's sources keep `docs/…`.

## HTTP kernel

Details in `docs/http.md`.

- A handler takes a `Punch::HTTP::Context` and returns a `Punch::HTTP::Response` value; the kernel writes it in one piece. Never write to the socket from a handler.
- Read bodies only with `context.read_body`, which enforces the limit.
- Inside `module Punch`, refer to the standard library as `::HTTP`, because `HTTP` means `Punch::HTTP` there.
- Specs that need a server bind port 0 and call `shutdown`; see `spec/http/server_spec.cr`.
- Probes and banned addresses are answered by `Probes::Guard` before a request is traced or routed (`docs/http.md`, "Probes and bans"). Keep that path free of allocation beyond the path check, and keep `/up` ahead of it. Never put on the probe list anything a browser asks for on its own, or anything under `/.well-known/`.

## Operations and routing

Details in `docs/operations.md`.

- An operation subclasses `Punch::Query` (takes a `Punch::Reader`) or `Punch::Command` (takes a `Punch::Writer`) and declares `Input`, `alias Output = …` (the union of everything `call` returns, right above `call`), and `call`, which returns `: Output` (`Punch/OperationOutput`, app code only). Specs of Punch itself may return any type, since they check that the macros read whatever `call` declares.
- An app's structure is in `docs/structure.md`: a namespace is a directory, a file's outermost module is its directory's, a use case lives where it writes. One file per operation, page, job, mail, and subscriber: `Billing::Invoices::Send` in `app/billing/invoices/operations/send.cr`, with the result types only it returns, and `ShowPage` in `app/billing/invoices/pages/show_page.cr`, with the components only it renders; shared ones in the namespace's `results.cr` and `components.cr`, policies in `policies.cr` (`Punch/OperationFile`). App-wide declarations only in `app/setup.cr` (`Punch/SetupFile`). Apps require one generated file, `app/requires.gen.cr` (`punch requires:generate`), which loads every file under `app/` in the order of its kind; a file of no known kind is refused (`docs/structure.md`).
- Routes are derived from the name; check them with `punch routes`. Override only when the derived route is wrong for a reason, with `@[Punch::Route]`.
- Build paths with `Operation.path(...)`, never by string concatenation.
- Commands that know their caller accept `Idempotency-Key` (`docs/operations.md`): the answer is stored in the Command's transaction and replayed. Mark Commands that move money or send something `@[Punch::Idempotency(:required)]`; anonymous Commands take keys only with `scope:`. Never call another system from `call` and rely on the key; that belongs in a job. Forms that create things get `idempotent: true`. Specs: `client.twice`, `be_replay_of`.
- Every concrete operation in a binary is in its route table, specs included. Spec operations live in a module named after the spec (`RoutingSpec::...`); misuse that must not compile goes to `spec/fail/`.

## Persistence

Details in `docs/persistence.md`.

- Linking any Punch binary builds the vendored SQLite once (`scripts/build-sqlite.sh --ldflags`, about 20 s). `punch db` shows what is linked; a spec checks it is the vendored version and not the system's.
- Operations get a `Reader` or `Writer`; framework code opens `Punch::Database` or `Punch::Databases`. Specs use `Punch::Spec.database` (memory) or `Punch::Spec.database(file: true)` (WAL, temp directory).
- SQL arguments and `row.read` types are `Nil`, `Bool`, `Int32`, `Int64`, `Float64`, `String`, `Bytes`; convert domain types at the call.
- Only `src/punch/database/driver.cr` (and `shell.cr`) may use `DB::`, `SQLite3::`, or the C bindings; `Punch/DriverTypes` reports any other use. Mark every workaround for an upstream defect `UPSTREAM`, with a link to the issue or fix filed with that project.
- A Punch Ameba rule lives in `src/punch/ameba/`, gets a fixture in `spec/lint/fixtures/` with `# expect` on each line it must report, and is built into `bin/ameba` by `scripts/check.sh`.
- Never create a database inside the repository; the filesystem check refuses a shared folder anyway.

## Migrations

Details in `docs/migrations.md`.

- Change the schema only with a new file from `punch db:migration NAME`, plain SQL, no transaction statements. Never edit an applied migration or `db/schema.sql`; `punch db:migrate PATH` rewrites the schema file, and `punch db:schema --check` must pass.
- Punch's own tables (outbox, idempotency keys, webhooks, auth, roles) come from `punch db:migration --punch outbox|idempotency|webhooks|auth|roles`, never pasted by hand; `punch check`'s `punchtables` step names the migration when a Punch upgrade changes one.
- Keep the previous release working against the new schema: add in one migration, remove in a later release.
- Before writing a migration, know its cost (`punch db:cost`): a rebuild (create, copy, drop, rename; `DROP COLUMN`) holds the write lock while it copies the table. Prefer a change that keeps the table (a unique index, a trigger, `SET NOT NULL`, `ADD CHECK`); when a rebuild is the only way, add `-- rebuild: <table>` to the file, which `punch check` requires. `ADD COLUMN` on a `STRICT` table is a scan, not instant.
- Migration specs build directories of files in a temp folder; fixtures that must stay are in `spec/database/fixtures/migrations/`.

## Queries

Details in `docs/queries.md`.

- Database access is named SQL in `.sql` files under `app/` or `src/` (`-- name: Name :one|:many|:exec|:execrows`, named parameters), turned into typed methods by `punch db:generate`. No query builder, no SQL strings assembled in Crystal.
- Before tightening a domain type (stricter parse rules), run the app's `db:audit` against a copy of the data; fix the rows it names first, then ship the type. Never loosen the audit or coerce values on read to make it pass. Its reports hold row IDs and reasons, never values; keep it so.
- Every named query is explained (`punch db:explain`, step `explain` of `punch check`): a full scan of a table or a sort of what was read fails, for each order with no filter and with each `when`. Fix it with an index, or a better query (no aggregate over a whole table to join a few rows); accept it only with a real reason in the header, `-- scan: <reason>` or `-- sort: <reason>`. Never add one to make the check pass.
- No SQL injection: never put a runtime value into SQL text (no interpolation, `+`, `String.build`, or format strings around SQL), in apps and in Punch. Every value is a bound parameter, also IDs, numbers, and limits. A choice of column or sort is a declared `-- order` (an enum), never a name from the request. Filter by user text with the pattern built in SQL around the parameter: `-- when q: AND c.name LIKE '%' || :q || '%' ESCAPE '\'`, the generator refuses a `LIKE` with a parameter and no `ESCAPE '\'`, and types that parameter (and the `Filter` field) as `Punch::LikeText`, which escapes when bound (`LikeText.new(text)`; `LikeText.pattern(text)` only for a screen that offers wildcards on purpose); an FTS5 `MATCH` parameter is a `Punch::FtsPhrase` the same way (`FtsPhrase.syntax` is the opt-out) (`docs/queries.md`, "No SQL injection"). `Punch::Database.escape_like`/`fts_phrase` are for hand-written SQL. `Punch/SQLText` reports SQL text that is not a literal, a constant, or built from constants only; a database method that passes its `sql` parameter on must be in the rule's `methods`. The only `# ameba:disable Punch/SQLText` lines are SQL from files (migrations, schema) and the checked `PRAGMA`; add none without a comment why (`docs/queries.md`).
- Map each column to its domain type once, in the owning entity's `columns.cr` (`Punch.table`, `app/billing/invoices/columns.cr`); only STRICT tables. The generated `Record` and `Table` (find, insert, update, delete) live in the module named there, written to `records.gen.cr` beside it.
- Personal data and stored secrets go in encrypted columns: `BLOB`, mapped as `Punch::Encrypted(T)` in `columns.cr`. Records hold `Punch::Secret(T)`; wrap on write (`Punch::Secret.new(value)`), `unwrap` only where the value leaves (a result struct, a view). Never compare, sort, `LIKE`, or index an encrypted column, and never put a `CHECK` on one: the ciphertext differs on every write; the generator refuses all of these (`Analyzer#check_secrets`, `Mapping.secret_problem`), but not comparisons of an expression over one. Lookups and uniqueness go through a blind index, `Punch::BlindIndex.of(:column)` on a second `BLOB` column: the generated `Table` writes it, records leave it out, and queries compare it only as `index = :param`, which the generator rewrites to `IN (SELECT unhex(value) FROM json_each(?))` over the hashes under every ring key (`Stored.blind_lookup`); keep that rewrite in `Analyzer.positional`, the one place both the statement and clause pieces go through. Purposes `column:<table>.<column>` and `blind_index:<table>.<column>` belong to the generated code; do not reuse them elsewhere. Do not rename an encrypted column, a blind index, or their table: the keys are derived from the names (`docs/queries.md`, "Encrypted columns", "Blind indexes"). A plaintext column becomes encrypted in three releases (`Punch::Encrypted(T).from(:column)`, then `clear: true`, then a migration drops it); in the second, generated code must not name the old column, and the generator refuses queries that do, `*` included. `Database::Encryption` (`punch db:encrypt`, the nightly job) converts, re-encrypts, rehashes, and clears through each table's generated `reencrypt`; Punch's own encrypted tables register a hand-written one (`Auth::SecondFactors.reencrypt`).
- A value type stored on a row is a composite (`Punch.composite` in `composites.cr` or the entity's `columns.cr`, `docs/composites.md`), mapped as a group of prefixed columns (`{type: T?, columns: "prefix_"}`) or a JSON document (a `TEXT` column with a `json_valid` CHECK, or `Punch::Encrypted(T)` in a `BLOB`). The generator writes its struct; `build` and `copy_with` return `| Punch::Invalid`, so never add a public constructor. Arrays and maps in documents are bounded (`max:`); documents keep keys they do not know; their shapes are in the payload lock's `documents` section, changed compatibly or by a new version with a frozen type, and `Database::Upgrade` rewrites old ones. Paths into documents are typed in `Paths` (`->>`, `json_extract`, generated columns); keep new path forms there. A polymorphic composite is a union alias, not a parent type: Crystal's `case … in` is not exhaustive over a struct hierarchy.
- Never edit `*.gen.cr`; change the source and regenerate. `punch db:generate --check` fails on stale files.
- A list with optional filters or a choice of sort is one query with declared clauses, not several queries or SQL assembled in Crystal: `-- when status: AND i.status = :status` (one parameter, named like the clause, or none for a `Bool` toggle) and `-- order issued: ORDER BY issued_on, id` on consecutive lines, each ascending in its first term. Pass `filter: Queries::Search::Filter.new(...)`, `order:`, and `direction:` (`Punch::Database::Direction`, `:desc` reads the order backwards); do not declare a separate descending order. A filter that is one of the app's enums gets one clause per member, `-- when status = paid: AND …`, with `-- param status: Billing::Invoices::Invoice::Status` in the header. The operation's input holds the `Filter` as one field (`getter filter : Queries::Page::Filter = Queries::Page::Filter.new`, read from `filter[status]`, one `deepObject` parameter in OpenAPI); never repeat its fields. Links pass it on (`IndexPage.href(filter: input.filter, after: …)`), the page narrows with `v.filter_form(IndexPage, input)`, and a spec runs the query with a `Filter` directly. A clause starts with `AND`, and keep any `OR` in parentheses, in the clause and in the condition it extends; the generator refuses anything that could widen the query (`docs/queries.md`).
- A list shown a page at a time is a `:page` query without `LIMIT` or `OFFSET`: the method takes `after:` (the previous page's `next_after`, a generated `Queries::X::Cursor` that an input takes as a field) and `limit:`, and returns `Punch::Paged` (`rows`, `next_after`). End every order with a key (`ORDER BY name, id`), sort only by selected `NOT NULL` columns, and never page with `OFFSET` (`docs/queries.md`, "Pages"). A next-page link repeats the filter's fields: the cursor holds only the position. A sort column that can be `NULL` needs a `NOT NULL` generated column as its key.
- Uniqueness is decided by the index, not by a lookup first: a generated write returns `Record | EmailTaken` (one `…Taken` struct per unique constraint of a mapped table, `docs/queries.md`). Handle it with `case … in` and return the violation from the Command (422, `taken` at its field); map it with `violation.rejection(path...)` when the input names the field differently. Use `Punch.cannot_violate(write)` only where the code makes a violation impossible. Never rescue `ConstraintError` in app code (`Punch/ConstraintRescue`).
- A Command whose result is a failure (status from 400 on, a `Punch::Rejection`, a violation) is rolled back: nothing it wrote stays.
- Generator code (`src/punch/query_gen/`) is only in the standalone `punch` binary (`CLI::TOOL_COMMANDS`), never in `require "punch"`, so applications do not compile Crystal's parser.
- The generator's broad fixture is `spec/query_gen/fixture/`, an app tree whose generated files are committed; `spec/query_gen/generator_spec.cr` checks they are current. After changing the generator, regenerate them (run `punch db:generate` inside that directory).

## JSON Schema

Details in `docs/json-schema.md`.

- Every schema comes from `Punch::JSONSchema`: OpenAPI, and later job payloads, forms, and action blocks. Never write a schema by hand for a type Punch can derive.
- A schema must say what the parser and `to_json` do. When `Punch::Input` or a serializer changes, the property specs in `spec/json_schema/` (required fields and `null` against the parser, keys against `to_json`) must still pass.
- A domain primitive with constraints declares them in `self.json_schema` (a NamedTuple of keywords).
- Derivation is compiled only where it is called; keep calls out of normal application builds (`punch openapi` uses its own build).

## JSON endpoints and OpenAPI

Details in `docs/openapi.md`.

- A result type's status is `@[Punch::Status(code)]`; from 400 on it renders as Problem Details with a snake_case `code` and its fields as extension members. Every error response, framework ones included, has that shape; never a sentence. A result of several types of the app's gives every member a `@[Punch::Status]` (`@[Punch::Status(200)]` on the success): the build refuses one that does not, because a failure without a status answers 200 and commits. A failure type includes `Punch::Problem` (JSON, the empty constructor, and a required status from 400 to 599).
- Declare the return type of `call`: the OpenAPI document shows the declared type, not what the body returns today.
- `openapi.json` is generated by `punch openapi` (a separate `-Dpunch_openapi` build) and never edited. `punch openapi --check` fails when stale; `punch openapi:diff` fails on breaking changes without a major version bump.
- The OpenAPI build compiles no endpoints (its routes use a stub handler), 1.18 GB at 400 operations; the normal build is the one near the 2.5 GB budget (2.30 GB with a server and the CLI). Measure before adding anything compiled per operation, and keep per-operation generic code to what depends on the types.

## Tracing

Details in `docs/tracing.md`.

- Every request is a trace; its root span is the wide event. Framework I/O gets a span: use `Punch::Trace.span` or `span.child`, with OpenTelemetry attribute names where one exists and `punch.` for Punch's own.
- Add business fields with `Punch::Trace.event["invoice.id"] = …`. Never record SQL arguments, bodies, or secrets; a `Punch::Secret` attribute does not compile.
- The current span is fiber-scoped. Code that spawns a fiber passes the span and uses `Punch::Trace.with`.
- Code inlined into every operation (yielding methods such as `Database#read`, the endpoint) keeps tracing in non-generic helpers: it counts against the compile-time budget per operation.
- Specs: `Punch::Spec.trace { … }` and `have_span(name, **attributes)`; servers in specs take `Tracer.off` or a tracer with `MemoryEvents`, so nothing is printed.
- An exception that is handled but must be seen goes on the trace with `record_exception` (or `span.error`); one raised outside any trace with `tracer.report(ex, name)`. Never only `Log.error` where a tracer or trace is at hand: the ops console reads traces, not logs.

## Metrics

Details in `docs/metrics.md`.

- Metrics are observed: a source registers a callback with `Punch::Metrics.registry.observe(name, kind, unit, description)`, and values are read when collected. Keep what the hot path updates to an atomic or a `Metrics::Histogram`.
- OpenTelemetry names where a convention exists (`db.client.connection.pending_requests`), `punch.` for Punch's own; durations in seconds.
- Each database's writer reports its queue, the WAL, and its checkpoints. The writer checkpoints itself (`checkpoint_pages`); do not set `wal_autocheckpoint`.
- Specs: `Punch::Spec.metrics(registry)` with `value`, `distribution`, `has?`; give the code under test its own `Metrics::Registry`.
- Export is OTLP/HTTP with JSON only (`Punch::OTLP`), configured by OpenTelemetry's `OTEL_*` variables in `AppConfig`; header values are secrets and are never printed. Specs post to a local `HTTP::Server` (`spec/otlp/otlp_spec.cr`), never a real collector.

## Backup

Details in `docs/backup.md`.

- `primary.db`, `queue.db`, and `ops.db` are replicated by Litestream, configured by `PUNCH_BACKUP_URL` (plus `PUNCH_BACKUP_EXEMPT`, `PUNCH_BACKUP_ENCRYPTION`, `PUNCH_LITESTREAM`; keys in `AWS_*`). Punch generates `litestream.yml` at every start; never commit or hand-edit one. `cache.db` is never replicated.
- Only the process holding `litestream.lock` runs Litestream; do not start a second Litestream on the same storage directory. The sidecar stops after the databases close, so the last writes are synced.
- Outside development and test, a file without a replica and a bucket not known to encrypt fail `/up`; lag never does (it is `punch.backup.lag` and a `Punch::Backup::Lagging` error).
- Litestream adds `_litestream_seq` and `_litestream_lock` to each file. Code that lists a database's tables must leave out `_litestream_%` as `Punch::Migrations::Schema.dump` does.
- Litestream uploads nothing for a file that does not change, so `Punch::Backup::Heartbeat` writes `_punch_heartbeat` into each quiet replicated file. A replica's last file time means "current up to here" only because of it: never treat a replica's end as its point without it, and leave `_punch_heartbeat` out wherever `_litestream_%` is.
- The nightly restore check (`Punch::Backup::Verify`, `punch backup:verify`) restores into `PUNCH_STORAGE/verify-*`, checks integrity, and runs `Punch::Backup::Reconciliation` as a dry run. `punch restore` (`Punch::Backup::Recovery`) restores the same way (`Restorer#restore_all`), so change restoring there, once, for both. The reconciliation only reads; `punch recovery:confirm` applies it (`Queue#reconcile`, `Job::Outbox.hand_over_again`).
- A restore moves replaced files aside, never deletes them, and refuses while `serve` or `jobs` hold `punch.lock` (shared, taken in `Serve.boot`). Anything new that opens the storage's files for the life of a process boots through `Serve.boot`. While `recovery.json` exists, background work is held (`Recovery::Hold`): a new kind of background work in `serve` or `jobs` starts inside `hold.start`, never before it.
- Specs never reach a real bucket: stand-in S3 endpoint and control socket, a shell script for the sidecar, real Litestream only with a `file://` replica (`spec/backup/backup_spec.cr`, `spec/backup/verification_spec.cr`).

## Deployment

Details in `docs/deployment.md`.

- An app ships as one static binary (Alpine, musl, `--release --static`) and runs behind a reverse proxy; the image is `FROM scratch` with Litestream, CA certificates, and time zones. The reference app's `Dockerfile`, `config/deploy.yml` (Kamal), and `deploy/` (Caddy, systemd, `deploy.sh`) are the recipes; keep them working when boot, shutdown, or settings change. Pin every download by checksum.
- The main file declares `Punch.migrations "../db/migrations"`: the binary embeds them, `serve` and `jobs` apply pending ones at boot (`PUNCH_MIGRATE=off` refuses instead), and its `db:migrate`/`db:status` use them. `punch check` (step `boot`) fails without it.
- A deploy runs two processes on the same files: the new one boots, the proxy switches on its `/up`, the old one drains on SIGTERM. Anything a process holds alone (a lock, a schedule, a sidecar) must hand over to the next process; anything per process (memory caches, live streams) must be fine to lose.
- Drain and shutdown come from `PUNCH_DRAIN_DELAY_SECONDS` (above the proxy's health interval when it polls; 0 behind kamal-proxy) and `PUNCH_SHUTDOWN_TIMEOUT_SECONDS` (below the supervisor's SIGKILL).
- Measure dropped requests with `reference/bench/handover.sh kamal|caddy|none` after changing the server's accept, drain, or shutdown, and the hasher's isolation with `reference/bench/signins.sh`.

## Testing and tooling

Details in `docs/testing.md` and `docs/tooling.md`.

- App specs use `Punch::Spec.db` (fresh in-memory database per example, `db/schema.sql` loaded) and `Punch::Spec.client` (in-process requests through `HTTP::Server#process`). Every response the client receives is checked against `openapi.json`; never turn that off to make a spec pass, regenerate the document or fix the code. An unhandled exception in an operation is raised by the client as `Punch::Spec::ServerError` (the original is its `cause`); a spec that tests the 500 page uses `Punch::Spec.client(raise_errors: false)`.
- `punch check` is the one entry point for CI. A new convention gets a step there or an Ameba rule.
- `punch dev`, `punch routes`, and `punch check` build the app's first target; the app's binary has `serve` and `config`. Settings come only from `PUNCH_*` variables, checked at boot (`Punch::AppConfig`). The default execution context starts with one thread; `serve` sizes it to `PUNCH_THREADS` before opening databases, so anything that sizes itself by threads (the reader pool) reads `Fiber::ExecutionContext.default.capacity`, never the environment.
- Development data is the app's `db/seeds.cr`, run by `punch db:seed` (`Punch::Seeds`, `docs/tooling.md`): it sends the app's own Commands through the router, so seeded data passes the same rules, and refuses outside development. A seed looks before it adds; never write rows a Command would have refused.
- Specs that run the tools on an app copy a fixture with `AppFixture.copy` (`spec/support/app_fixture.cr`); prefer the tiny stdlib-only fixture (`spec/cli/fixture/tiny`) when the test is about the loop, not about Punch.
- Measure the compile budget with an app that runs a server and the CLI: a class that is never instantiated compiles calls on it as unreachable, so a build without a server leaves out most of every endpoint.

## Translations

Details in `docs/translations.md`.

- Text for people comes from `config/locales/*.yml` through the generated accessors: `v.t.invoices.title` in a view, `locale.t…` elsewhere. Never write a sentence for people as a string literal in a page, a component, or a problem; never edit `*.gen.cr`, run `punch i18n:generate`.
- Rejections and failure results carry codes; their messages are `errors.<code>` and `problems.<code>` in the locale files, rendered at the edge. A new code needs a message in the default locale, or `punch check` fails.
- Show dates, numbers, and money with the locale's formats (`v.locale.date`, `.number`, `.money`), never with `to_s` or a hand-made pattern.
- Jobs and mail use the recipient's stored locale (`Punch::I18n.locale(tag)`), never the request's.
- Punch's own messages live in `src/punch/locales/en.yml` and `de.yml`; after changing them, run `punch i18n:generate` in Punch's root (writes `src/punch/i18n/own.gen.cr`) and in `spec/i18n/fixture/`. A new error code in Punch needs a message in both files (`spec/i18n/i18n_spec.cr` checks).

## Text

Details in `docs/text.md`.

- Text primitives normalize to NFC at the boundary; never compare or store unnormalized user text.
- Order text with a collation declared in the schema (`COLLATE de`), not in Crystal after fetching. Punch's collations, `lower`, `upper`, and `like` are on every connection, also in the generator, spec databases, and `punch db:shell`.
- A change to the Latin provider's order raises `Text::Collation::Latin::RULES`; databases then need a `REINDEX` migration, which the version check enforces.
- Collation and SQL function callbacks run inside SQLite: they must not raise (the driver catches and reports).

## Credentials

Details in `docs/credentials.md`.

- An app declares what it needs from its deployment as a type that includes `Punch::Credentials`, registered once with `Punch.credentials`. Never read `ENV` for an app setting or secret in app code.
- Lookup is the environment first (`stripe.secret_key` is `STRIPE__SECRET_KEY`), then `config/credentials/<env>.yml.enc`, compiled in. Secrets are `Punch::Secret(T)` fields.
- Key files (`config/credentials/*.key`) are never committed; `punch check` fails if one is. Change files with `punch creds:edit` or `creds:set` (value on stdin), never by hand.
- Specs load credentials with `Punch::Spec.credentials(Type, yaml)`; a spec binary must not call `Punch.credentials` itself, since every spec shares that one declaration.
- Crypto lives in `Punch::Crypto` (HKDF, AES-256-GCM with a fixed 16-byte tag). Never call `OpenSSL::Cipher` elsewhere; derive a key per purpose with an info naming algorithm, version, and purpose.

## Key ring

Details in `docs/keys.md`.

- Stateless signed or encrypted values use `Punch::KeyRing.current.signer(purpose)` or `.encryptor(purpose)`, one purpose per use. Sessions and tokens are random and stored hashed instead; never sign something that must be revocable one by one.
- The ring is the credential `secret_key_base : Punch::KeyRing`. Rotate in three deployed steps: `keys:rotate`, `keys:promote`, `keys:retire ID`. Before retiring a key, run `db:encrypt`, then check `db:audit`'s per-key counts of encrypted columns and blind indexes: values under a retired key no longer decrypt.
- Verification failures are `nil` without a reason; do not add one, and answer them as not found where a resource is concerned.

## Authentication

Details in `docs/auth.md`.

- Sessions, API tokens, and one-time tokens are random values stored as SHA-256 digests in the app's `punch_` tables (`Punch::Auth::Schema.sql`); never sign something that must be revocable, never store a raw token, never query those tables from app SQL.
- Passwords: input fields are `Punch::Auth::Password` (sign-in) or `Punch::Auth::NewPassword` (setting one); never `String`. Never hash or verify inside `call`: the router hashes `Auth::NewPassword` fields before the transaction (`input.password.hashed`), and a sign-in takes `password : Punch::Auth::PasswordCheck` and calls `password.confirm(db, Users::ID)`. Email identities and password hashes live in `punch_email_identities` and `punch_passwords`, through `Punch::Auth::EmailIdentities` and `Punch::Auth::Passwords`. Copy `reference/app/accounts/` for the slice.
- An operation gets the actor by asking for it: `actor : App::Actor` (401 without one) or `App::Actor?`, after the handle in `call`. The app's actor includes `Punch::Auth::Actor` and loads itself in the operation's transaction. Only Commands take `Punch::Auth::Authentication`, to sign in, out, or renew.
- Extra `call` parameters are read from `PunchCallExtras`, an alias each operation defines for itself, because a restriction such as `Actor` resolves lexically, and from `Punch::Routing` it would mean `Punch::Auth::Actor`.
- Raw tokens are `Punch::Secret(String)` until the one place they leave: the cookie, the link, or the response that shows a new API token once. A browser sees a new token on the page after the form through `Punch::Auth::Reveal` (`reveal.once` in the Command, `reveal.take` in the page; an encrypted cookie bound to the session); never store a raw token to show it later, and never give such a Command an idempotency key. Users manage agents' tokens on a page: copy `reference/app/accounts/tokens/` (creating one needs `Punch::RecentlyAuthenticated`, so a token cannot make another).
- A browser without a session that asks for a page or sends a form that needs one goes to the app's sign-in page (`Punch::Pages.sign_in = Accounts::Sessions::CreatePage.href`, set once in `app/setup.cr`); otherwise it gets the 401 page.
- A sign-in Command lists `Punch::Auth::SignInFailed` in its `Punch::Events(...)`; Punch publishes it after a refusal. Publish `SignedIn`, `PasswordChanged`, and `SessionRevoked` (`Punch::Auth::`) from the Commands that do those things. Checking the actor's own password is `password : Punch::Auth::OwnPasswordCheck` with `current_password` in the input and a limit `by: :actor`.
- Remove an email identity only with `Punch::Auth::EmailIdentities.remove`, which keeps the user's last way to sign in. One-time links carry the token in the query string, are made by the job that mails them, and are used only by the Command behind the page's button. Copy the flows from `reference/app/accounts/`.
- Commands from other sites' pages are refused by headers (`Sec-Fetch-Site`, `Origin`); no form tokens. Specs: `Punch::Spec.client.sign_in(id)`, `Punch::Spec.api_token(id)`.

## Authorization

Details in `docs/authorization.md`.

- Every operation has `@[Punch::Authorize(Policy)]` or `@[Punch::Public]`, and a Command without a signed-in user has `@[Punch::RateLimit]` or `@[Punch::RateLimitExempt("reason")]`; the build fails otherwise, at the operation (specs declare them too: `@[Punch::Public]` and an exempt for a fixture). `Punch::SignedIn` admits any signed-in user. A policy is one indexed lookup. Rules by role: copy `Billing::Invoices::ByRole` (the record's organization from its ID) and `Accounts::Organizations::Current` (lists and creates in the organization the actor works in) in the reference app; `not_found` to anyone without a role there. Code reads the time with `Time.utc`; specs stop and move it with `Punch::Spec.clock`.
- A policy includes `Punch::Policy` and decides in `self.check(actor, db, **path_params)` with `allow`, `forbid` (403), or `not_found` (404, where existence must not leak). It never sees the body: forms and links ask it before rendering. Rules about the body and state rules stay results of the operation; lists are scoped in SQL, never filtered after fetching.
- A Command with a policy takes `grant : Punch::Grant(Self)`; only `Punch::Grant(O).check` makes one. Call Commands directly only with a grant from there (`Punch::Spec.grant` in specs).
- Pages that take the actor render inside their read transaction and leave out forms and links their viewer may not use. Do not hide them by hand with role or ownership checks in components.

## Events

Details in `docs/events.md`.

- A Command announces its side effects as events: `record`s that include `Punch::Event`, named in the past tense, holding IDs and small values. It asks for `events : Punch::Events(A | B)` in `call` and calls `events.publish`; the type is the declaration `punch events` prints. Never make a handle by hand (`Punch/EventsHandle`); specs use `Punch::Spec.events(Command, writer)`.
- Subscribers include `Punch::Subscriber(T)` (an event, an abstract event, or a module events include). After commit is the default, `call(event)`, for reactions that must not fail the Command; `@[Punch::Subscriber::Delivery(:inline)]` with `call(event, db : Punch::Writer)` writes in the Command's transaction, and is rare. `@[Punch::Subscriber::Delivery(:deferred)]` with `call(event, job : Punch::Job::Context) : Punch::Job::Result` runs as a job through the outbox: for mail, webhooks, anything slow or retryable; keep such events to IDs and small values.
- Nothing is delivered after commit when the Command fails or raises. Do not use events for core flow the Command depends on; call that explicitly.
- `punch check` fails on an event no operation publishes. Specs: `->{ … }.should publish(T, field: value)`, or `Punch::Spec.published(T) { ... }` for the events themselves.

## Jobs

Details in `docs/jobs.md`.

- A job is a `record` (a struct) that includes `Punch::Job`; its fields are the payload (IDs and small values), and `perform(job : Punch::Job::Context) : Punch::Job::Result` returns `nil`, `Punch::Job::Retry`, or `Punch::Job::Discard`, made with `retry(reason, after:)` and `discard(reason)` (a deferred subscriber has both too). Options only by `@[Punch::Job::Options(queue:, attempts:, priority:)]`.
- Jobs run at least once: make every job safe to repeat, and pass `job.key` to providers that take an idempotency key.
- A job reads and writes through `job.read`/`job.write`, never holding a transaction while it calls out. `Punch::Job::Queue.enqueue` and `job.enqueue` are for code outside a transaction; inside one they raise.
- A Command enqueues through its outbox: `jobs : Punch::Jobs(A | B)` in `call`, then `jobs.enqueue(job, at:, in:)`. The app's migration creates `punch_outbox` from `Punch::Job::Outbox.sql`; never query it from app SQL. Never make a handle by hand (`Punch/EventsHandle`); specs use `Punch::Spec.jobs(Command, writer)`.
- Schedules only by `@[Punch::Job::Recurring(cron:)]` or `(every:)`, in UTC, on jobs whose fields have defaults; limits by `@[Punch::Job::Concurrency(n, by:, group:)]`. Jobs and events are written as `record`, which defines `initialize` also without fields (`record Purge do … end`); a hand-written struct defines it itself (JSON::Serializable removes the default one). Frozen payload types stay as written.
- Payloads outlive deploys. Their shapes are in `payloads.lock.json` (written by `punch jobs:lock`, checked by `punch check`); never edit it by hand. Change a payload compatibly (new fields nilable or defaulted, keep required ones and every type), or raise its version: `@[Punch::Payloads::Version(N, from: {N - 1 => V1})]` with the old fields copied unchanged into a frozen type (`include Punch::Payloads::Frozen`, `def upgrade : Job`). Never change a frozen type; delete it only when `punch jobs:versions` shows none of its version left. Remove a job type or deferred subscriber with `punch jobs:lock --drop 'Type'` only after the same check. Never put a record (a whole row) in a payload. Spec a conversion with `Punch::Spec.read_payload`.
- A payload that does not parse is parked as `incompatible`, not failed; never rescue parse errors inside `perform` to avoid that.
- A long job runs in steps (`include Punch::Job::Stepped`): methods marked `@[Punch::Job::Step]`, in definition order, each taking the context and optionally a `Punch::Job::Cursor(T)`, returning `Punch::Job::StepResult` (`nil`, `cursor.continue(value, in:)`, `again(in:)`, `retry`, `discard`). Punch defines `perform`. Return the cursor from inside the `job.write` that does the batch's work, so both commit together. Progress is in `primary.db` (`punch_job_progress`, `Punch::Job::Steps::Progress.sql`), a table every app has (`PunchTables::REQUIRED`), since `Punch::Database::Encryption::Run` runs in steps; step names and cursor schemas are in `payloads.lock.json`. Runner internals live in `Punch::Job::Steps`, not in the mixin, so their names stay out of the jobs. Specs: `perform_jobs(interrupt_every: 1)`, `Punch::Spec.job_progress(id)`.
- `queue.db` is Punch's own file. Changing its tables means a new `Job::Queue::LAYOUT` and a way to carry the jobs over; never drop it.
- Specs: `->{ … }.should enqueue(T, field: value)`, `Punch::Spec.perform_jobs` (hands over the outbox first), `Punch::Spec.enqueued(T)`, `Punch::Spec.clock`. Worker specs share one execution context (`spec/jobs/queue_spec.cr`) rather than making one per example.

## Ops data

Details in `docs/ops.md`.

- `ops.db` is Punch's own file, filled by `Punch::Ops::Sink` from wide events: error groups by fingerprint, failed requests, job runs, committed events. It is a view over the instrumentation; never write to it from anywhere but the sink and the console's actions.
- Changing its tables means a new `Ops::Store::LAYOUT` and a way to carry the history over; a file of another layout is refused.
- Keep the sink off the request path: it must drop rather than block, and nothing it does may start a trace (its writes run with no current span).
- Specs: `Punch::Spec.ops` opens this example's store; client requests and `perform_jobs` then record into it.
- The console (`src/punch/ops/console.cr` and `console/*.cr`: errors, jobs, performance, events, database and recovery, keys and credentials, webhooks, captured mail, cache) is Punch pages and Commands under `/_punch`, each with `@[Punch::Authorize(Access)]` and `@[Punch::Unlisted]`; keep both on anything added there. It reads `ops.db` and `queue.db` through `Ops.current?` and `Queue.current?`, the rest through what the process holds (`Metrics.registry`, `Backup.storage`, `KeyRing.current?`, `Credentials.loaded`), and must say so when something is not there, never fail. It never shows a secret's value.
- Performance is counted per request route, job type, and named query (`punch_ops_stats`, 10-minute buckets) from the wide event and the trace's query tally (`Span#tally_query`, fed by `Database::Probe` for statements with a `name:`). Give Punch's own SQL a `name:` too, so it shows there. Keep what the tally does per statement to a hash update under the trace's lock: it runs for every statement of every request.
- A console Command that changes the primary uses its own `db : Punch::Writer`; never open a second connection to `primary.db` from inside a Command (it waits for the write lock the Command holds: `Recovery.confirm(storage, queue, primary, now)`).
- Console pages are `@[Punch::AgentReadable]` (not `MailHTMLPage`, which writes raw HTML); a new page gets it too, and a line in the "renders every page as markdown" spec. What `punch ops` prints is a type in `Punch::Ops::Reports` (JSON with `emit_nulls`, plus `to_text`), built once from the store and queue, answered by a console Query on the page's path and printed by the command, locally or with `--url` (`OpsRemote`, token in `PUNCH_OPS_TOKEN`). Mirror a page in the CLI that way, never with a second way of reading the data; add its path to `OpsPaths`, which a spec checks against the routes.
- Notifications are the events `Punch::Ops::ErrorOccurred`, `JobsFailing`, `BackupStale`, published by `Punch::Ops::Notify` (every minute) once per episode (state in `ops.db`: `opened_at`/`notified_at`, `punch_ops_notices`). A new kind of trouble gets an event there, with IDs and small values only, never a message or a backtrace.

## Mail

Details in `docs/mail.md`.

- A mail is a struct that includes `Punch::Mail`: `to`, `subject(locale)`, and `view(v : Punch::View)`. One view yields the HTML and the plain-text part; text from the locale files, links as `Page.href` (absolute in mail). No `raw`, forms, or `v.document` in a mail.
- Send only from a job, normally a deferred subscriber: `Punch::Mailer.deliver(mail, locale: Punch::I18n.locale(recipient_tag), job: job)`, and return its result. Always the recipient's stored locale.
- Never use `Carbon::Email`, Carbon's dev or SMTP adapter, or `deliver_later` (`Punch/MailDelivery`). A provider goes in with `Punch::Mailer.adapter { ... }` and `delivery: adapter`.
- Settings are `getter mail : Punch::Mailer::Settings` in the app's credentials; links need `PUNCH_PUBLIC_URL` outside development and test.
- Specs: `->{ Punch::Spec.perform_jobs }.should deliver_mail(Mail, to: address)`, `Punch::Spec.mails(to:)` with `paths` to follow links, `Punch::Spec.render_mail`. In development, captured mail is at `/_punch/mail`.

## Webhooks

Details in `docs/webhooks.md`.

- Deliveries from other systems come through a provider: a struct that subclasses `Punch::Webhook::Inbound` with `@[Punch::Webhook::Provider("name")]`, a `verifier` (`Punch::Webhook::HMAC.new(secrets)` from the credentials), `parse` into typed events, and one `process(event, db, ...)` per event returning `Punch::Webhook::Outcome`. Punch adds the endpoint (`Provider::Receive`, `POST /webhooks/name`) and the processing job; never write a webhook Command of your own. Copy `Billing::Payments::Provider` in the reference app.
- Processing is a job: it runs at least once and later than the delivery. `process` writes like a Command (its writes commit with the invocation's move to `processed`, or roll back); return `retry(reason)` for a temporary failure, `discard(reason)` for nothing left to do, `Failed` or `Unprocessable` for a final one that someone should see, `Ignored` from `parse` for events the app does not handle. Never verify, call out, or sleep inside `process`.
- `punch_webhooks` (`Punch::Webhook::Invocations.sql`) is Punch's table in the app's migrations; never query it from app SQL. A provider with `verify: :none` needs a reason; `punch check` lists them.
- Signatures are `Punch::Webhook::Signature` (Standard Webhooks). Specs: `client.deliver_webhook(Provider::Receive.path, body, secret:)`, then `Punch::Spec.perform_jobs`; `Punch::Spec.webhooks` for the invocations.

## Uploads

Details in `docs/uploads.md`.

- No byte of an uploaded file passes through the app in production: the browser `PUT`s to a URL signed for one object, its `Content-Length` and `Content-Type` among the signed headers. Keep multipart refused, and never add a route that streams files from or to the storage; local storage (`storage: local`) is refused outside development and test.
- The client never chooses a key. Punch writes `pending/<id>`, and only its check copies to `files/<kind>/<id>`, from the ETag it read, after comparing size, type, and first bytes (`Punch::Upload::TYPES`). Only `files/` is ever signed for `GET`. A new type in `TYPES` needs a check of its first bytes; a type that runs script in a browser never goes in.
- The kept-file composites (`File`, `PrivateFile`, `ImageFile`, `PrivateImageFile`) are declared in `src/punch/upload/composites.cr`, embedded in the tool: after changing it, run `punch db:generate` in Punch's root (`composites.gen.cr`). A client's file name is only ever a `Filename`; names are parsed again on every read, so a tightened `clean` needs a migration of the stored names. A scan fails closed: keep `servable?` false for a file with no state in a scanned kind, and `url(key)` refusing such a key.
- A check takes its upload (`granted` to `checking`, compare-and-set) before it asks the storage, and copies at most once per upload; keep the storage's timeouts well inside `CHECK_LEASE`. A `Punch::Upload::Key` never comes from a request (an input field of that type does not compile); `discard` takes the owner.
- Storage calls (`Punch::S3::Client`) happen outside write transactions: in the check endpoint, which holds the writer only for the state change, and in the sweep. `grant`, `claim`, `discard`, and `url` sign or write locally and never call the storage.
- `punch_uploads` keeps the SHA-256 of a ticket, never the ticket. Tickets, signed URLs, and the secret key stay out of traces and logs (`Ticket#inspect` hides it; the check reads it from the body, not the path).
- Specs never reach a real bucket: `Punch::Spec.uploads` and `Punch::Spec.upload` for local storage, the stand-in S3 server in `spec/upload/upload_spec.cr` for signed requests.

## Cache

Details in `docs/cache.md`.

- Cache what is expensive to produce (outbound calls, heavy aggregates, rendered documents), never rows. One `Punch::Cache(K, V)` constant per kind of value, with a unique name; choose the tier (`:memory`, `:durable`, `:both`) and a `ttl`.
- Compute in a Query: a block inside a Command sees uncommitted data. Invalidate with an after-commit subscriber annotated `@[Punch::Subscriber::Forget(STORE, key: getter)]` (`Customers::ForgetStatement` in the reference app), so `punch events` shows it; otherwise entries live for their `ttl`. Forgetting does not reach another process's memory: use `:durable` where a job in a separate process commits the change.
- The app must be correct with an empty cache: `punch check` runs app specs again with `PUNCH_CACHE=off`. A spec that checks caching branches on `Punch::Caches.enabled?`; `Punch::Spec.clock` lets entries expire.
- A value type with a `Punch::Secret` inside does not compile; keep it that way when changing `Caches.check_value`.
- A Query result that includes `Punch::HTTP::Versioned` gets an `ETag` and 304s. Its `version` must change whenever the content does.

## Rate limits

Details in `docs/rate-limits.md`.

- Limit an operation with `@[Punch::RateLimit(n, per: span, by: :ip | :actor | :token | :field)]`; `store: :durable` for security limits (sign-in, sign-up, resets, token creation), memory otherwise. Every Command that runs without a signed-in user needs a limit or `@[Punch::RateLimitExempt("reason")]`; `punch check` fails otherwise.
- Never limit by hand-built keys from headers: `:ip` already uses the trusted-proxy rules and counts IPv6 by /64.
- Rate limits do not depend on the cache switch (`PUNCH_CACHE=off`); keep it that way. Specs: `Punch::Spec.clock`, `be_rate_limited`.

## Views and pages

Details in `docs/views.md`.

- A page subclasses `Punch::Page` (name ends in `Page`), takes a `Reader`, calls operations, and returns components or failures from 400 on. Keep rules in operations and models; a page that shares a path with a Query gets the browsers (`Accept`), the Query keeps the programs.
- Components include `Punch::Component` and write HTML through `v : Punch::View` with element names (`v.h1`, `v.table`, `v.a ... href:`). Layouts are components that take a block and call `v.document`; navigation goes in `v.chrome`.
- Never build markup from strings. Text is escaped; `SafeHTML.trusted` takes only a literal (`Punch/TrustedHTML`), and `HTTP::Response.html` only a `SafeHTML`.
- Links are `SomePage.href(...)` or `Punch::Href.external(...)`, never strings. No `on…` or `style` attributes: the CSP blocks them.
- Nesting mistakes raise `Punch::View::NestingError` when rendered, so render every component in a spec: `client.visit(href).should have_element(selector, text: ...)`, or `Punch::Spec.render(component)`.
- Forms are bound to Commands: `v.form(Command.action(...), values: {...}) { |form| form.field :name; form.submit "Save" }`. Never write a form, an input, or a field name by hand. Each Command with a form has one page that holds it (`CommandPage`, or `@[Punch::Forms(Command)]`), where a refusal is shown again; success is a 303 to the page's `redirect(result)`. Spec forms with `client.submit`, `redirect_to`, and `have_field_error`.
- Turbo Frames: `v.frame(typed_id, prefix)`, DOM IDs from `Punch.dom_id`, never built by hand.
- Turbo Streams: a `Punch::TurboStream` of actions on DOM IDs (typed IDs or `Punch.dom_id`), each holding a component; never a second template for a stream. A holding page answers its Command's form with one by overloading `self.stream(result)` next to `redirect`; build it from the result (`docs/views.md`, "Turbo Streams").
- A page agents may read as markdown says so with `@[Punch::AgentReadable]`; nothing else reaches the markdown surface. Its components render through a plain `View`: no `raw` outside `v.chrome`, no component that takes an `HTMLView` (both fail to compile). Spec it with `client.read(href)` (`Accept: text/markdown`) or `Punch::Spec.markdown(component)`. Markdown escaping is checked with hostile strings against cmark-gfm in `spec/view/markdown_spec.cr`: a change to `MarkdownBackend` must keep it passing. Forms on such pages become action blocks (`src/punch/view/action_block.cr`, `docs/views.md`), generated from the form's element tree plus a `FormTarget` the view hands to backends that describe forms; an agent's form body with `Accept: text/markdown` is answered like a browser's form, in markdown. Spec actions with `client.act(page, title, fields)` and `have_action`. Phrases live in `punch.actions.*` (run `punch i18n:generate` after changing them). A GET path ending in `.md` is that page's markdown, and only that: markdown links, action addresses, and an agent's redirects use `.md` URLs (`Href#markdown_url`), so never build them by hand. Pages an agent opens first get `@[Punch::AgentReadable(entry: true)]` (no path parameters or required fields), listed in `/llms.txt` with the app's `llms.*` texts.

## Assets

Details in `docs/assets.md`.

- An app's stylesheets, images, fonts, and ES modules live in one directory, declared once with `Punch.assets "assets"` and embedded at compile time. No build step, no Node.
- Refer to an asset only with `Punch.asset("path")` (checked at compile time): `.href` for `src:`/`href:`, `v.document(..., stylesheets: {...}, script: ...)` for the head. Never write `/assets/...` by hand; the fingerprint changes with the content.
- In stylesheets, refer to other assets by relative paths (Punch rewrites them); in modules, import by bare names from the import map, never by relative paths.
- Nothing inline: the CSP allows only the import map and Turbo's progress bar by hash. Keep `Assets.csp` in any replacement policy.
- Turbo is vendored in `vendor/turbo/`; update it only with `scripts/vendor-turbo.sh VERSION`.

## Domain models

Details in `docs/models.md`.

- A model decides, an operation orchestrates. Models never take a database handle.
- Every namespace directory under `app/` (slices, entities, namespaces without tables) has an outline beside it, named like it (`app/billing/customers.cr`): the module with a doc comment saying, in plain words, what it means, what it is for, and how it relates to other entities (not types, files, events, or policies, which the code and tools tell), plus at most documented constants the domain names with plain values (`PAYMENT_TERM = 14.days`); no other code, and no doc comment on that module anywhere else (`crystal docs` keeps the last; `Punch/NamespaceFile`). Read it first; update it in the same commit when its meaning changes.
- Start with the generated record (tier 1). Move an entity to state types (tier 2) when its state decides which operations are allowed, when it has rules spanning its child rows, or when the same status check turns up in a second operation; when unsure, stay with tier 1.
- A record's behaviour goes only in the file named after it (`Billing::Customers::Record` in `app/billing/customers/record.cr`); the generated comment points there and `Punch/RecordFile` reports any other place.
- A rule needed by a model and by list rows goes in a module with abstract getters, included by the model and by the query (`-- include Module` in the header). Require it before the generated query file.
- Tier 2: one immutable type per state, transitions as methods, and a `…Store` that maps rows to states and back. Only operations and stores take database handles (`Punch/ModelDatabase`); operations branch on state types with `case … in`, never on a status (`Punch/StatusComparison`). Every store spec uses `Punch::Spec.round_trip(..., covering: States)`.

## Reference app

Details in `reference/README.md`.

- `reference/` is an app like any other: its own `shard.yml` (Punch as a path dependency), `punch check`, and `openapi.json`. `scripts/check.sh` checks it after the framework; run `shards install` in it once.
- It holds one worked example of each model tier: customers (behaviour on the generated record) and invoices (state types and a store). When a framework change touches what it uses, update the app in the same series; it is the first consumer.
- The app template of `punch new` is `template/` (ECR, compiled into the tool; `docs/tooling.md`). The reference app's accounts slice, home page, `AGENTS.md`, systemd recipe, and seed are rendered from it: change them in `template/`, then run `scripts/sync-reference.sh`; `scripts/check.sh` fails when `reference/` differs (`--check`). The script lists the files the reference app owns (billing, its roles, layout, texts, stylesheet, migrations, Docker and Kamal files).
- `punch generate accounts PART` (`src/punch/cli/tool/generate.cr`) renders the same template for an app's parts, read back from its files (`CLI::New::Detect`), without and with the part: so a template file must render the same for the same parts, whatever else changed. `punch generate entity` and `namespace` write only what `docs/structure.md` asks of every entity, never operations or SQL.
- `punch template:render DIR` is a contract: `punch upgrade:diff` runs an older Punch's tool with it to render that Punch's template for an app (`src/punch/cli/tool/upgrade.cr`, `docs/tooling.md`). Keep its arguments, its output (the rendered files and nothing else), and its use of the part detection; a template change shows in every app's `upgrade:diff`, so name it in the changelog.
- `template/AGENTS.md.ecr` is the guide for app developers and their agents. When a change alters what an app writes, runs, or sees in an error, update it in the same series. `spec/cli/new_spec.cr` renders the template for several sets of parts; `scripts/check.sh` with `PUNCH_NEW_APPS=1` also generates three apps (the default parts, every optional part, none) with `scripts/new-apps.sh` and runs their `punch check`.
- `reference/bench/run.sh` measures latency under mixed load. Compare with the baseline in its README before and after changes to the kernel, the database, or tracing.
- Measure compile times of an app on local disk: a shared folder doubles a warm rebuild.

## Documentation

Checked by `punch docs:check` (`src/punch/docs_check.cr`).

- Three layers: the guides in `docs/guides/` (narrative, by task), the reference pages `docs/*.md` (one per subsystem, every option), and the API docs from doc comments. A guide links to its reference page for the full list instead of copying it. Paths of reference pages never change: Punch's messages cite them.
- Every page is in `docs/llms.txt`, one line each, for agents. `docs/README.md` is the front page for people: the layers, a reading path per reader, and a link to every page outside `docs/guides/`; `docs/guides/README.md` links every guide. Every `lib/punch/docs/…` path in `src/` and `template/` must name a page and heading that exist.
- Every code block in a guide says what keeps it true: `source=PATH select=NAMES elide=NAMES` copies a file or some of its definitions (Crystal by name, `A::B`, `A::B#m`, `A::B.m`; SQL by `-- name:`; YAML by key path `en.billing`; `bare` shows a Crystal definition's doc comment and annotations as `# ...` (`bare=A::B` only those of the definitions named), for a section they would only distract from), `fails=spec/fail/NAME.cr` shows misuse and is followed by a `text` block with the compiler's message, `illustrative="why"` is neither (the reason is required for Crystal and SQL), and `console` and `text` need nothing unless they quote a message. `text message=PATH` (or `console message=PATH`) quotes one of that file's messages: each line of the block is one of a Crystal file's string literals, to the line's end, with interpolations and `%s` as any text, or holds a YAML file's value (or the start of a compile error in `spec/core/compile_errors_spec.cr`) anywhere; `message=crystal`, `sqlite`, or `turbo` names another program's, which is not checked. Every message under "Common mistakes" says where it comes from, so each mistake that gives one quotes it exactly. Quote the reference app, or `docs/guides/examples/` for what it does not use; never add code to the reference app only for a guide.
- `docs/guides/examples/` is an app made by `punch new` (module `Examples`, the fewest parts) plus a `billing` slice with what the guides quote. Like the reference app, its template files are kept by `scripts/sync-reference.sh` (it owns `shard.yml`, `config/locales/en.yml`, `spec/spec_helper.cr`, and its migrations), and `scripts/check.sh` runs its `punch check`. Its databases go under `$HOME` here, like any app's (`PUNCH_STORAGE`).
- Never edit a quoted block by hand: change the source and run `punch docs:check --write`, then read the diff.
- Guides carry no build history (no internal IDs or dates), say "Applies to Punch 0.N." near the top, and end their topic with `## Rules`. English, Oxford spelling ("behaviour", "organization").

## Rules

- **Multi-thread safe from the first line.** No thread-locals, no assumption that a fiber stays on one thread. Specs run with parallelism above one.
- **Expected failures are values, exceptions are bugs**.
- **Stdlib first.** Every new shard needs a stated reason, in the commit that adds it.
- **Generated files are committed and never edited by hand.**
- **One change per commit series,** with its specs, docs, and the reference app updated in the same series.
- **Commit messages:** plain summary line plus a short body. No co-author or tool attribution lines.
