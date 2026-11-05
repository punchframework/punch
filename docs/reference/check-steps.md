# `punch check` steps

<!-- Written by `punch docs:check --write` from the step table in src/punch/cli/tool/check.cr. Do not edit: change the source and run it again. -->

`punch check` runs every step that applies to the project, in this order, and runs all of them even after one fails, so one run reports everything. `--json` gives each step's name, status (`passed`, `failed`, `skipped`), seconds, and detail.

| Step | Does | When |
|---|---|---|
| `format` | `crystal tool format --check` | always, on `src`, `spec`, `app`, `db`, `tools` |
| `schema` | `punch db:schema --check` | `db/migrations` exists |
| `migrations` | `punch db:cost --check`: no unacknowledged rebuild in a migration `--base` does not have (all without one) | `db/migrations` exists |
| `punchtables` | Punch's own tables in `db/schema.sql` (outbox, job steps, idempotency keys, webhooks, uploads, auth, roles) have the columns this Punch expects; names the migration | `db/schema.sql` has one of them |
| `queries` | `punch db:generate --check` | `db/schema.sql` exists, or in Punch itself |
| `explain` | `punch db:explain --check`: no full scan or sort a query does not accept | `queries` passed and `db/schema.sql` exists |
| `i18n` | `punch i18n:generate --check`: current file, no gaps between locales, a message for every code | `config/locales` exists, and in Punch itself |
| `requires` | `punch requires:generate --check`: `app/requires.gen.cr` requires every file under `app/`, each of a known kind | `app` exists |
| `unreached` | every `app/**/*.cr` and `db/*.cr` but `db/seeds.cr` is in some target's require list (`crystal tool dependencies`): a file nothing requires compiles away silently | `app` or `db` has Crystal files |
| `docs` | `punch docs:check`: guide code blocks quoted, failing, or illustrative and current; quoted messages current; links resolve; every page indexed | in Punch itself |
| `lint` | Ameba with Punch's rules | always |
| `build` | every target, warnings as errors, statistics in `tmp/build-stats/` | always |
| `creds` | key files are neither committed nor unignored; every encrypted file with a key file decrypts; the built app's `creds:check` passes for those environments | `config/credentials` exists |
| `limits` | every Command without a required user is rate limited or exempt | in Punch apps, after `build` |
| `policies` | every operation has a policy or is public | in Punch apps, after `build` |
| `events` | every event is published by an operation | in Punch apps, after `build` |
| `webhooks` | lists inbound webhook providers that do not verify their deliveries; never fails | in Punch apps with providers, after `build` |
| `jobs` | every recurring job's schedule parses | in Punch apps, after `build` |
| `payloads` | `punch jobs:lock --check`, then the lock against `--base`'s with the same rules | `payloads.lock.json` exists, or the app has job types of its own |
| `openapi` | `punch openapi --check`, then `openapi:diff` against `--base` | `openapi.json` exists |
| `specs` | the specs built as one binary (as `crystal spec` would), warnings as errors, then run with `CRYSTAL_WORKERS` threads (4 by default) | `spec` exists |
| `nocache` | the specs again with `PUNCH_CACHE=off`: the app must be correct with an empty cache | `specs` passed, in apps (not Punch itself) |
