# Background jobs

Learn it in: [Background Jobs](guides/background-jobs.md).

Work that should not hold up a request runs as a job: a typed struct stored in `queue.db`, claimed by a worker in its own execution context, retried with backoff when it fails, and visible from the command line. No Redis and no separate service: the queue is one more SQLite file next to `primary.db`.

```crystal
module Billing::Invoices
  @[Punch::Job::Options(queue: "mail", attempts: 5)]
  record Remind,
    invoice_id : ID do
    include Punch::Job

    def perform(job : Punch::Job::Context) : Punch::Job::Result
      invoice = job.read { |db| Table.find(db, invoice_id) }
      return discard("invoice deleted") unless invoice

      # ... call the mail provider, passing job.key as its idempotency key ...
    end
  end
end
```

## Jobs

A job is a **struct** that includes `Punch::Job`. Its fields are the payload: stored as JSON when it is enqueued and parsed back into the struct when a worker claims it, with the same parsers as everything else (domain primitives and typed IDs read their own JSON). A typed ID with a public form (`docs/core-types.md`) is stored as its rowid, not as `inv_…`, so a payload does not depend on the public-ID key and a binary from before the type had a public form still reads it; step cursors and cached values are stored the same way (`Punch::Stored.json`). Keep the payload to IDs and small values and read the rest when the job runs, so it sees the data as it is then. A `Punch::Secret` in a payload does not compile.

`perform(job : Punch::Job::Context)` does the work and returns a `Punch::Job::Result`:

| Returns | Means | Recorded as |
|---|---|---|
| `nil` | Done | `done` |
| `Punch::Job::Retry.new(reason, after: span?)`, or `retry(reason, after:)` in a job or deferred subscriber | An expected failure worth another attempt (a provider answered 503) | `ready` again after the backoff, or after *after*; `failed` after the last attempt |
| `Punch::Job::Discard.new(reason)`, or `discard(reason)` in a job or deferred subscriber | Nothing left to do (the invoice was deleted) | `discarded`, never retried |

An exception is a bug, but it may be a passing one: it is logged with its backtrace, stored as the job's error, and retried like `Punch::Job::Retry`.

**Jobs run at least once.** After a crash, a deploy that outlasts the shutdown timeout, or a restore, a job can run again. Make it safe to repeat: check the state first, and pass `job.key` as the idempotency key to providers that take one. The key stays the same across attempts. A long job can run in [steps](#long-jobs-steps), so that it repeats only the part since its last save.

What the context gives a running job:

| | |
|---|---|
| `job.read { \|db\| ... }`, `job.write { \|db\| ... }` | Short transactions on `primary.db`. A job is not an operation: it may call other systems, so it holds no transaction while it runs |
| `job.enqueue(OtherJob.new(...), at:, in:)` | A follow-up, straight into `queue.db`, after the write it follows from. Inside `write` it raises |
| `job.id`, `job.attempt`, `job.attempts`, `job.last_attempt?`, `job.queue_name`, `job.key` | About this run |

These do not compile: a job that is a class, a job without `perform(job : Punch::Job::Context)`, `perform` returning something other than `Punch::Job::Result`, options that are not what `@[Punch::Job::Options]` takes, and a job that includes `JSON::Serializable::Strict` (readers ignore unknown fields; see [Payloads across deploys](#payloads-across-deploys)).

### Options

```crystal
@[Punch::Job::Options(queue: "mail", attempts: 5, priority: 10)]
```

| Option | Default | |
|---|---|---|
| `queue` | `default` | A name of lowercase letters, digits, and `_`. Queues are what a process can be limited to and what can be paused |
| `attempts` | `10` | Runs in all, 1 to 100. Retries wait 15 s, tripled each time, at most 6 hours, ±15 % jitter: ten attempts span about 17 hours |
| `priority` | `0` | -100 to 100. Among due jobs, higher runs first; then the one due first |

### Recurring jobs

```crystal
@[Punch::Job::Recurring(cron: "30 3 * * *")]   # every day at 03:30 UTC
@[Punch::Job::Recurring(every: 15.minutes)]    # at :00, :15, :30, :45
```

A recurring job is enqueued with an empty payload, so its fields need defaults (or must be nilable); otherwise it does not compile. Schedules are in UTC.

- **Cron:** five fields, `minute hour day-of-month month day-of-week`, with `*`, numbers, ranges `1-5`, steps `*/15` and `10-50/20`, lists, and English three-letter names (`MON-FRI`, `JAN`); Sunday is 0 or 7. `@hourly`, `@daily`, `@weekly`, `@monthly`, `@yearly` stand for the usual. When both day fields are restricted, a day matching either runs, as in every cron. An expression that does not parse stops `serve` and `jobs` at boot, and `punch check` (step `jobs`) reports it first.
- **Every:** at multiples of the interval counted from the Unix epoch, at least a minute, so every process computes the same times.

Every process with workers runs the schedules. Each run is enqueued once all the same: its unique key is the job type and the scheduled time. Runs missed while no process was up are not made up; the next one runs.

Punch brings its own, among them `Punch::Job::Queue::Purge` (hourly: finished jobs, handed-over outbox entries, and the progress of finished runs of jobs with steps past `PUNCH_JOB_RETENTION_HOURS`, 72 by default), `Punch::Auth::Purge` (hourly: expired sessions, API tokens, and one-time tokens; does nothing in an app without an actor), and `Punch::Backup::Verify` (04:00 UTC: restores the backup and checks it, `docs/backup.md`; does nothing in a process that replicates nothing).

### Concurrency limits

```crystal
@[Punch::Job::Concurrency(1, by: :invoice_id)]   # one at a time per invoice
@[Punch::Job::Concurrency(2, group: "stripe")]   # two at a time in all, shared by every job in the group
```

The key is the group (the job's type unless given), followed by the value of the field *by*. The limit holds across processes. A due job whose key is at its limit waits as `blocked`, out of the way of other jobs, and goes back to `ready` when a job of its key finishes, is retried, or is handed back; each heartbeat also unblocks keys with free slots, in case the job holding one ended in a crash.

## Enqueuing

```crystal
Punch::Job::Queue.enqueue(Remind.new(invoice.id))                    # due now
Punch::Job::Queue.enqueue(Remind.new(invoice.id), in: 3.days)        # delayed
Punch::Job::Queue.enqueue(Remind.new(invoice.id), at: invoice.due_at)
```

`Punch::Job::Queue.enqueue` writes straight into `queue.db`, which is a different file from `primary.db`: it cannot be part of a transaction there. It is for code that runs **outside** a transaction: a job enqueuing a follow-up (`job.enqueue`), a command, a script. Called inside any write transaction it raises, because the data could roll back while the job stays, or the job could be lost while the data commits.

### From a Command: the outbox

A Command enqueues through its outbox: it asks for the handle in `call`, and the type lists every job it may enqueue.

```crystal
def call(input : Input, db : Punch::Writer, actor : Invoicing::Actor, grant : Punch::Grant(Send),
         jobs : Punch::Jobs(Remind)) : Result
  # ... save the sent invoice ...
  jobs.enqueue(Remind.new(sent.id), at: sent.due_at)
end
```

`jobs.enqueue` writes the job to `punch_outbox` in `primary.db`, in the Command's transaction: if the Command fails or raises, the job is gone with its writes; if it commits, the job will run. After the commit, the outbox relay of the process hands the entry over to `queue.db` at once; entries of other processes, and any a crash left behind, are found within a second.

- **Hand-over is idempotent.** Every entry has a random key, which becomes the job's unique key. An entry handed over twice (a crash between the insert and the mark, two processes, a restore) makes one job.
- **The relay runs only in an app that enqueues**: some Command takes `Punch::Jobs`, or some subscriber is deferred (known at compile time). An app without either has no outbox table to poll. If the table goes missing while the relay runs, it logs that once, with the way out, not every second.
- **Entries are kept** after hand-over for the retention window, for the reconciliation after a restore, then purged with finished jobs.
- **Deferred subscribers** (docs/events.md) take the same path: one entry per subscriber and event.
- A Query or a Page that asks for `Punch::Jobs` does not compile; neither does a type in it that is not a job, or enqueuing a job outside it. Never make a handle by hand (`Punch/EventsHandle` reports it); specs use `Punch::Spec.jobs(Command, writer)`.

The table lives in the app's migrations, like the auth tables. Write it with `punch db:migration --punch outbox`, which creates the migration with this SQL (`Punch::Job::Outbox.sql`); `serve` refuses to start without it in an app that enqueues from Commands:

```sql
CREATE TABLE punch_outbox (
  id                INTEGER PRIMARY KEY,
  key               TEXT    NOT NULL UNIQUE,
  queue             TEXT    NOT NULL,
  type              TEXT    NOT NULL,
  version           INTEGER NOT NULL,
  payload           TEXT    NOT NULL,
  priority          INTEGER NOT NULL,
  run_at            INTEGER NOT NULL,
  max_attempts      INTEGER NOT NULL,
  concurrency_key   TEXT,
  concurrency_limit INTEGER,
  traceparent       TEXT,
  created_at        INTEGER NOT NULL,
  handed_over_at    INTEGER
) STRICT;

CREATE INDEX punch_outbox_pending ON punch_outbox (id) WHERE handed_over_at IS NULL;
CREATE INDEX punch_outbox_handed_over ON punch_outbox (handed_over_at) WHERE handed_over_at IS NOT NULL;
```

## Long jobs: steps

A job that walks through many rows, or waits on another system, can run as **steps**, each resumed where it stopped. Without steps a job starts over from the beginning after a deploy that outlasts the shutdown timeout, a crash, or a retry. With steps it continues from the last saved point.

```crystal
module Catalog::Products
  record Reprice,
    list_id : PriceLists::ID do
    include Punch::Job
    include Punch::Job::Stepped

    @[Punch::Job::Step]
    def check_list(job : Punch::Job::Context) : Punch::Job::StepResult
      list = job.read { |db| PriceLists::Table.find(db, list_id) }
      return discard("price list #{list_id} was deleted") unless list

      nil
    end

    @[Punch::Job::Step]
    def reprice(job : Punch::Job::Context, products : Punch::Job::Cursor(ID)) : Punch::Job::StepResult
      batch = job.read { |db| Queries.products_after(db, after: products.at, limit: 500) }
      return if batch.empty?

      job.write do |db|
        batch.each { |product| Queries.set_price(db, product.id, price_for(product)) }
        products.continue(batch.last.id)
      end
    end

    @[Punch::Job::Step]
    def notify(job : Punch::Job::Context) : Punch::Job::StepResult
      # ...
    end
  end
end
```

- **Steps** are the methods marked `@[Punch::Job::Step]`. They run in the order they are defined, each once. Punch defines `perform`, so the job does not.
- **A step takes the context**, and optionally a `Punch::Job::Cursor(T)`: where the step stopped. `products.at` is `nil` on the first call.
- **A step returns `Punch::Job::StepResult`:**

| Returns | Means |
|---|---|
| `nil` | This step is done; the next one starts |
| `products.continue(value)` | Call the step again with *value* as its cursor |
| `products.continue(value, in: span)`, `again(in: span)` | The same, after *span*: the job goes back to the queue meanwhile. `again` keeps the cursor it has, and works in a step without one |
| `retry(reason)`, `discard(reason)` | As from `perform`. A retry resumes this step at its cursor |

**What runs once.** A finished step is not run again, and neither is a call whose cursor was saved. Return the cursor from inside the `job.write` that does the work, as `reprice` does above: the cursor then commits with the batch, so a crash either keeps both or neither, and the batch runs exactly once. Returned outside a write, the cursor is saved in a transaction of its own after the call. Work done between two saves can run again, so it must be safe to repeat, as in any job. Calls to other systems always fall in that gap: pass `job.key` as their idempotency key.

**Stopping.** Keep each call short, a batch rather than the whole walk: the worker checks between two calls whether its process is stopping. If it is, the job goes back to the queue **without counting an attempt**, and the next worker resumes it at once. A deploy does not wait for a long job, and does not restart it. A crash counts the attempt as usual, and the job resumes from the last save.

**Waiting.** `again(in: 5.minutes)` polls another system without holding a worker or using attempts:

```crystal
@[Punch::Job::Step]
def wait_for_export(job : Punch::Job::Context) : Punch::Job::StepResult
  return again(in: 5.minutes) unless provider.export_ready?(job.key)

  nil
end
```

A job that waits never fails for it. Stop it with `punch jobs:discard ID`.

**The cursor** is any type a payload may hold: an ID, a time, a provider's page token, or a record of several values for keyset order on a column that is not unique:

```crystal
record Position, created_at : Time, id : ID do
  include JSON::Serializable
end

@[Punch::Job::Step]
def export(job : Punch::Job::Context, rows : Punch::Job::Cursor(Position)) : Punch::Job::StepResult
  # ... rows after rows.at, ordered by created_at, then id ...
end
```

Order the rows a cursor walks by something unique and stable, or a resumed step can skip rows or repeat them. A cursor holds values, never a whole row; holding a record does not compile.

**Retries and discards by hand.** `punch jobs:retry ID` resumes a failed run where it stopped. A run that a step discarded starts over: discarding forgets its progress.

**Across deploys.** A run stopped part-way is resumed by the next binary, by step name, with the cursor as saved. `payloads.lock.json` records each job's steps, in order, with each cursor's schema, and `punch check` applies the payload rules:

| Change | |
|---|---|
| Add a step | Compatible. Runs already stopped at a later step do not run it (the check says which) |
| Change a cursor's type compatibly (a field added as nilable) | Compatible |
| Change a cursor's type otherwise | Breaks: a run stopped at the step could not read its cursor. Keep the type, or give the step a new name |
| Remove or rename a step | Refused until acknowledged: a binary without the step parks a run stopped at it as `incompatible`. Once `punch jobs:versions` shows none of the job unfinished in every environment, `punch jobs:lock --drop 'Type#step'` |

**Progress lives in `primary.db`**, in `punch_job_progress`, one row per run: the step it is at, the cursor, and when it was saved. Because it sits next to the data, a restore of `primary.db` rolls both back together, and a run started again resumes from a point that matches the data. Every app has the table, since Punch's own nightly `Punch::Database::Encryption::Run` runs in steps: `punch new` writes its migration, and an app made before writes it with `punch db:migration --punch steps`. `punch check` (step `punchtables`) and `serve` refuse to go on without it. The progress of finished runs is purged with finished jobs. A job with steps gets a random unique key when enqueued directly, so its progress never meets that of another job.

`punch jobs:show ID` shows where a run stopped:

```
step          reprice (2 of 3: check_list, reprice, notify)
cursor        4812
saved         2026-11-01 10:14:03, 12 saves
```

These do not compile: steps in a job that does not include `Punch::Job::Stepped`, a job with steps that defines `perform` or marks no step, a step with other arguments than the context and a cursor, a step returning something other than `Punch::Job::StepResult`, and a cursor continued with a value of another type.

## Payloads across deploys

A payload written by one binary is read by another: old payloads by new code after a deploy, new payloads by old code after a rollback or while two processes hand over, and delayed, retried, and recurring jobs can outlive several releases. Deferred event payloads (docs/events.md) are payloads too, and composites stored as JSON documents follow the same rules, in the lock's `documents` section (docs/composites.md, "Versions"). Punch handles this in three layers, cheapest first.

### 1. Compatible changes, checked in CI

`payloads.lock.json`, committed next to `openapi.json`, records every stored job type, the payload it carries (the job, or the event of a deferred subscriber), the payload's version, and its schema, derived from the struct by the same derivation as OpenAPI. `punch jobs:lock` writes it; `punch check` (step `payloads`) fails when it is stale, and when a change since the base revision (`--base`, else `origin/main` or `main`) is one stored payloads cannot follow.

| Change | |
|---|---|
| Add a field that is nilable or has a default | Compatible: old payloads lack it and get the default; old binaries ignore it |
| Remove a field that was nilable or defaulted | Compatible: old binaries default it |
| Add a required field (neither nilable nor defaulted) | Breaks: payloads already waiting lack it |
| Remove a required field, or make it nilable | Breaks: old binaries require it in new payloads |
| Make a nilable field required | Breaks: old payloads may lack it |
| Change a field's type, down to enum members and number formats | Breaks |
| Remove a job type or a deferred subscriber | Refused until acknowledged: jobs of it still waiting would never run. Once `punch jobs:versions` shows none in every environment, `punch jobs:lock --drop 'Type'` |

Objects inside a payload (and in arrays) follow the same rules field by field. A breaking change fails with the fields it breaks and the two ways out: make it compatible, or raise the version.

Keep payloads to IDs and small values. A field that holds a generated record (a whole row) fails the derivation with a message; read the row when the job runs. A collection (`Array`, `Hash`, `Set`, `Bytes`, a tuple, `JSON::Any`) in a job or an event is reported by `Punch/PayloadFields`: store the IDs that find the rows instead, or say on the line why a short list belongs there. Calls to other systems belong in jobs, not in an operation's `call`: `Punch/OutsideCalls` reports HTTP clients, sockets, processes, and `Mailer.deliver` there.

### 2. Breaking changes are a new version

Raise the payload version and keep the old shape as a **frozen type** that converts itself one step on. The compiler checks the chain:

```crystal
@[Punch::Payloads::Version(2, from: {1 => V1})]
record Remind,
  invoice_id : ID,
  channel : Channel do
  include Punch::Job

  def perform(job : Punch::Job::Context) : Punch::Job::Result
    # ...
  end

  # Version 1: before reminders had a channel. Never change it.
  struct V1
    include Punch::Payloads::Frozen

    getter invoice_id : ID

    def upgrade : Remind
      Remind.new(invoice_id, Channel::Email)
    end
  end
end
```

- Copy the old fields into the frozen type exactly as they were: `punch jobs:lock` compares its schema with what the lock recorded for that version, and later with itself (a frozen type never changes).
- `upgrade` declares its return type: the job (or event) itself, or the frozen type of a later version, so `{1 => V1, 2 => V2}` reads version 1 through `V1#upgrade : V2` and `V2#upgrade : Remind`. Going backwards does not compile; neither does a type in `from:` that is not a frozen payload, or a version in `from:` that is not below the current one.
- Events take the same annotation; a deferred subscriber gets the upgraded event.
- New payloads are written with the new version (every job row and outbox entry stores its version).
- Delete a frozen type once `punch jobs:versions` shows no job and no outbox entry of its version left, in every environment. Payloads of a version nothing reads any more are parked, not lost.

Test a conversion with `Punch::Spec.read_payload(Remind, 1, %({"invoice_id": 7}))`, which reads as a worker does.

### 3. Nothing is failed or dropped for being unreadable

A worker claims only versions its binary reads, up to its newest: an old binary leaves a newer binary's payloads waiting during a handover or after a rollback, and the newer binary runs them when it is back. A payload that is claimed and still does not parse, because it is malformed, its version is older than the oldest frozen type, or a conversion raised, is **parked** as `incompatible`: the attempt is not counted, the error is stored and logged as an error, and the job waits until it is retried (`punch jobs:retry ID`, with a binary that reads it) or discarded.

## Workers

`serve` runs the workers in-process (`PUNCH_JOBS=on`, the default): a dispatcher fiber claims due jobs and runs each in a fiber of its own, in an execution context with `PUNCH_JOB_THREADS` threads (2), at most `PUNCH_JOB_CONCURRENCY` jobs at once (10), from every queue or those in `PUNCH_JOB_QUEUES` (comma-separated). Jobs do not take threads from requests.

- **Claiming** is one write transaction on `queue.db`: the most urgent due jobs (priority, then due time, then age) of the types this binary knows, from queues that are not paused, become `running` with this process's ID and one more attempt. A binary never claims a job type it does not know, or a payload version newer than it reads, such as a newer binary's during a handover.
- **Wake-up:** an enqueue in the same process wakes the dispatcher at once. Jobs enqueued by another process, and delayed jobs coming due, are found by polling, at most a second late.
- **Heartbeat:** each process records a heartbeat every 10 s in `queue.db`. Every heartbeat also hands back the jobs of processes silent for a minute: they go back to `ready` with the attempt counted, so a job that kills its process every time ends as `failed` instead of looping.
- **Shutdown:** on SIGTERM the workers stop claiming, wait up to 25 s for running jobs, then hand the rest back to the queue without counting the attempt, before the databases close. A job handed back may still finish in the meantime; its result is not recorded over the hand-back, so it runs again.

Two processes on one `queue.db` take turns on SQLite's lock: every job is claimed exactly once.

### A separate process

`punch jobs` (the app's binary: `bin/app jobs`) runs the workers, the schedules, and the outbox relay without an HTTP server, with the same settings and databases as `serve`. Start `serve` with `PUNCH_JOBS=off` next to it, or run both with their own `PUNCH_JOB_QUEUES`. Enqueues from `serve` reach it through `queue.db`, by polling. It stops on SIGINT or SIGTERM like `serve`.

### Pausing

`punch jobs:pause QUEUE` stops every process from claiming jobs of the queue; jobs already running finish. `punch jobs:resume QUEUE` lets them claim again. Jobs keep being enqueued meanwhile.

## States

| State | |
|---|---|
| `ready` | Waiting; shown as `scheduled` until it is due |
| `running` | Claimed by a process |
| `blocked` | Due, but its concurrency key is at its limit |
| `done` | Finished; purged after the retention window |
| `discarded` | Finished by `Punch::Job::Discard` or by hand; purged like `done` |
| `failed` | Out of attempts; kept until retried or discarded |
| `incompatible` | Parked: its payload does not parse in the binary that claimed it; kept until retried or discarded, never purged |

`queue.db` is Punch's own file: its tables are created on first open and are not part of the app's migrations. It is never recreated: a file written by a binary with another queue layout is refused at boot with a message, and its jobs are kept.

## Inspecting

Every command works on `queue.db` in `PUNCH_STORAGE`, also while the app runs, and takes `--json`.

| Command | |
|---|---|
| `punch jobs:list [--state S] [--queue Q] [--type T] [--limit N]` | Jobs, newest first. States: `ready`, `scheduled`, `blocked`, `running`, `done`, `discarded`, `failed`, `incompatible` |
| `punch jobs:show ID` | One job with its payload and last error with backtrace; for a job with steps, the step it is at and its cursor |
| `punch jobs:stats` | Jobs per queue and state, and the processes running workers with their last heartbeat |
| `punch jobs:retry ID` | A failed, discarded, or incompatible job runs again, with fresh attempts |
| `punch jobs:discard ID` | A waiting, failed, or incompatible job is discarded. A running job cannot be |
| `punch jobs:pause QUEUE`, `punch jobs:resume QUEUE` | Stop and restart claiming from a queue, in every process |
| `punch jobs:types` | The app's job types (deferred subscribers among them) with queue, attempts, priority, payload version and the versions it reads, concurrency limit, and schedule with its next run |
| `punch jobs:versions` | Unfinished jobs and pending outbox entries per type and payload version, against the versions this binary reads: when a frozen type can go |
| `punch jobs:lock [--check] [--drop TYPE] [--drop 'TYPE#step']` | The `punch` tool: writes `payloads.lock.json` from a derivation build, refusing breaking changes; `--check` also fails when stale |

## Tracing

The wide event of a request counts `punch.jobs.enqueued` through the outbox. Each run of a job is a trace of its own and one wide event: the root span `job Billing::Invoices::Remind` (kind consumer), continuing the trace that enqueued it, with `messaging.destination.name` (the queue), `messaging.message.id` (the job ID), `punch.job.type`, `punch.job.attempt`, `punch.job.latency_ms` (from due to start), and `punch.job.outcome` (`done`, `retried`, `discarded`, `failed`, `parked`, `paused` for a job with steps that went back to the queue between steps, or `lost` when it had been handed back). A job with steps adds `punch.job.steps` (how many), `punch.job.step` (the last one called), `punch.job.step_saves`, and `punch.job.paused` (`stopping` or `waiting`) when it paused. A parked job's span is failed with the reason and carries `punch.job.version`. A deferred subscriber's run adds `punch.subscriber`, `punch.event`, and `punch.delivery: deferred`. A retry or failure marks the span failed with the reason. Spans of the job's transactions and statements are below it.

## Specs

`punch/spec` gives every example a fresh in-memory `queue.db` (`Punch::Spec.queue`), which `Punch::Job::Queue.enqueue` uses. Nothing runs by itself: run due jobs with `perform_jobs`, in the example's fiber, against `Punch::Spec.db`. It and `enqueued` first hand the committed outbox entries of `Punch::Spec.db` over to the queue (`Punch::Spec.hand_over`), so jobs enqueued by Commands and deferred subscribers are there too.

```crystal
Punch::Job::Queue.enqueue(Remind.new(id), in: 3.days)
Punch::Spec.enqueued(Remind).map(&.invoice_id).should eq([id])

clock = Punch::Spec.clock
Punch::Spec.perform_jobs.should be_empty # not due yet
clock.advance(3.days)
Punch::Spec.perform_jobs.map(&.outcome).should eq([Punch::Job::Queue::Outcome::Done])
```

`perform_jobs` repeats until nothing is due, so follow-ups a job enqueues run too; retries wait for their backoff, so advance the clock to see them. Each run returns its ID, type, outcome, and stored error. Test a job's logic directly by calling `perform` with a context from a spec that needs one, or through `perform_jobs`. To call a Command directly, get its outbox handle with `Punch::Spec.jobs(Command, writer)`.

The `enqueue` matcher checks what a block added, outbox entries handed over first; its failure lists the jobs of that type that were enqueued instead:

```crystal
-> { client.post(Invoices::Send.path(invoice_id: id)) }.should enqueue(Remind, invoice_id: id, times: 1)
-> { Punch::Job::Queue.enqueue(Remind.new(id), in: 1.day) }.should enqueue(Remind, at: clock.now + 1.day)
```

A job with steps runs through `perform_jobs` like any other. To check that it ends the same wherever a deploy stops it, stop it after every save and let `perform_jobs` resume it until it is done; `job_progress` shows where a run stopped:

```crystal
Punch::Job::Queue.enqueue(Reprice.new(list_id))
Punch::Spec.perform_jobs(interrupt_every: 1).last.outcome.should eq(Punch::Job::Queue::Outcome::Done)

progress = Punch::Spec.job_progress(id).should_not be_nil
progress.step.should eq("reprice")
progress.cursor(Products::ID).should eq(last_repriced)
```

`Punch::Spec.db` has the progress table from `db/schema.sql`. A step's `again(in:)` puts the job back as `scheduled`; advance `Punch::Spec.clock` to run it again.
