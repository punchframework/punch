# Ops data: errors, job runs, events, performance

Learn it in: [The Ops Console and `punch ops`](guides/the-ops-console.md).

A Punch app records what its operators need in `ops.db`, a SQLite file next to the others in `PUNCH_STORAGE`. No third-party service is involved. The ops console (`/_punch`), for people, agents (markdown), and programs (JSON), and the `punch ops` commands, on the box or against a running app, read it. Trouble is announced as domain events ("Notifications").

## What is recorded

`ops.db` is filled by `Punch::Ops::Sink`, an event sink on the tracer (`docs/tracing.md`). It sees the same wide events as the JSON log and the trace export, so the three cannot disagree.

| Table | Holds | Kept |
|---|---|---|
| `punch_ops_errors` | One row per **error group**: exception class, where it was handled (the route, `job <Type>`, a subscriber, or a reported loop), latest message and backtrace, first and last seen, count, resolved or open | Open groups always; resolved ones until `PUNCH_OPS_RETENTION_DAYS` after they were last seen |
| `punch_ops_occurrences` | Each time a group's exception was raised: time, trace ID, message, and a link to the stored wide event | `PUNCH_OPS_RETENTION_DAYS` (14) |
| `punch_ops_records` | Stored **wide events**: every job run (sampled), every failed request (a 5xx or an exception), every error reported outside a trace; the whole event as JSON | `PUNCH_OPS_RETENTION_DAYS` |
| `punch_ops_events` | Each **domain event** a transaction committed, with its trace ID and the request or job that published it (sampled) | `PUNCH_OPS_RETENTION_DAYS` |
| `punch_ops_stats` | **Performance** per request route, job type, and named query, in buckets of 10 minutes: runs, failures (5xx, failed job runs, failed statements), total and longest time, runs per duration bucket, time waiting for the writer, time in SQL, statements, rows, answers replayed for an idempotency key | `PUNCH_OPS_RETENTION_DAYS` |

**Sampling** (`PUNCH_OPS_SAMPLE_PERCENT`, 100 by default) applies only to successful job runs and to events. It is decided by trace ID, so a request's events and the jobs it enqueued are kept or left out together. Errors and failures are always kept. A successful request is stored only when it took `PUNCH_OPS_SLOW_MS` (500) or longer, at most 10 per route and 10 minutes, so an incident that slows everything keeps a sample.

**Performance** is counted for every request, job run, and named query, whatever the sampling: the sink adds them up in memory per name and 10-minute bucket and writes the sums every 10 seconds and when it closes. A named query is counted by its name (`-- name:` in its `.sql` file, `Billing::Invoices::Queries.page`), which every statement span already carries, so no SQL is fingerprinted. Each statement's time goes into the trace beside the wide event's totals (`Trace::Span#tally_query`), never into the exported attributes. Durations are counted in the buckets of the metrics (`Metrics::DURATION_BOUNDS`, 0.5 ms to 10 s), so a percentile in the console is the upper bound of the bucket it falls in, at most the longest run. Statements outside any request or job (Punch's own loops, the sink itself) are not counted.

**Grouping.** An error's fingerprint is its class, where it was handled, and the files of the top five frames of its backtrace, without line numbers: a deploy that moves code keeps the group, and messages, which often hold values, do not split it. Method names are left out because the symbolizer names frames of macro-generated code differently from build to build. A resolved group opens again when it recurs.

**What counts as an error:** an exception that reaches a request or a job; an exception in an after-commit subscriber (the response stands, `docs/events.md`); a failure in a worker's loop (`tracer.report`). A job that returns `Punch::Job::Retry` or is parked fails its run (kept as a failed record) but is not an exception. App code records an exception it handles with `Punch::Trace.event.record_exception(ex, "where")`.

**Writes.** The sink hands events to a fiber that writes in batches of up to 256 per transaction through `ops.db`'s own writer, so requests never wait for it. When 4,096 events are waiting, more are dropped and the count is logged, rather than slowing requests. `serve` closes the sink before the databases at shutdown.

**The file.** `ops.db` is Punch's own, like `queue.db`: its tables are not in the app's migrations, and a file of another layout is refused, never recreated, because it holds history wanted after losing the box. Layout 2 added `punch_ops_stats`, layout 3 what notifications need (when each error group opened and up to which opening it was announced, and `punch_ops_notices`); a file of an earlier layout gets them when opened and keeps its history, its groups counted as announced. It is replicated with the other files (`docs/backup.md`); `PUNCH_BACKUP_EXEMPT=ops` leaves it out. Exception messages and backtraces may contain personal data; the retention window bounds how long.

`PUNCH_OPS=off` opens no `ops.db` and records nothing. With `PUNCH_TRACE=off` there are no wide events, so nothing reaches it either.

## Retention

`Punch::Ops::Purge`, one of Punch's recurring jobs, runs hourly and removes what is past `PUNCH_OPS_RETENTION_DAYS`, stats buckets included. It is in every app's `payloads.lock.json`. `Punch::Database::Audit::Run` audits the stored values every night and reports columns that no longer parse as `Punch::Database::Audit::Unparseable` errors (`docs/queries.md`, "Auditing stored values"). `Punch::Database::Encryption::Run` brings encrypted columns to the signing key every night (`docs/queries.md`, "Converting and re-encrypting"). `Punch::Database::Upgrade::Run` rewrites JSON documents of older versions every night (`docs/composites.md`, "Versions").

## The console

The ops console is a set of Punch pages and Commands below `/_punch`, built like any app's. An app mounts it once:

```crystal
require "punch/ops/console"

module Accounts::Roles
  # Runs the app: the ops console.
  struct Operator
    include Punch::Role

    permits Punch::Ops::Console::Operations
  end
end

Punch::Ops::Console.mount Invoicing::Actor, Punch::Ops::Console::ByRole
```

`mount` names the app's actor and the console's policy; requiring the file without mounting does not compile. `Punch::Ops::Console::Operations` is a global role that permits every console operation, and `ByRole` asks the roles (docs/authorization.md): whoever holds a global role that includes it may use the console, in every environment, and the wide event records the role as `punch.roles`. Give the first operator on the box with `bin/<app> roles:assign Accounts::Roles::Operator --email ADDRESS` once they have verified the address; `punch new` seeds one for development. Punch's own role does not make an app need the role tables; only the app's roles do.

The console has its own stylesheet (`punch/ops.css`, served with the app's assets) and no script; its bars are drawn by CSS, for browsers only, as their numbers are on the page.

Another policy works too. It takes `**params` (an error's or a job's ID); answer `not_found` rather than `forbid`, so the console does not show that it exists. Without a policy, `mount Invoicing::Actor` uses `Punch::Ops::Console::Development`: any signed-in user when the process runs with `PUNCH_ENV=development`, 404 everywhere else. So a production app shows no console until it says who may use it. Links to it (`Punch::Ops::Console::IndexPage.href`) ask the policy and are left out for everyone else, like any link.

| Page | Shows | Actions |
|---|---|---|
| `GET /_punch` | A banner while a restore waits for confirmation; open errors, occurrences and failed runs in the last 24 hours, jobs per state, worker processes, requests in the last hour | |
| `GET /_punch/errors` (`?resolved=true`) | Error groups, most recently seen first | |
| `GET /_punch/errors/:error_id` | Where, counts, message, backtrace, the latest occurrences with the wide event of each (every field) and its timing | Resolve, Reopen |
| `GET /_punch/jobs` | Counts per queue and state, failed jobs grouped by type with the latest error, parked (incompatible), running, and scheduled jobs, recurring jobs with their next run, processes with heartbeats | Retry all failed of a type, pause and resume a queue |
| `GET /_punch/jobs/:job_id` | State, attempts, keys, payload, last error, and the job's runs from `ops.db` | Retry, Discard |
| `GET /_punch/performance` (`?kind=request\|job\|query`, `?window=hour\|day\|week`) | Per route, job type, or named query: runs, failed, p50, p95, p99, longest, average, total time; for requests and jobs the average writer wait and statements per run, for requests the replayed answers, for queries the rows per statement; the most time spent first, each with its p50, p95, and p99 as bars. The slowest stored requests | |
| `GET /_punch/performance/series?kind=…&name=…` | One route, job type, or query per 10-minute bucket, newest first: when it started to be slow | |
| `GET /_punch/records/:record_id` | One stored wide event (a slow or failed request, a job run), every field, and its timing: a job's wait in the queue and then its run, and the time in database statements, writer waits, and cache computations as totals within the run (`ops.db` keeps no child spans) | |
| `GET /_punch/events` | The outbox: entries waiting to be handed over and the oldest one's age. Each event type with how often it was committed in the last 24 hours, the operations that publish it, and its subscribers with their delivery, a deferred one's runs and failures, and open errors of each; the latest committed events | |
| `GET /_punch/database` | Each file's size, WAL size and frames, writes waiting for the writer, checkpoints (count, average, longest; incomplete ones apart), replica lag; the last restore check (`verification.json`) with its problems and dry-run counts, the recovery waiting for confirmation, the last recovery; every metric of the process as the OTLP exporter reads it | |
| `GET /_punch/recovery` | The restore waiting for confirmation: files and their points, and each list of the reconciliation with its entries and jobs; or the last confirmed recovery | Confirm (as `punch recovery:confirm`) |
| `GET /_punch/keys` | The key ring's keys with creation date, age, role (signs, verifies, pending), and how many messages each key that does not sign opened since the process started; each credential with where it came from (environment, file, default, not set), never a secret's value | |
| `GET /_punch/webhooks` (`?provider=…`, `?state=failed`) | Providers with their verification and invocations per state; the latest invocations | |
| `GET /_punch/webhooks/:invocation_id` | One invocation: state, key, attempts, times, error, the kept headers, the stored body (up to 64 KiB) | Retry (failed, unprocessable, rejected), Replay (processed, ignored, discarded) |
| `GET /_punch/mail` | The mail this process captured (`delivery: capture`, `docs/mail.md`), newest first; says so when mail is sent instead | |
| `GET /_punch/mail/:mail_id` | Sender, recipients, the job's key, locale, the text part as a mail client shows it, and a link to the HTML part (`/_punch/mail/:mail_id/html`) | |
| `GET /_punch/cache` | Every cache store used in this process: tier, time-to-live, entries in memory, hits per tier, misses, joins, hit rate, compute time, evictions, errors; `cache.db`'s bytes against `PUNCH_CACHE_MB`, and entries, expired entries, and bytes per store and shape, an earlier shape marked (`docs/cache.md`) | Clear a store (this process's memory and the file) |
| `GET /_punch/bans` | Addresses banned for probing, from `cache.db` (so also those the other process banned): which ban, since and until when, the first paths asked for; ended bans still counted for the next; probes and refusals since the process started (`docs/http.md`, "Probes and bans") | Lift a ban, here and in the file; the other process lets the address in within 30 seconds |

Each action is a Command (`ResolveError`, `ReopenError`, `RetryJob`, `DiscardJob`, `RetryFailed`, `PauseQueue`, `ResumeQueue`, `ClearCache`, `LiftBan`, `ConfirmRecovery`, `RetryWebhook`, `ReplayWebhook`), so it also answers JSON: `POST /_punch/jobs/42/retry` returns `{"id": 42, "state": "ready"}`, 404 `not_found`, or 409 `wrong_state` with the state it found. The console's routes carry `@[Punch::Unlisted]`: they answer, but they are not in `openapi.json`. `punch routes` marks them `(unlisted)`.

The pages are plain semantic HTML with Turbo and no stylesheet: the console cannot add files to the app's assets, and the content security policy allows no inline styles. The Commands write to `queue.db` and `ops.db` while holding the primary database's write transaction that every Command gets; the transaction is empty, so this costs the writer a few milliseconds.

**Retrying and replaying a webhook.** Both move the invocation back and enqueue its processing through the outbox in the Command's transaction, as the endpoint does, so it runs in the `webhooks` queue with the provider's concurrency limit. A failed or unprocessable invocation goes back to `verified` (it was verified once); a rejected one to `received`, so its signature is checked again, as of when it arrived, before anything is parsed: a retry never processes unverified data. Replaying a processed or ignored one runs the provider's `process` for the same delivery a second time, which the endpoint never does: use it for a handler that is safe to repeat, or after fixing one that ignored or mishandled the event.

**Confirming a recovery** applies the reconciliation as `punch recovery:confirm` does (`docs/backup.md`), with the process's own queue and the Command's write transaction on the primary, and background work starts in every process within seconds.

The pages read what the process has: `ops.db` and `queue.db` through `Ops.current?` and `Queue.current?`, the metrics registry, the storage directory (`Punch::Backup.storage`), the key ring, and the credentials loaded at boot (`Punch::Credentials.loaded`). Performance, events, and errors cover every process writing to the same `ops.db`; cache counters, old-key uses, and metrics are the serving process's own.

## For agents and programs

**Every console page is agent-readable** (`@[Punch::AgentReadable]`, `docs/views.md`), except the raw HTML part of a captured mail: an agent with an operator's API token reads `GET /_punch/errors.md` (or any console path with `Accept: text/markdown`) and gets the open errors as markdown, with links to each error's `.md` page, its backtrace and wide events, and the buttons as action blocks (Resolve, Retry, Retry all, Pause, Discard, Confirm). Agents act as a browser does, with the token: `client.act(page, "Resolve")` in a spec. The pages are `@[Punch::Unlisted]`, so they are not in `/llms.txt`; start an agent at `/_punch.md`. An agent without access gets the same 404 as a person.

**The reports are JSON on the same paths.** A Query beside each page that `punch ops` mirrors answers programs (`Accept: application/json`, or no `Accept`): `GET /_punch`, `/_punch/errors` (`?resolved=true`, `?all=true`, `?limit=`), `/_punch/errors/:error_id`, `/_punch/jobs`, `/_punch/jobs/:job_id`, `/_punch/performance` (`?kind=`, `?window=`, `?limit=`), `/_punch/records/:record_id`. Each answers the report type `punch ops` prints (`Punch::Ops::Reports`), so the JSON is the same document whether read on the box or remotely. Where the file a report reads is not open in the serving process, the answer is 404 `unavailable` with the file in `database`; the overview has `null` for each missing part. The actions were already Commands that answer JSON.

The loop this enables: an agent reads an error, follows the stored wide event (`ops:record`, `/_punch/records/:id`) to the route or the job and the named query, proposes a fix, and `punch check` verifies it.

## Notifications

Trouble is announced as domain events, so alerting is a subscriber of the app's (usually deferred, to mail or page someone), not a separate system:

| Event | Published when | Fields |
|---|---|---|
| `Punch::Ops::ErrorOccurred` | an error group opens: a new fingerprint, or one that recurs after it was resolved (`reopened`). Reopening by hand announces nothing: someone already knows | `error_id`, `exception`, `source`, `occurrences`, `reopened?` |
| `Punch::Ops::JobsFailing` | jobs of a type have failed for good or are parked with an incompatible payload; announced again only after none of that type is left in either state | `job_type`, `failed`, `incompatible` |
| `Punch::Ops::BackupStale` | a replicated file is more than `Backup::Monitor::LAGGING` (5 minutes) behind (`lagging`, with `database` and `lag_seconds`), or the restore check has not passed for 26 hours (`unverified`) or failed last (`verification_failed`), with `last_passed_at`; announced again only after it recovered | `reason`, `database`, `lag_seconds`, `last_passed_at` |

`Punch::Ops::Notify`, one of Punch's recurring jobs (every minute, in every app's `payloads.lock.json`), looks at `ops.db`, the queue, and the backup monitor of the process it runs in, and publishes what started in one transaction of the primary, so deferred subscribers get their jobs through the outbox. What was announced is kept in `ops.db`, so each trouble is announced once: at least once, since the events are published before `ops.db` records them; a subscriber that mails should be safe to repeat like any job. At most 20 error groups per run; more wait a minute. An error's message and backtrace are not in the event (messages often hold values, and the event is a payload): read them with `Punch::Ops.current?.try(&.error(event.error_id))`. Nothing is published with `PUNCH_OPS=off`, and nothing about the backup without a replicated file. `punch events` lists the three with the publisher `Punch::Ops::Notify`.

```crystal
@[Punch::Subscriber::Delivery(:deferred)]
struct Ops::Page
  include Punch::Subscriber(Punch::Ops::ErrorOccurred)
  include Punch::Subscriber(Punch::Ops::JobsFailing)
  include Punch::Subscriber(Punch::Ops::BackupStale)

  def call(event, job : Punch::Job::Context) : Punch::Job::Result
    # The app's: mail the operators, or call a pager with `job.key` as the idempotency key.
    Alerts.page(event, job)
  end
end
```

## Command line

All with `--json`, in both binaries. They open `$PUNCH_STORAGE/ops.db` and `queue.db`, also while the app runs; with `--url URL` (in the standalone `punch` binary only; an app's binary runs on the box, refuses `--url` with `remote_unavailable`, and compiles no HTTP client for it) they read and act on a running app's console instead, with the API token of a user its policy admits in `PUNCH_OPS_TOKEN` (never on the command line, where it would land in the shell's history; `punch tokens:create`). `--url` takes `https://`, or `http://` only to this machine. The JSON is the same both ways: the report the console's Query answers.

| Command | Does |
|---|---|
| `punch ops` | Open errors and occurrences in 24 hours, failed job runs, jobs per state, worker processes, requests in the last hour, recovery mode |
| `punch ops:errors [--resolved \| --all] [--limit N]` | Error groups, most recently seen first; open ones by default |
| `punch ops:error ID` | One group with its backtrace and its latest occurrences (trace ID, stored event) |
| `punch ops:resolve ID` | Marks a group resolved; it opens again when it recurs |
| `punch ops:reopen ID` | Opens a resolved group again |
| `punch ops:jobs` | Jobs per queue and state, paused queues, failed jobs by type with the latest error, parked and running jobs, processes |
| `punch ops:job ID` | One job with its payload, last error, and its runs in `ops.db` |
| `punch ops:retry ID` \| `--type TYPE` | Runs a failed, discarded, or parked job again; or every failed job of a type |
| `punch ops:discard ID` | Discards a waiting, failed, or parked job |
| `punch ops:performance [--kind request\|job\|query] [--window hour\|day\|week] [--limit N]` | Runs, failures, p50/p95/p99, longest, total time per route, job type, or named query, the most time spent first |
| `punch ops:slow [--window ...]` | The slowest requests kept (failed, or from `PUNCH_OPS_SLOW_MS`), with their record IDs |
| `punch ops:record ID` | One stored wide event, every field |

An action that does not apply fails as the console's Command does: `not_found`, or `wrong_state` naming the state found. Remotely, a user the policy refuses gets `not_found` (the console does not show itself), a token that does not authenticate `unauthenticated`. The `jobs:*` commands (`docs/jobs.md`) stay the local tools for the queue, with filters the console does not have.

## Testing

```crystal
ops = Punch::Spec.ops                                  # this example's ops.db, in memory
client.post(Invoices::Send.path(invoice_id: id), json: {...})
ops.errors.should be_empty
Punch::Spec.perform_jobs
ops.records(kind: "job").map(&.name).should eq(["job Billing::Invoices::Remind"])
ops.stats("query", since: Time.utc - 1.hour).map(&.name).should contain("Billing::Invoices::Queries.page")
```

Once an example has called `Punch::Spec.ops`, the wide events of `Punch::Spec.client` requests and of `perform_jobs` are recorded in it at once (no batching), their stats too.
