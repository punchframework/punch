# Punch documentation

Punch is a SQLite-first, single-node web framework for Crystal. An app is typed operations, Queries and Commands, over named SQL. It serves HTML pages for people, markdown for agents, and JSON with an OpenAPI document for programs, all from one static binary.

Punch 0.x is not released: anything may change between minor versions. In an app, these pages are at `lib/punch/docs/` and match the Punch version the app uses.

## How the documentation is organised

| Layer | What it answers | Where |
|---|---|---|
| **Guides** | "How do I…" and "why does Punch…", in order, with working code from the reference app | [`guides/`](guides/README.md) |
| **Reference** | Every option and limit of one subsystem, on one page | the pages listed [below](#reference-pages) |
| **Generated tables** | Every compile error, lint rule, and `punch check` step | [`reference/`](#generated-tables) |
| **API** | Every type and method, from the doc comments | [`crystal docs`](#api-documentation) |

A guide teaches the common path and links to the reference section for the rest. Start with a guide; go to the reference page when you need an option the guide does not show.

## Where to start

**You know Rails, Phoenix, or Django, and not Crystal.**

1. [Introduction](guides/introduction.md): whether Punch fits your project.
2. [Installing Punch](guides/installing.md), then [Getting Started](guides/getting-started.md): a first app, from `punch new` to a passing `punch check`.
3. [Crystal for Punch Developers](guides/crystal-for-punch-developers.md): the Crystal you need to read every example.
4. [Coming from Rails](guides/coming-from-rails.md): where each part of a Rails app goes, and what Punch deliberately lacks.
5. [How a Punch App Works](guides/how-a-punch-app-works.md): one request from the socket into the background.

**You know Crystal, and not full-stack frameworks.**

1. [Introduction](guides/introduction.md), [Installing Punch](guides/installing.md), and [Getting Started](guides/getting-started.md).
2. [How a Punch App Works](guides/how-a-punch-app-works.md) and [Application Structure](guides/application-structure.md): the conventions, and why each one exists.
3. [Securing Punch Applications](guides/securing-punch-applications.md) and [Backup and Restore](guides/backup-and-restore.md): what Punch does for you in production, and what stays yours.

**You are a coding agent working in a Punch app.**

1. The app's own `AGENTS.md`, then [`llms.txt`](llms.txt): one line per page, for retrieval.
2. [When the Compiler Says No](guides/when-the-compiler-says-no.md) and [punch check and the Command Line](guides/punch-check-and-the-command-line.md): the messages you meet most, and their honest fixes. [Compile errors](reference/compile-errors.md) has every one.
3. The "Rules" section at the end of each guide: the invariants, one line each.

**You run a Punch app in production.**

1. [Configuring Punch Applications](guides/configuring-punch-applications.md) and [Deploying](guides/deploying.md).
2. [Backup and Restore](guides/backup-and-restore.md): turn backups on, and practise a restore before you need one.
3. [The Ops Console and punch ops](guides/the-ops-console.md) and [Tracing and Metrics](guides/tracing-and-metrics.md).
4. [Evolving a Live App](guides/evolving-a-live-app.md): changing the schema, payloads, and API while the app runs.

Every guide, by group: [the guides](guides/README.md). Every term the guides use: [the glossary](guides/glossary.md).

## Reference pages

**An app and its tools**

- [Application structure](structure.md): where code lives in an app, and why a type's name decides its file, route, and permission.
- [Tooling](tooling.md): `punch new`, `punch generate`, `punch upgrade:diff`, `punch check`, `punch dev`, and the `PUNCH_*` settings.
- [Testing](testing.md): `punch/spec`, the client, inputs, databases, mails, jobs, and the matchers.

**Operations and HTTP**

- [Operations and routing](operations.md): Queries and Commands, how their names become routes, and how to call one from another.
- [Input](input.md): an operation's input struct, its parsing from path, query string, form, or JSON, and cross-field checks.
- [Core types](core-types.md): domain primitives, `Punch::Invalid` and `Punch::Rejection`, typed IDs and public IDs, money, and secrets.
- [JSON endpoints and OpenAPI](openapi.md): results and their statuses, Problem Details, and the committed `openapi.json`.
- [JSON Schema](json-schema.md): schemas derived from Crystal types for OpenAPI, forms, and job payloads.
- [HTTP kernel](http.md): the server, request bodies and their limits, headers, draining on shutdown.

**Data**

- [Persistence](persistence.md): the vendored SQLite, connections, readers and writers, and the storage directory.
- [Migrations and schema.sql](migrations.md): plain SQL migrations, `db/schema.sql`, the cost of a change, and keeping the previous release working.
- [Queries](queries.md): named SQL turned into typed Crystal, records, declared filters and orders, keyset pages, and uniqueness violations.
- [Composites](composites.md): value types stored as groups of columns or JSON documents, bounded lists and maps, polymorphic ones, typed paths, and versions.
- [Domain models](models.md): a model decides, an operation orchestrates; records, state types, stores, and entity outlines.
- [Text](text.md): collations, case-insensitive matching, and text normalized at the boundary.

**Pages and the browser**

- [Views and pages](views.md): pages, components, forms, Turbo Frames and Streams, live pages, and the markdown surface for agents.
- [Assets](assets.md): stylesheets, images, fonts, and JavaScript modules embedded in the binary and served under fingerprinted URLs.
- [Translations and formats](translations.md): messages per language from codes, and dates, numbers, and money in each language's format.

**Background work and integration**

- [Domain events](events.md): typed events published in a Command's transaction, subscribers, and the outbox.
- [Background jobs](jobs.md): typed jobs in `queue.db`, retries, recurring schedules, concurrency limits, and the payload lock.
- [Mail](mail.md): mail as a component with HTML and text parts, delivered by a job, captured in development and specs.
- [Inbound webhooks](webhooks.md): deliveries stored at once and processed later through the outbox, verified, and never processed twice.
- [Uploads](uploads.md): files sent from the browser straight to S3-compatible storage, checked by their first bytes, claimed and kept by the app with their names, held back until a scan passes them, and served by the storage.
- [Cache](cache.md): typed stores for expensive values and conditional requests for Query results.

**Security**

- [Authentication](auth.md): sessions, API tokens, one-time tokens, password hashing, two-factor sign-in, and the actor of a request.
- [Authorization](authorization.md): the policy every operation declares, grants, roles, and links and forms that ask the same policy.
- [Credentials](credentials.md): what an app needs from its deployment, declared as a type, checked before it starts, kept in encrypted files.
- [Key ring](keys.md): the root secret, keys derived from it, signed values, rotation, and the public-ID key.
- [Rate limits](rate-limits.md): how often an operation may run for one key, counted by GCRA, answered with 429.

**Production**

- [Deployment](deployment.md): one static binary behind a reverse proxy, deploys without downtime, Docker and Kamal.
- [Backup](backup.md): Litestream replication to S3-compatible storage, restores, restore drills, and recovery.
- [Ops data](ops.md): errors, job runs, events, and performance in `ops.db`, the ops console, and `punch ops`.
- [Tracing and wide events](tracing.md): one trace per request, its wide event, child spans, and export to OpenTelemetry.
- [Metrics](metrics.md): the SQLite signals of each database's writer on the OpenTelemetry data model.

## Generated tables

These pages are generated from Punch's sources. Search them for the exact text of a message.

- [Compile errors](reference/compile-errors.md): every message of Punch's compile-time checks, by topic, with the smallest program that gives it.
- [Lint rules](reference/lint-rules.md): Punch's Ameba rules and what each reports.
- [punch check steps](reference/check-steps.md): every step of `punch check`, what it does, and when it runs.

## API documentation

The types and methods are documented in the source. Build the pages from an app's checkout of Punch:

```console
$ cd lib/punch
$ crystal docs src/punch.cr -o /tmp/punch-api
```

Then open `/tmp/punch-api/index.html`. Pass `-o`: without it, `crystal docs` writes into `docs/`, among these pages.
