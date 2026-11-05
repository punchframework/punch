# Tooling: `punch new`, `punch generate`, `punch upgrade:diff`, `punch check`, `punch dev`, settings

Learn it in: [`punch check` and the Command Line](guides/punch-check-and-the-command-line.md), [Installing Punch](guides/installing.md).

The standalone `punch` binary builds and checks the app in the current directory, the directory with its `shard.yml`. The app's first target is the app; its binary answers the same commands an application binary has (`routes`, `serve`, `db:*`, `config`).

## One entry point

`punch` has the commands that build or write (`check`, `dev`, `db:generate`, `openapi`, `jobs:lock`, ...), and the app's binary has the ones that need the app's operations and settings (`serve`, `db:audit`, `jobs:types`, `jobs:versions`, `tokens:create`, `limits:*`, ...). Run any of them as `punch <command>` from the app's root: a command `punch` does not have but an application binary does is forwarded. `punch` builds the app as `punch routes` does (`tmp/punch-routes/app`), runs the binary with the same arguments (`--json` included), and its stdout, stderr and exit code are the command's. Outside an app, such a command fails with `no_app`. A name neither binary has is a usage error (exit 2, JSON `unknown_command`) that names the closest commands (`Did you mean 'routes'?`, also as `details.did_you_mean`). The application binary names itself by its file name in `help`.

## Getting the tool

An app developer needs the `punch` binary that matches the app's `lib/punch`: it holds the generators (queries, i18n, the payload lock), so one from another Punch would write files the app does not expect. There are two ways to get it.

**From a release.** Each GitHub release of Punch carries the tool for Linux (x86-64 and ARM64, static) and macOS (Apple silicon), with `SHA256SUMS` and a build provenance attestation. In an app that gets Punch from GitHub, `punch tool:install` installs the tool of the version in `shard.lock`; `punch tool:install VERSION` installs another, and `--repository OWNER/NAME` names a fork. It fetches the archive and the release's `SHA256SUMS` with `curl`, compares the archive's SHA-256, and keeps the binary only if it reports that version, under `~/.cache/punch/tools/OWNER/NAME/VERSION/` (`XDG_CACHE_HOME` moves it). `PUNCH_RELEASES_URL` replaces `https://github.com` with a mirror (`https://` or `file://`). The checksum shows the download is what the release lists, not who made the release; `gh attestation verify ARCHIVE --repo OWNER/NAME` checks that the archive was built by the release workflow. The macOS tool loads OpenSSL and LibYAML from Homebrew, which building an app needs anyway.

**From the app's source,** on any platform, after `shards install`:

```
crystal build lib/punch/src/cli/main.cr -o lib/punch/bin/punch --release
```

Put `lib/punch/bin` on the `PATH`, or call it by path. An app's `scripts/punch-tool.sh`, which `punch new` writes and the app's CI and devcontainer run, puts the tool at the same place without a global `punch`: the release's tool of the app's version, checked against the release's `SHA256SUMS` and the version it reports, or, where Punch is a path dependency, the release has no tool for the machine, or with `--build`, the build above. It does nothing when the tool there is already that version. Whichever `punch` runs, it compares its `Punch::VERSION` and generator format (`Punch::CLI::GENERATOR_FORMAT`, bumped when an output changes shape) with `lib/punch`'s. When they differ, it runs `lib/punch/bin/punch` if it exists, or else the installed release tool of `lib/punch`'s version (as a Bundler binstub does), once: the binary it starts does not check again (`PUNCH_TOOL_REEXEC`). When there is neither, it refuses with `tool_mismatch` and the commands that get one. `help`, `version`, and `tool:install` always run. In the Punch repository itself there is no `lib/punch`, and nothing is compared.

## `punch new`

`punch new NAME` writes a new app into `NAME/` (or the current directory, `punch new .`, when it is empty): the accounts slice with sign-up, sign-in and out, password reset, email verification, the session list, second factor, and API tokens; a home page where sign-ins land (`GET /`); the global role `Accounts::Roles::Operator`, which opens the ops console; the migrations for the users table and the Punch tables it uses (auth, roles, outbox, idempotency keys, from Punch's own SQL); `AGENTS.md` and `CLAUDE.md` for people and coding agents; a README; a seed (`db/seeds.cr`); a CI workflow; a devcontainer; `scripts/punch-tool.sh`; and the deploy recipes. No example entity: `punch generate` adds the first one.

| Option | Does |
|---|---|
| `--module NAME` | The app's top-level module; from the directory's name otherwise (`time-sheets` is `TimeSheets`) |
| `--magic-links`, `--organizations` | Add sign-in by mailed link; add organizations, members, the roles held on them, and the organization a session works in |
| `--no-second-factor`, `--no-tokens` | Leave out the authenticator app, or the page for API tokens |
| `--deploy kamal\|systemd\|none` | The recipe: Kamal (`Dockerfile`, `config/deploy.yml`, the default), systemd and Caddy (`Dockerfile`, `deploy/`), or none |
| `--ci github\|none` | `.github/workflows/check.yml`, running `punch check` (default `github`) |
| `--languages en,de` | Locale files for each language Punch has texts in; English always |
| `--environments development,test` | The credential environments to start (the default); `development` is required. Production's are started when deploying, `punch creds:init --env production`, since its values are the deployment's |
| `--path DIR` | Punch as a path dependency on DIR instead of its repository |
| `--skip-install`, `--skip-git` | Write the files and credentials only; no `git init` and first commit |
| `--json` | The files written, each step's result, and the commands left |

Then it makes the app ready and proves it: `crystal tool format`; `shards install`; per environment a credentials file, its key (`config/credentials/<env>.key`, ignored by Git), and the key ring, plus captured mail for development and test; `db:migrate`, `db:generate`, `i18n:generate`, `requires:generate`, `openapi`, `jobs:lock`; `db:seed`; `punch check`; `git init` and a first commit. A fresh app passes `punch check`, so the first failing check is always the developer's own change. When a step fails, the files stay, and the message lists the commands left to run. The target must not exist or be empty.

While Punch has no repository (`Punch::REPOSITORY` is `nil`), the new app depends on the Punch checkout the tool was built from, by path, and the `Dockerfile` takes it as a second build context (`docker build --build-context punch=PATH .`).

The files come from `template/` in Punch's root, compiled into the tool as ECR: every file sees the app's names and parts. The reference app's shared files are rendered from the same template (`scripts/sync-reference.sh`, checked in CI); change them in `template/`, never in `reference/` alone.

## `punch generate`

Adds to an app what follows from its structure (`docs/structure.md`), never its content: no operation, page, or SQL query, which are the developer's.

| Command | Writes |
|---|---|
| `punch generate entity billing/plans [--table plans]` | The outline `app/billing/plans.cr`; `types.cr` with `Billing::Plans::ID`; `columns.cr` mapping the table; `queries.sql` with a header. The table defaults to the last segment |
| `punch generate namespace accounts/invitations` | The outline `app/accounts/invitations.cr`, for a namespace without tables |
| `punch generate accounts PART` | An optional part of the accounts slice, as `punch new` would have written it: `magic_links`, `organizations`, `second_factor`, `tokens` |
| `--skip-steps` | Write the files only, and list the steps |
| `--json` | The files created and updated, the edited files and their patch, each step's result, and the commands left |

A path is directories (`billing/plans`) or a module (`Billing::Plans`); names of file kinds (`operations`, `types`, …) are refused. A parent without an outline gets one too. Each outline starts with a placeholder (`# punch generate: say here what …`) that `Punch/NamespaceFile` reports, so `punch check` fails until the meaning is written down in its place (`docs/models.md`). An existing namespace is refused.

**An entity's table.** When `db/schema.sql` has the table, `columns.cr` maps its rowid to the entity's `ID`, each column referencing a mapped table's rowid to that table's ID type (`owner_id: Accounts::Users::ID`), and each `TEXT` column ending in `_at` to `Time`; the other columns are listed in a comment with their stored types, to map to their domain types by hand. A table that is mapped already, not `STRICT`, or named `punch_*` is refused. Without the table, a migration `create_<table>` creates it with only its `id`, and nothing runs: add the columns to the migration first, then run the listed steps (`db:migrate`, `db:generate`, `requires:generate`).

**A part later.** The template is rendered for the app as it is (its parts read from its files: `app/accounts/<part>/`, the locale files, the deploy recipe, the workflow) and again with the part, both formatted as `punch new` leaves them. The part's new files are written; if any of them exists, nothing is. A file the part changes that the app has left as the template wrote it is replaced. One the app has edited is left alone, and the template's change to it goes to `tmp/generate/accounts-<part>.patch`, a unified diff to apply with `git apply` or by hand. A template migration (organizations) is written with the current time in its name, after the app's own. With nothing in a patch, the steps run (`db:migrate`, `db:generate`, `i18n:generate`, `requires:generate`, `openapi`, `jobs:lock`); otherwise they are listed for after the patch. `punch check` is next either way.

## `punch upgrade:diff`

An app owns the code `punch new` and `punch generate` wrote, so a new Punch never changes it. `punch upgrade:diff`, run after updating Punch, shows what the template now writes differently for this app: it renders the template as the previous Punch wrote it and as this one does, both for the app's parts, and compares the two renderings (not the template with the app's files).

```
punch upgrade:diff                 # from the Punch in shard.lock before the last change to it
punch upgrade:diff --from 0.4.0    # from that version
punch upgrade:diff --from a1b2c3d  # from a commit or tag of a path dependency's checkout
punch upgrade:diff --from ../punch # from another Punch checkout
```

**The previous Punch.** By default, the version `shard.lock` named before the last commit that changed it (or at `HEAD`, when the change is not committed yet). A git dependency's is tag `v<version>` of its repository, cloned once; a path dependency's is tag `v<version>` in its checkout, exported with `git archive`. A path dependency keeps its version while Punch changes, so there it usually takes `--from`. The previous Punch's own `punch` renders its template, since the templates are compiled into the tool: it is built once per version or commit and kept in `$XDG_CACHE_HOME/punch/upgrade/` (`~/.cache/punch/upgrade/`; a `--from` directory is built each time), which needs `crystal` and `shards`, and the network once per version. It runs `punch template:render DIR` in the app, which every Punch from this one on answers; an older one is refused by name.

**The result.** The difference goes to `tmp/upgrade/<from>-<to>.patch`, and each changed file is listed with what it means for the app:

| Status | Means | In the patch |
|---|---|---|
| untouched | the app has the previous rendering | yes, applies |
| applies | the app edited it, and the change still applies | yes |
| conflicts | the app edited it where the template changed | yes: `git apply --3way` leaves conflict markers |
| new, removed | a file the template adds (a migration with the current time in its name), or no longer writes | yes |
| missing, exists, removed_edited | the app removed the file, has another one where a new one goes, or edited one the template no longer writes | no: decide by hand |
| migration | an applied migration changed in the template | no: never edit an applied one; the `punchtables` step of `punch check` names the migration to write |

The patch names both sides' blobs, which it writes into the app's object store, so `git apply --3way` can merge edited files. Nothing in the app is changed: apply the patch (`git apply`, or `git apply --3way` when a file conflicts), look at the result, regenerate what it touches (`punch typecheck` does), and run `punch check`.

`punch template:render DIR` renders this app's template, as this Punch writes it for the app's parts, into an empty directory, and nothing else. It is what an older Punch answers for `upgrade:diff`; its arguments and output stay as they are.

## `punch check`

Every check CI runs, the same on a laptop. Each step runs when the project has what it checks, and every step runs even after one fails, so one run reports everything:

| Step | Does | When |
|---|---|---|
| `format` | `crystal tool format --check` | on `src`, `spec`, `app`, `db`, `tools` |
| `schema` | `punch db:schema --check`: `db/schema.sql` matches the migrations | `db/migrations/` exists |
| `migrations` | `punch db:cost --check`: no rebuild without `-- rebuild: <table>` in a migration that `--base` does not have, or in any migration without a base revision (`docs/migrations.md`) | `db/migrations/` exists |
| `punchtables` | Punch's own tables in `db/schema.sql` (outbox, idempotency keys, webhooks, uploads, auth, roles) have the columns this Punch expects; each difference names the migration to write. A set with no table in the schema is not checked (`serve` checks what the app uses at boot), except `steps`, which every app has | `db/schema.sql` exists |
| `queries` | `punch db:generate --check`: generated files are current | `db/schema.sql` exists |
| `explain` | `punch db:explain --check`: no full scan or sort that the query does not accept with `-- scan:` or `-- sort:` (`docs/queries.md`) | `queries` passed |
| `i18n` | `punch i18n:generate --check`: the generated translations are current, and every code a rejection or failure result carries has its message in the default locale (`docs/translations.md`) | `config/locales/` exists |
| `requires` | `punch requires:generate --check`: `app/requires.gen.cr` is current, and every file under `app/` is of a known kind (`docs/structure.md`) | `app/` exists |
| `unreached` | every `app/**/*.cr` and `db/*.cr` is in a target's require list, read from `crystal tool dependencies -f flat` (under a second): a file nothing requires compiles away and its routes do not exist. Names each file and says to require it | `app/` or `db/` has Crystal files |
| `lint` | Ameba with Punch's rules | always |
| `build` | every target into `bin/`, warnings as errors, compiler statistics in `tmp/build-stats/` | always |
| `creds` | no key file (`config/credentials/*.key`) is committed or left out of `.gitignore`, and every encrypted file opens with its key (`docs/credentials.md`) | `config/credentials/` exists |
| `limits` | every Command that runs without a signed-in user has `@[Punch::RateLimit]` or `@[Punch::RateLimitExempt("reason")]`, read from the binary's `routes --json` (`docs/rate-limits.md`) | `build` passed, in an app that depends on Punch |
| `policies` | every operation has `@[Punch::Authorize(Policy)]` or `@[Punch::Public]`, read from the binary's `routes --json`; the compiler refuses an operation without either, so this step reports what a stale binary or a framework change would let through (`docs/authorization.md`) | `build` passed, in an app that depends on Punch |
| `events` | every event is published by an operation, read from the binary's `events --json`; Punch's own events (`Punch::Auth::SignInSucceeded`) count only when the app subscribes to them (`docs/events.md`) | `build` passed, in an app that depends on Punch |
| `webhooks` | lists the providers that do not verify their deliveries (`verify: :none`), never failing, so that none is added unnoticed (`docs/webhooks.md`) | `build` passed, in an app with webhook providers |
| `jobs` | every recurring job's schedule parses, read from the binary's `jobs:types --json` (`docs/jobs.md`) | `build` passed, in an app that depends on Punch |
| `boot` | the binary carries its migrations (`Punch.migrations` in the main file), so `serve` migrates at boot (`docs/deployment.md`) | `build` passed, in an app with `db/migrations/` |
| `payloads` | `punch jobs:lock --check`: `payloads.lock.json` is current and no change breaks stored payloads; then the lock against `--base`'s with the same rules (`docs/jobs.md`) | `build` passed, in an app with `payloads.lock.json` or job types of its own |
| `openapi` | `punch openapi --check`, then `punch openapi:diff` against `--base` (default `origin/main`, else `main`) | `openapi.json` exists |
| `specs` | the specs built as one binary in `tmp/punch-check/specs/` (the files `crystal spec` takes), warnings as errors, then run on `CRYSTAL_WORKERS` threads (4 by default); `nocache` runs the same binary. Built first so the compiler's memory is freed before specs compile fixture apps | `spec/` exists |
| `nocache` | the specs again with `PUNCH_CACHE=off`, since an app must be correct with an empty cache (`docs/cache.md`) | `specs` passed, in an app (not Punch itself) |

`openapi` and `payloads` derive from one build of the app with `-Dpunch_openapi` (the derivation build, in `tmp/punch-openapi/`), made once per `punch check`.

```
$ punch check
passed  format        0.2 s  src, spec
skipped schema        0.0 s  nothing to check
...
passed  specs        38.6 s  345 examples, 0 failures, 0 errors, 0 pending (CRYSTAL_WORKERS=4)
All checks passed: 4 passed, 3 skipped, 43.8 s.
```

A line per step goes to stderr as it finishes; the result goes to stdout. On failure the exit code is 1 and the message carries each failed step's output. With `--json`, stdout carries one document: `{"steps": [...]}`, or `{"error": {"code": "check_failed", "message", "details": {"steps": [...]}}}`, each step with `name`, `status` (`passed`, `failed`, `skipped`), `seconds`, and `detail`.

Lint needs Ameba as a development dependency of the app:

```yaml
development_dependencies:
  ameba:
    github: crystal-ameba/ameba
    version: ~> 1.7.0
```

`punch check` builds it with Punch's rules into `tmp/punch-check/ameba` (release mode, about a minute, again only when Ameba or the rules change). Without a `.ameba.yml`, it inspects the format directories, `db/` (the seeds) among them. In the Punch repository it builds `bin/ameba` from `tools/ameba.cr`; `scripts/check.sh` builds the CLI and runs `punch check`.

Builds go through a temporary file and a rename, so a running binary is replaced, not overwritten.

## `punch db:migration --punch`

Punch's own tables live in the app's migrations, so they can reference its users table. `punch db:migration --punch outbox|steps|idempotency|webhooks|uploads|auth|roles` writes the migration with Punch's SQL (`db/migrations/<time>_add_punch_<set>.sql`); `auth` and `roles` take `--users TABLE` (default `users`). When a later Punch changes a table, `punch check`'s `punchtables` step names the column and the migration to write.

## `punch db:seed`

Development data lives in `db/seeds.cr`, plain Crystal that sends the app's own Commands through its router, in one process, as a browser would. Seeded users and records then pass the same rules as real ones. `punch db:seed` builds the file and runs it against `$PUNCH_STORAGE/primary.db`; it opens the files as `serve` does (pending migrations, credentials, Punch's tables) and refuses unless `PUNCH_ENV` is `development`. `punch new` runs it once.

```crystal
require "../src/tally"
require "punch/seeds"

Punch::Seeds.run do |seed|
  email = Punch::Email.parse("admin@example.test").as(Punch::Email)
  unless seed.read { |db| Punch::Auth::EmailIdentities.find(db, email) }
    seed.submit(Accounts::SignUp::Create.action, form: {"name" => "Admin", "email" => email.value, "password" => Random::Secure.urlsafe_base64(15)})
  end
end
```

- `seed.submit(Command.action, form: {...})` sends the form with text fields, as a person types them (`seed.submit(Command.action, {...})` takes values typed like the input); a refusal (400 and up) stops the seed with the error codes. Cookies the app sets are kept, so after a sign-in the seed acts as that user (a sign-up does not sign in: it mails a link first); `seed.sign_in(user_id)` acts as anyone. The template's seed keeps its random password in `storage/seed-password`.
- `seed.request(method, path, json)` for JSON endpoints, `seed.read` and `seed.write` for what no Command does, such as a global role (`Punch::Roles.assign`).
- Look before adding, so running it again is safe. Jobs the Commands enqueue wait in the outbox for the next `punch dev`.

The `unreached` step of `punch check` leaves `db/seeds.cr` out: it is a main file of its own.

## `punch dev`

The development loop. Each round, in order:

1. applies pending migrations to `$PUNCH_STORAGE/primary.db`, which rewrites `db/schema.sql` when it changes;
2. regenerates the query files when the app has a schema;
3. regenerates the translations (`punch i18n:generate`) when the app has `config/locales/`, so a new key in a locale file is in `v.t` before the build, and the require file (`punch requires:generate`) when it has `app/`, so a new file is part of the build;
4. builds the first target into `tmp/punch-dev/app`, retrying once when only linking failed (Crystal's object cache occasionally fails a warm rebuild); when only the contents of assets changed, it builds nothing (below);
5. restarts the app with `serve`: SIGTERM, which drains it, then the new binary.

Then it polls `src/`, `app/`, `db/`, `config/` (translations and credentials), `shard.yml`, `shard.lock`, and `openapi.json` every 300 ms and starts the next round when a file changes, is added, or is removed. Files a round writes itself do not start another; a file saved during a build starts another round. A failed step prints its error and leaves the running app as it is; fix and save.

Its builds differ from `punch check`'s in three ways, none of which reaches a release:

- **`-Dpunch_dev`.** Assets are read from disk while the app runs (`docs/assets.md`), and every page loads a small script that reloads it when an asset changed or the app was restarted (it listens on `/punch/dev/reload`, which only these builds answer).
- **The fastest linker found:** mold, then lld, then gold (`-fuse-ld`); on macOS the system's. Linking the reference app takes 0.8 s with gold instead of 2.5 s. A build that fails to link with it is built again with the default linker, for the rest of the session. Debug information stays, so backtraces keep their file and line.
- **Its own object cache,** beside Crystal's with `-punch-dev` appended (`~/.cache/crystal-punch-dev`). Crystal keeps one cache per main file and drops it when the link flags change, so sharing it would make `punch dev` and `punch check` start each other's builds cold.

Each round is logged to `tmp/punch-dev/rounds.jsonl`: the files that differ from the last build, with their kind and how far the change reaches (a method body, a signature, structure), the compiler's stage times, the modules it compiled again, and how long the app took to answer `/up`. `punch dev:rounds` (`--json`) summarizes the log, and `punch typecheck` logs beside it once `tmp/punch-dev/` exists.

### Bareknuckle: incremental builds

An experiment, off unless asked for. `punch bareknuckle:build` builds `bareknuckle`, an incremental compiler made from Crystal's compiler sources, into `bin/` beside Punch's sources (the app's `lib/punch/bin/bareknuckle`). It needs LLVM's development files (`llvm-config`), which a Crystal install does not include, takes about 2.5 minutes, and needs about 4 GB of memory.

Once it is built, `punch dev --bareknuckle` (or `PUNCH_BAREKNUCKLE=on`) builds with it instead of `crystal build`:

- **A full build** runs in a new `bareknuckle` process, which builds as `crystal build` does and then keeps the typed program in memory (about 2 GB for the reference app).
- **A round that only changed method bodies** takes the fast path: the process types the changed methods again, generates only the modules that hold them, and links them with the other modules' objects. A method body edit on the reference app is built in about 0.8 s instead of 9 s. A comment or a blank line counts: debug information records every line, so every method after it in the file is typed again.
- **Anything else** is a full build in a new process: code outside methods that changed or moved (constants, `getter`, macro calls), a changed signature, a method that yields, a return type or instance variable that changes, a new type, and anything the main module holds (top-level code, constants, class variables, procs). Each round's line says how it was built, and why the fast path did not apply.

When the files stay unchanged for 5 s after a fast round, `punch dev` builds them in full in the background, at the lowest priority and with its own object cache (`~/.cache/crystal-punch-dev-verify`), and compares that build's code with the fast path's, function by function. A difference is logged to `tmp/punch-dev/verify.jsonl` and turns the fast path off until `punch dev` restarts. `punch dev:rounds` reports how rounds were built and what verification found.

The process keeps its own object cache (`~/.cache/crystal-punch-dev-bareknuckle`): it links the LLVM of the machine (`llvm-config`), and bitcode from two LLVM releases never compares equal. Its first build is therefore cold.

`punch typecheck` asks the running process instead of type-checking again: once a round has built the files as they are on disk, that round's result is the answer.

It only starts when it was built from the current sources and for the Crystal release the app builds with (`crystal env CRYSTAL_VERSION`); otherwise `punch dev` says why and builds with `crystal build`, as it also does when the process stops.

The app runs with `PUNCH_TRACE=console` unless set, so each request prints its trace as a tree. Its output goes to the terminal; `punch dev`'s own lines start with `punch dev:`. Ctrl-C stops both. `openapi.json` is not regenerated on every change, because that needs a second build: run `punch openapi` when the API changed, and `punch check` reports a stale one.

## `punch typecheck`

`punch typecheck` (`--json`) type-checks the app's first target with `crystal build --no-codegen`: every error the compiler finds, macros included, with its location, and no binary. On the reference app a check takes about 3 s where a warm build takes about 10 s, so it is the inner loop for a person or a coding agent between edits; `punch check` and `punch dev` still build. It first makes the files it reads current, as `punch dev` does: `db:generate` when there is a schema, `i18n:generate` when there are locale files, `requires:generate` when there is `app/`.

While `punch dev` builds with the bareknuckle daemon, `punch typecheck` asks the daemon (above) and answers within a second of the save; it waits for `punch dev`'s round when one is running.

`punch dev` does not type-check before building: the compiler reports a type error at the same point in a full build as in `--no-codegen` (about 2 s on the reference app in both, measured), so a check first would only add its 3 s to every build that passes.

## `punch routes`

Builds the app (`tmp/punch-routes/app`) and lists its routes, as `routes` does in the application binary: method, path, the surfaces it answers (`json`, `html`, `markdown`), the operation, and marks for the page holding a Command's form, the policy, rate limits, `unlisted`, and entry points of `/llms.txt`. With `--json`, `{"routes": [{"method", "path", "operation", "operation_id", "kind", "surfaces", …, "unlisted", "entry"}]}`.

## Settings: `punch config`

An application process reads its settings from the environment at boot. Every value is checked before anything starts, and every problem is reported at once (`invalid_config`). `punch config` shows them, checked the same way.

| Variable | Default | |
|---|---|---|
| `PUNCH_STORAGE` | `storage` | Directory of the database files (`primary.db`, …). Local disk only: the filesystem check refuses network and virtual filesystems |
| `PUNCH_HOST` | `127.0.0.1` | Address the server binds; `0.0.0.0` in a container |
| `PUNCH_PORT` | `3000` | |
| `PUNCH_PUBLIC_URL` | `http://<host>:<port>` in development and test | Where people reach the app, such as `https://invoices.example.org`: the base of links in mail (`docs/mail.md`). Required in other environments |
| `PUNCH_TRUSTED_PROXIES` | none | Comma-separated addresses or CIDR ranges whose forwarded headers are believed (`docs/http.md`) |
| `PUNCH_THREADS` | `CRYSTAL_WORKERS`, else the CPU count | Threads of the default execution context, which serves requests; the reader pool has one connection per thread. The writer has its own thread |
| `PUNCH_TRACE` | `json` | `json`: wide events as JSON lines on stdout; `console`: each trace as a tree on stderr; `off` |
| `PUNCH_TRACE_SAMPLE_PERCENT` | `100` | Share of traces whose spans are recorded and exported (console tree, OTLP) |
| `OTEL_EXPORTER_OTLP_ENDPOINT` and the other `OTEL_*` | none | Export of traces and metrics over OTLP/HTTP (`docs/tracing.md`, "Exporting over OTLP") |
| `PUNCH_CACHE` | `on` | `off`: every cache fetch computes (`docs/cache.md`) |
| `PUNCH_CACHE_MB` | `256` | Size cap of `cache.db` in MiB |
| `PUNCH_JOBS` | `on` | `off` runs no job workers in `serve`, for a separate `jobs` process (docs/jobs.md) |
| `PUNCH_JOB_THREADS` | `2` | Threads of the job workers' execution context |
| `PUNCH_JOB_CONCURRENCY` | `10` | Jobs running at once in one process |
| `PUNCH_JOB_QUEUES` | all | Comma-separated queues this process claims from |
| `PUNCH_JOB_RETENTION_HOURS` | `72` | How long finished jobs are kept |
| `PUNCH_OPS` | `on` | `off` records nothing in `ops.db` (docs/ops.md) |
| `PUNCH_OPS_SAMPLE_PERCENT` | `100` | Share of traces whose successful job runs and committed events `ops.db` keeps; errors and failures are always kept |
| `PUNCH_OPS_SLOW_MS` | `500` | Successful requests taking at least this long keep their wide event in `ops.db`, for the console's slowest requests |
| `PUNCH_OPS_RETENTION_DAYS` | `14` | How long `ops.db` keeps job runs, occurrences, and events, and resolved errors after they were last seen |

`punch db:migrate` and `punch db:status` default to `$PUNCH_STORAGE/primary.db`. Secrets and per-deployment values that are not settings are the app's credentials: the environment first, then `config/credentials/<env>.yml.enc` (`docs/credentials.md`).

## `serve`

The application binary's `serve` opens `primary.db`, `cache.db`, `queue.db`, and `ops.db` in `PUNCH_STORAGE`, routes every operation, serves the embedded `openapi.json`, and runs until SIGINT or SIGTERM has drained it. Wide events go to stdout, so it has no JSON mode. An app's main file is:

```crystal
require "./invoicing"
require "punch/cli"

exit Punch::CLI.run(ARGV, commands: Punch::CLI::APP_COMMANDS)
```

App-wide declarations, such as `Punch.migrations "../db/migrations"`, which embeds the migrations so the binary applies them at boot (`docs/deployment.md`), go in `app/setup.cr`.

Keep the app in a library file the main file requires (`src/invoicing.cr`: `require "punch"` and `require "../app/requires.gen"`), so specs can require it without starting the command line.
