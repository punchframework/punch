require "json"
require "socket"

module Punch
  # The job queue in `queue.db`: Solid Queue's model on one SQLite file.
  # Every change goes through the file's writer, so claiming is a plain
  # `UPDATE` in a `BEGIN IMMEDIATE` transaction; two processes on one file
  # take turns on SQLite's lock.
  #
  # The file and its tables are Punch's own, created here, outside the
  # app's migrations. Unlike `cache.db` it holds work that must not be
  # lost, so a file with another layout is refused, never recreated.
  #
  # Jobs move through these states:
  #
  # | State | Meaning |
  # |---|---|
  # | `ready` | Waiting; due once `run_at` has passed (scheduled before) |
  # | `blocked` | Due, but its concurrency key is at its limit |
  # | `running` | Claimed by a process (`claimed_by`) |
  # | `done` | Finished; kept for the retention window, then purged |
  # | `discarded` | Finished by `Punch::Job::Discard` or by hand; kept like `done` |
  # | `failed` | Out of attempts; kept until retried or discarded |
  # | `incompatible` | Parked: its payload does not parse in the binary that claimed it; kept until retried or discarded |
  class Job::Queue
    Log = ::Log.for("punch.jobs")

    # Bumped when the tables change. A file of another layout is refused.
    LAYOUT = 1

    TABLES = {
      <<-SQL,
        CREATE TABLE punch_jobs (
          id                INTEGER PRIMARY KEY,
          queue             TEXT    NOT NULL,
          type              TEXT    NOT NULL,
          version           INTEGER NOT NULL,
          payload           TEXT    NOT NULL,
          state             TEXT    NOT NULL,
          priority          INTEGER NOT NULL,
          run_at            INTEGER NOT NULL,
          attempts          INTEGER NOT NULL,
          max_attempts      INTEGER NOT NULL,
          unique_key        TEXT    UNIQUE,
          concurrency_key   TEXT,
          concurrency_limit INTEGER,
          claimed_by        TEXT,
          claimed_at        INTEGER,
          enqueued_at       INTEGER NOT NULL,
          finished_at       INTEGER,
          error             TEXT,
          traceparent       TEXT
        ) STRICT
        SQL
      "CREATE INDEX punch_jobs_due ON punch_jobs (priority DESC, run_at, id) WHERE state = 'ready'",
      "CREATE INDEX punch_jobs_running ON punch_jobs (claimed_by) WHERE state = 'running'",
      "CREATE INDEX punch_jobs_by_concurrency ON punch_jobs (concurrency_key, state) WHERE concurrency_key IS NOT NULL",
      "CREATE INDEX punch_jobs_finished ON punch_jobs (finished_at) WHERE state IN ('done', 'discarded')",
      "CREATE INDEX punch_jobs_by_state ON punch_jobs (state, queue, type)",
      <<-SQL,
        CREATE TABLE punch_job_processes (
          id           TEXT    PRIMARY KEY,
          kind         TEXT    NOT NULL,
          pid          INTEGER NOT NULL,
          host         TEXT    NOT NULL,
          queues       TEXT    NOT NULL,
          started_at   INTEGER NOT NULL,
          heartbeat_at INTEGER NOT NULL
        ) STRICT, WITHOUT ROWID
        SQL
      "CREATE TABLE punch_paused_queues (queue TEXT PRIMARY KEY, paused_at INTEGER NOT NULL) STRICT, WITHOUT ROWID",
    }

    STATES = %w[ready blocked running done discarded failed incompatible]

    # Stored errors are cut to this many bytes.
    MAX_ERROR = 8192

    DEFAULT_QUEUE    = "default"
    DEFAULT_ATTEMPTS = 10

    # One job to insert: what `enqueue`, the outbox, and the scheduler
    # write.
    record Entry, queue : String, type : String, version : Int32, payload : String, priority : Int32,
      run_at : Time, max_attempts : Int32, unique_key : String? = nil, concurrency_key : String? = nil,
      concurrency_limit : Int32? = nil, traceparent : String? = nil

    # A job claimed by a worker.
    record Claimed, id : Int64, queue : String, type : String, version : Int32, payload : String,
      attempts : Int32, max_attempts : Int32, run_at : Time, enqueued_at : Time, unique_key : String?,
      concurrency_key : String?, traceparent : String? do
      # Stable across attempts: the outbox entry's key when it came from
      # one, else the job's ID.
      def key : String
        unique_key || "job-#{id}"
      end
    end

    # One job as `jobs:list` and the console show it.
    record Row, id : Int64, queue : String, type : String, version : Int32, state : String, priority : Int32,
      run_at : Time, attempts : Int32, max_attempts : Int32, unique_key : String?, concurrency_key : String?,
      claimed_by : String?, enqueued_at : Time, finished_at : Time?, error : String?, payload : String do
      include JSON::Serializable

      # `scheduled` for a ready job that is not due yet.
      def display_state(now : Time) : String
        state == "ready" && run_at > now ? "scheduled" : state
      end
    end

    # Jobs per queue and state, for `jobs:stats` and `/up`.
    record Count, queue : String, state : String, jobs : Int64 do
      include JSON::Serializable
    end

    # Unfinished jobs per type, payload version, and state, for
    # `jobs:versions`: a frozen type can go once its version has none.
    record VersionCount, type : String, version : Int32, state : String, jobs : Int64 do
      include JSON::Serializable
    end

    # A process that runs workers, by its heartbeat.
    record Process, id : String, kind : String, pid : Int64, host : String, queues : String,
      started_at : Time, heartbeat_at : Time do
      include JSON::Serializable
    end

    # How a claimed job ended, as recorded.
    enum Outcome
      Done
      Retried
      Discarded
      Failed
      # Released by the worker (shutdown) or by the sweep (orphaned):
      # someone else finished the row first.
      Lost
      # Its payload did not parse: parked as `incompatible`, the attempt
      # not counted.
      Parked
      # A job with steps went back to the queue between steps, its attempt
      # not counted: the worker was stopping, or a step waits
      # (`Punch::Job::Stepped`).
      Paused
    end

    @@current : Job::Queue?

    # The queue `serve` and `jobs` opened, for code outside a transaction
    # that enqueues (`Job::Queue.enqueue`).
    def self.attach(queue : Job::Queue) : Nil
      @@current = queue
    end

    def self.detach : Nil
      @@current = nil
    end

    # Where `current` turns when nothing is attached: `punch/spec` sets it
    # to the example's queue.
    # :nodoc:
    class_property fallback : Proc(Job::Queue)?

    def self.current : Job::Queue
      @@current || @@fallback.try(&.call) || raise Error.new("no queue is attached: serve and jobs open queue.db; specs use Punch::Spec.queue")
    end

    def self.current? : Job::Queue?
      @@current
    end

    # Enqueues *job* on the attached queue, directly: only for code that
    # runs outside a transaction. A Command enqueues through its outbox
    # handle, `jobs : Punch::Jobs(...)`.
    def self.enqueue(job : J, *, at : Time? = nil, in delay : Time::Span? = nil) : Int64? forall J
      current.enqueue(job, at: at, in: delay)
    end

    # Raised for misuse of the queue, which is a bug in the caller.
    class Error < Exception
    end

    getter database : Database

    @listeners = [] of Proc(Nil)
    @listeners_lock = Mutex.new

    def initialize(@database : Database)
      @database.write { |db| setup(db) }
    end

    # Calls *listener* after every enqueue that wrote a row, in the
    # enqueuing fiber: the in-process wake-up of workers.
    def on_enqueue(&listener : -> Nil) : Nil
      @listeners_lock.synchronize { @listeners << listener }
    end

    # Wakes the workers of this process.
    def notify : Nil
      @listeners_lock.synchronize { @listeners.dup }.each(&.call)
    end

    # Enqueues *job*, due now, *at* a time, or *in* a span from now.
    # Returns its ID. Inside a write transaction this raises: a Command
    # uses its outbox handle (`Punch::Jobs`), a job enqueues after its
    # write.
    def enqueue(job : J, *, at : Time? = nil, in delay : Time::Span? = nil, unique_key : String? = nil) : Int64? forall J
      {% raise "#{J} is not a job: a job is a struct that includes Punch::Job (lib/punch/docs/jobs.md)." unless J < ::Punch::Job %}
      if Fiber.current.punch_writer?
        raise Error.new("#{J} enqueued directly inside a write transaction. A Command enqueues through its outbox: " \
                        "`jobs : Punch::Jobs(#{J})` in `call` (lib/punch/docs/jobs.md); other code enqueues after the write has committed.")
      end
      # A job with steps keeps its progress under its key, which must never
      # name another job: the row ID can be reused once a job is purged.
      {% if J < ::Punch::Job::Stepped %}
        unique_key ||= "run-#{Random::Secure.hex(16)}"
      {% end %}
      insert(Job::Queue.entry(job, Job::Queue.run_at(Time.utc, at, delay), unique_key: unique_key, traceparent: Trace.current.span_context.try(&.traceparent)))
    end

    # Inserts *entry*. Returns the new job's ID, or `nil` when a job with
    # its unique key exists already (a hand-over or schedule seen twice).
    def insert(entry : Entry) : Int64?
      ids = insert([entry])
      ids.first?
    end

    # Inserts *entries* in one transaction; those whose unique key exists
    # are left out. Returns the IDs of the rows written.
    def insert(entries : Array(Entry)) : Array(Int64)
      return [] of Int64 if entries.empty?

      enqueued_at = Time.utc.to_unix_ms
      ids = @database.write do |db|
        entries.compact_map do |entry|
          db.query_one?(<<-SQL, entry.queue, entry.type, entry.version.to_i64, entry.payload, entry.priority.to_i64,
            INSERT INTO punch_jobs (queue, type, version, payload, state, priority, run_at, attempts, max_attempts,
              unique_key, concurrency_key, concurrency_limit, enqueued_at, traceparent)
            VALUES (?, ?, ?, ?, 'ready', ?, ?, 0, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (unique_key) DO NOTHING
            RETURNING id
            SQL
            entry.run_at.to_unix_ms, entry.max_attempts.to_i64, entry.unique_key, entry.concurrency_key,
            entry.concurrency_limit.try(&.to_i64), enqueued_at, entry.traceparent, name: "Punch::Job::Queue.insert", &.read(Int64))
        end
      end
      notify unless ids.empty?
      ids
    end

    # Claims up to *limit* due jobs of *types* for *process*, most urgent
    # first, skipping paused queues and, when given, queues not in
    # *queues*. *types* maps each type to the newest payload version the
    # binary reads: newer jobs are left for a binary that reads them. Each
    # claim counts an attempt.
    def claim(process : String, limit : Int32, types : Hash(String, Int32), queues : Array(String)? = nil) : Array(Claimed)
      return [] of Claimed if limit < 1 || types.empty?

      at = Time.utc.to_unix_ms
      @database.write do |db|
        candidates = db.query_all(<<-SQL, at, types.to_json, queues ? 1 : 0, Database::Values.new(queues || [] of String), (limit * 4).to_i64, name: "Punch::Job::Queue.candidates") do |row|
          SELECT id, concurrency_key, concurrency_limit FROM punch_jobs
          WHERE state = 'ready' AND run_at <= ?1
            AND version <= (SELECT value FROM json_each(?2) WHERE key = punch_jobs.type)
            AND (?3 = 0 OR queue IN carray(?4))
            AND queue NOT IN (SELECT queue FROM punch_paused_queues)
          ORDER BY priority DESC, run_at, id
          LIMIT ?5
          SQL
          {row.read(Int64), row.read(String?), row.read(Int64?)}
        end
        chosen = [] of Int64
        blocked = [] of Int64
        running = {} of String => Int64
        candidates.each do |id, key, key_limit|
          break if chosen.size >= limit
          if key && key_limit
            count = running[key] ||= db.query_one?("SELECT count(*) FROM punch_jobs WHERE concurrency_key = ? AND state = 'running'",
              key, name: "Punch::Job::Queue.running", &.read(Int64)) || 0_i64
            if count >= key_limit
              blocked << id
              next
            end
            running[key] = count + 1
          end
          chosen << id
        end
        unless blocked.empty?
          db.exec("UPDATE punch_jobs SET state = 'blocked' WHERE id IN carray(?)", Database::Values.new(blocked), name: "Punch::Job::Queue.block")
        end
        next [] of Claimed if chosen.empty?
        claimed = db.query_all(<<-SQL, process, at, Database::Values.new(chosen), name: "Punch::Job::Queue.claim") { |row| Job::Queue.claimed(row) }
          UPDATE punch_jobs SET state = 'running', claimed_by = ?1, claimed_at = ?2, attempts = attempts + 1
          WHERE id IN carray(?3)
          RETURNING id, queue, type, version, payload, attempts, max_attempts, run_at, enqueued_at, unique_key, concurrency_key, traceparent
          SQL
        # RETURNING has no order; keep the urgency order of the candidates.
        claimed.sort_by! { |job| chosen.index!(job.id) }
      end
    end

    # :nodoc:
    def self.claimed(row : Database::Row) : Claimed
      Claimed.new(row.read(Int64), row.read(String), row.read(String), row.read(Int64).to_i32, row.read(String),
        row.read(Int64).to_i32, row.read(Int64).to_i32, Time.unix_ms(row.read(Int64)), Time.unix_ms(row.read(Int64)),
        row.read(String?), row.read(String?), row.read(String?))
    end

    # Records that *job* finished.
    def finish(job : Claimed, process : String) : Outcome
      close(job, process, "done", nil) ? Outcome::Done : Outcome::Lost
    end

    # Records a discarded job with its reason.
    def discard(job : Claimed, process : String, reason : String) : Outcome
      close(job, process, "discarded", reason) ? Outcome::Discarded : Outcome::Lost
    end

    # Records a job that cannot run again.
    def fail(job : Claimed, process : String, error : String) : Outcome
      close(job, process, "failed", error) ? Outcome::Failed : Outcome::Lost
    end

    # Parks a job whose payload this binary cannot read: it waits as
    # `incompatible`, its attempt not counted, until someone retries it with
    # a binary that reads it, or discards it.
    def park(job : Claimed, process : String, error : String) : Outcome
      changed = @database.write do |db|
        changes = db.exec(<<-SQL, Time.utc.to_unix_ms, Job::Queue.cut(error), job.id, process, name: "Punch::Job::Queue.park").changes
          UPDATE punch_jobs SET state = 'incompatible', attempts = max(attempts - 1, 0), finished_at = ?, error = ?,
            claimed_by = NULL, claimed_at = NULL
          WHERE id = ? AND state = 'running' AND claimed_by = ?
          SQL
        unblock(db, job.concurrency_key)
        changes
      end
      changed == 1 ? Outcome::Parked : Outcome::Lost
    end

    # Records a failed attempt: back to `ready` after the backoff (or
    # *after*), or `failed` when it was the last attempt.
    def retry(job : Claimed, process : String, error : String, after : Time::Span? = nil) : Outcome
      if job.attempts >= job.max_attempts
        return close(job, process, "failed", error) ? Outcome::Failed : Outcome::Lost
      end

      run_at = Time.utc + (after || Job::Queue.backoff(job.attempts))
      changed = @database.write do |db|
        changes = db.exec(<<-SQL, run_at.to_unix_ms, Job::Queue.cut(error), job.id, process, name: "Punch::Job::Queue.retry").changes
          UPDATE punch_jobs SET state = 'ready', run_at = ?, error = ?, claimed_by = NULL, claimed_at = NULL
          WHERE id = ? AND state = 'running' AND claimed_by = ?
          SQL
        unblock(db, job.concurrency_key)
        changes
      end
      changed == 1 ? Outcome::Retried : Outcome::Lost
    end

    # Puts a job with steps back as `ready`, due at *run_at*, without
    # counting the attempt: it stopped between steps, its progress saved.
    def pause(job : Claimed, process : String, run_at : Time) : Outcome
      changed = @database.write do |db|
        changes = db.exec(<<-SQL, run_at.to_unix_ms, job.id, process, name: "Punch::Job::Queue.pause").changes
          UPDATE punch_jobs SET state = 'ready', run_at = ?, attempts = max(attempts - 1, 0), claimed_by = NULL, claimed_at = NULL
          WHERE id = ? AND state = 'running' AND claimed_by = ?
          SQL
        unblock(db, job.concurrency_key)
        changes
      end
      notify if changed == 1
      changed == 1 ? Outcome::Paused : Outcome::Lost
    end

    # Hands claimed jobs back without counting the attempt: the process
    # stops before they finished.
    def release(ids : Array(Int64), process : String) : Int64
      return 0_i64 if ids.empty?

      @database.write do |db|
        keys = db.query_all(<<-SQL, Database::Values.new(ids), process, name: "Punch::Job::Queue.release", &.read(String?))
          UPDATE punch_jobs SET state = 'ready', attempts = max(attempts - 1, 0), claimed_by = NULL, claimed_at = NULL
          WHERE id IN carray(?) AND state = 'running' AND claimed_by = ?
          RETURNING concurrency_key
          SQL
        keys.uniq.each { |key| unblock(db, key) }
        keys.size.to_i64
      end
    end

    private def close(job : Claimed, process : String, state : String, error : String?) : Bool
      @database.write do |db|
        changes = db.exec(<<-SQL, state, Time.utc.to_unix_ms, error.try { |text| Job::Queue.cut(text) }, job.id, process, name: "Punch::Job::Queue.close").changes
          UPDATE punch_jobs SET state = ?, finished_at = ?, error = coalesce(?, error), claimed_by = NULL, claimed_at = NULL
          WHERE id = ? AND state = 'running' AND claimed_by = ?
          SQL
        unblock(db, job.concurrency_key)
        changes == 1
      end
    end

    # Moves blocked jobs of *key* back to `ready` while it has free slots.
    private def unblock(db : Writer, key : String?) : Nil
      return unless key
      db.exec(<<-SQL, key, name: "Punch::Job::Queue.unblock")
        UPDATE punch_jobs SET state = 'ready' WHERE id IN (
          SELECT id FROM punch_jobs WHERE concurrency_key = ?1 AND state = 'blocked'
          ORDER BY priority DESC, run_at, id
          LIMIT max(0, coalesce((SELECT concurrency_limit FROM punch_jobs WHERE concurrency_key = ?1 AND state = 'blocked' LIMIT 1), 0)
                     - (SELECT count(*) FROM punch_jobs WHERE concurrency_key = ?1 AND state = 'running'))
        )
        SQL
    end

    # Unblocks every key with free slots: a safety net run with the
    # heartbeat, for keys whose last running job ended in a crash.
    def unblock_all : Int64
      @database.write do |db|
        keys = db.query_all("SELECT DISTINCT concurrency_key FROM punch_jobs WHERE state = 'blocked'", name: "Punch::Job::Queue.blocked_keys", &.read(String))
        keys.each { |key| unblock(db, key) }
        keys.size.to_i64
      end
    end

    # Records that *process* is alive.
    def heartbeat(process : String, kind : String, queues : Array(String)?) : Nil
      at = Time.utc.to_unix_ms
      @database.write do |db|
        db.exec(<<-SQL, process, kind, ::Process.pid.to_i64, System.hostname, queues.try(&.join(",")) || "*", at, at, name: "Punch::Job::Queue.heartbeat")
          INSERT INTO punch_job_processes (id, kind, pid, host, queues, started_at, heartbeat_at) VALUES (?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT (id) DO UPDATE SET heartbeat_at = excluded.heartbeat_at
          SQL
      end
    end

    # Removes *process*, which stopped cleanly.
    def deregister(process : String) : Nil
      @database.write { |db| db.exec("DELETE FROM punch_job_processes WHERE id = ?", process, name: "Punch::Job::Queue.deregister") }
    end

    # Jobs claimed by processes whose heartbeat is older than *stale* (or
    # gone) go back to `ready`, their attempt counted: a job that crashes
    # its process every time ends as `failed`, not in a loop. Returns how
    # many were released.
    def release_orphans(stale : Time::Span) : Int64
      cutoff = (Time.utc - stale).to_unix_ms
      @database.write do |db|
        db.exec("DELETE FROM punch_job_processes WHERE heartbeat_at < ?", cutoff, name: "Punch::Job::Queue.forget_processes")
        orphans = db.query_all(<<-SQL, name: "Punch::Job::Queue.orphans") { |row| {row.read(Int64), row.read(Int64), row.read(Int64), row.read(String?), row.read(String?)} }
          SELECT id, attempts, max_attempts, claimed_by, concurrency_key FROM punch_jobs
          WHERE state = 'running' AND claimed_by NOT IN (SELECT id FROM punch_job_processes)
          SQL
        orphans.each do |id, attempts, max_attempts, claimed_by, _|
          error = "interrupted: process #{claimed_by} stopped while the job ran"
          if attempts >= max_attempts
            db.exec("UPDATE punch_jobs SET state = 'failed', finished_at = ?, error = ?, claimed_by = NULL, claimed_at = NULL WHERE id = ?",
              Time.utc.to_unix_ms, error, id, name: "Punch::Job::Queue.orphan_failed")
          else
            db.exec("UPDATE punch_jobs SET state = 'ready', error = ?, claimed_by = NULL, claimed_at = NULL WHERE id = ?",
              error, id, name: "Punch::Job::Queue.orphan_released")
          end
        end
        orphans.compact_map { |orphan| orphan[4] }.uniq!.each { |key| unblock(db, key) }
        orphans.size.to_i64
      end
    end

    # When the next job of *types* in *queues* is due: `nil` when none is
    # waiting, a time in the past when one is due now.
    def next_due(types : Hash(String, Int32), queues : Array(String)? = nil) : Time?
      @database.read do |db|
        db.query_one?(<<-SQL, types.to_json, queues ? 1 : 0, Database::Values.new(queues || [] of String), name: "Punch::Job::Queue.next_due") { |row| row.read(Int64?).try { |millis| Time.unix_ms(millis) } }
          SELECT min(run_at) FROM punch_jobs
          WHERE state = 'ready' AND version <= (SELECT value FROM json_each(?1) WHERE key = punch_jobs.type)
            AND (?2 = 0 OR queue IN carray(?3))
            AND queue NOT IN (SELECT queue FROM punch_paused_queues)
          SQL
      end
    end

    # Jobs, newest first, filtered by state (`scheduled` too), queue, and
    # type.
    def list(*, state : String? = nil, queue : String? = nil, type : String? = nil, limit : Int32 = 50) : Array(Row)
      at = Time.utc.to_unix_ms
      stored, due = case state
                    when "scheduled" then {"ready", 1_i64}
                    when "ready"     then {"ready", 0_i64}
                    else                  {state, nil}
                    end
      @database.read do |db|
        db.query_all(<<-SQL, stored, due, at, queue, type, limit.to_i64, name: "Punch::Job::Queue.list") { |row| Job::Queue.row(row) }
          SELECT id, queue, type, version, state, priority, run_at, attempts, max_attempts, unique_key, concurrency_key,
            claimed_by, enqueued_at, finished_at, error, payload
          FROM punch_jobs
          WHERE (?1 IS NULL OR state = ?1)
            AND (?2 IS NULL OR (?2 = 1 AND run_at > ?3) OR (?2 = 0 AND run_at <= ?3))
            AND (?4 IS NULL OR queue = ?4) AND (?5 IS NULL OR type = ?5)
          ORDER BY id DESC LIMIT ?6
          SQL
      end
    end

    # One job, or `nil`.
    def find(id : Int64) : Row?
      @database.read do |db|
        db.query_one?(<<-SQL, id, name: "Punch::Job::Queue.find") { |row| Job::Queue.row(row) }
          SELECT id, queue, type, version, state, priority, run_at, attempts, max_attempts, unique_key, concurrency_key,
            claimed_by, enqueued_at, finished_at, error, payload
          FROM punch_jobs WHERE id = ?
          SQL
      end
    end

    # :nodoc:
    def self.row(row : Database::Row) : Row
      Row.new(row.read(Int64), row.read(String), row.read(String), row.read(Int64).to_i32, row.read(String),
        row.read(Int64).to_i32, Time.unix_ms(row.read(Int64)), row.read(Int64).to_i32, row.read(Int64).to_i32,
        row.read(String?), row.read(String?), row.read(String?), Time.unix_ms(row.read(Int64)),
        row.read(Int64?).try { |millis| Time.unix_ms(millis) }, row.read(String?), row.read(String))
    end

    # Failed jobs of one type: how many, the latest one, and its error.
    record FailedGroup, type : String, count : Int64, latest_id : Int64, last_failed : Time?, error : String? do
      include JSON::Serializable
    end

    # Failed jobs grouped by type, the most recently failed type first.
    def failed_groups : Array(FailedGroup)
      @database.read do |db|
        db.query_all(<<-SQL, name: "Punch::Job::Queue.failed_groups") do |row|
          SELECT type, count(*), max(id), max(finished_at),
            (SELECT error FROM punch_jobs latest WHERE latest.state = 'failed' AND latest.type = failed.type ORDER BY id DESC LIMIT 1)
          FROM punch_jobs failed WHERE state = 'failed'
          GROUP BY type ORDER BY max(finished_at) DESC, type
          SQL
          FailedGroup.new(row.read(String), row.read(Int64), row.read(Int64), row.read(Int64?).try { |millis| Time.unix_ms(millis) }, row.read(String?))
        end
      end
    end

    # Makes every failed job of *type* ready again, with fresh attempts.
    # Returns how many.
    def retry_failed(type : String) : Int64
      changed = @database.write do |db|
        db.exec(<<-SQL, Time.utc.to_unix_ms, type, name: "Punch::Job::Queue.retry_failed").changes
          UPDATE punch_jobs SET state = 'ready', run_at = ?, attempts = 0, finished_at = NULL
          WHERE state = 'failed' AND type = ?
          SQL
      end
      notify if changed > 0
      changed
    end

    # Jobs per queue and state; ready jobs not yet due count as
    # `scheduled`.
    def counts : Array(Count)
      at = Time.utc.to_unix_ms
      @database.read do |db|
        db.query_all(<<-SQL, at, name: "Punch::Job::Queue.counts") { |row| Count.new(row.read(String), row.read(String), row.read(Int64)) }
          SELECT queue, CASE WHEN state = 'ready' AND run_at > ? THEN 'scheduled' ELSE state END AS shown, count(*)
          FROM punch_jobs GROUP BY queue, shown ORDER BY queue, shown
          SQL
      end
    end

    # Unfinished jobs (every state but `done` and `discarded`) per type,
    # payload version, and state.
    def version_counts : Array(VersionCount)
      @database.read do |db|
        db.query_all(<<-SQL, name: "Punch::Job::Queue.version_counts") { |row| VersionCount.new(row.read(String), row.read(Int64).to_i32, row.read(String), row.read(Int64)) }
          SELECT type, version, state, count(*) FROM punch_jobs
          WHERE state NOT IN ('done', 'discarded')
          GROUP BY type, version, state ORDER BY type, version, state
          SQL
      end
    end

    # The processes running workers, by their last heartbeat.
    def processes : Array(Process)
      @database.read do |db|
        db.query_all("SELECT id, kind, pid, host, queues, started_at, heartbeat_at FROM punch_job_processes ORDER BY started_at",
          name: "Punch::Job::Queue.processes") do |row|
          Process.new(row.read(String), row.read(String), row.read(Int64), row.read(String), row.read(String),
            Time.unix_ms(row.read(Int64)), Time.unix_ms(row.read(Int64)))
        end
      end
    end

    # Makes a failed, discarded, or incompatible job ready again, with
    # fresh attempts. `false` when there is no such job in these states.
    def retry_job(id : Int64) : Bool
      changed = @database.write do |db|
        db.exec(<<-SQL, Time.utc.to_unix_ms, id, name: "Punch::Job::Queue.retry_job").changes
          UPDATE punch_jobs SET state = 'ready', run_at = ?, attempts = 0, finished_at = NULL
          WHERE id = ? AND state IN ('failed', 'discarded', 'incompatible')
          SQL
      end
      notify if changed == 1
      changed == 1
    end

    # Discards a job that is waiting, failed, or incompatible, with
    # *reason*. A running job cannot be discarded. `false` when there is
    # no such job.
    def discard_job(id : Int64, reason : String = "discarded by hand") : Bool
      @database.write do |db|
        db.exec(<<-SQL, Time.utc.to_unix_ms, reason, id, name: "Punch::Job::Queue.discard_job").changes == 1
          UPDATE punch_jobs SET state = 'discarded', finished_at = ?, error = ?
          WHERE id = ? AND state IN ('ready', 'blocked', 'failed', 'incompatible')
          SQL
      end
    end

    # Stops claiming from *queue* in every process; running jobs finish.
    def pause(queue : String) : Bool
      Job::Queue.check_name(queue)
      @database.write do |db|
        db.exec("INSERT INTO punch_paused_queues (queue, paused_at) VALUES (?, ?) ON CONFLICT (queue) DO NOTHING",
          queue, Time.utc.to_unix_ms, name: "Punch::Job::Queue.pause").changes == 1
      end
    end

    def resume(queue : String) : Bool
      Job::Queue.check_name(queue)
      resumed = @database.write do |db|
        db.exec("DELETE FROM punch_paused_queues WHERE queue = ?", queue, name: "Punch::Job::Queue.resume").changes == 1
      end
      notify if resumed
      resumed
    end

    def paused : Array(String)
      @database.read { |db| db.query_all("SELECT queue FROM punch_paused_queues ORDER BY queue", name: "Punch::Job::Queue.paused", &.read(String)) }
    end

    # Applies a confirmed reconciliation after a restore
    # (`Punch::Backup::Recovery`), in one transaction: discards the jobs
    # *discard* (unfinished, their Command is not in the restored primary),
    # makes *rerun* (finished, their writes may be gone) ready with fresh
    # attempts, and *interrupted* (running at the restore point) ready
    # without counting the attempt. Only jobs still in the state the
    # reconciliation saw change. Processes that beat before *restored_at*
    # stopped before the restore and are removed. Returns how many of each
    # changed.
    def reconcile(discard : Array(Int64), rerun : Array(Int64), interrupted : Array(Int64),
                  restored_at : Time) : {Int64, Int64, Int64}
      at = Time.utc.to_unix_ms
      changed = @database.write do |db|
        discarded = db.exec(<<-SQL, at, Database::Values.new(discard), name: "Punch::Job::Queue.reconcile_discard").changes
          UPDATE punch_jobs SET state = 'discarded', finished_at = ?,
            error = 'discarded after a restore: its Command is not in the restored primary', claimed_by = NULL, claimed_at = NULL
          WHERE id IN carray(?) AND state IN ('ready', 'blocked', 'running', 'failed', 'incompatible')
          SQL
        ran = db.exec(<<-SQL, at, Database::Values.new(rerun), name: "Punch::Job::Queue.reconcile_rerun").changes
          UPDATE punch_jobs SET state = 'ready', run_at = ?, attempts = 0, finished_at = NULL,
            error = 'run again after a restore: its writes may be missing from the restored primary'
          WHERE id IN carray(?) AND state IN ('done', 'discarded')
          SQL
        released = db.exec(<<-SQL, Database::Values.new(interrupted), name: "Punch::Job::Queue.reconcile_interrupted").changes
          UPDATE punch_jobs SET state = 'ready', attempts = max(attempts - 1, 0), claimed_by = NULL, claimed_at = NULL,
            error = 'interrupted by a restore'
          WHERE id IN carray(?) AND state = 'running'
          SQL
        db.exec("DELETE FROM punch_job_processes WHERE heartbeat_at < ?", restored_at.to_unix_ms, name: "Punch::Job::Queue.reconcile_processes")
        {discarded, ran, released}
      end
      notify if changed[1] > 0 || changed[2] > 0
      changed
    end

    # Removes jobs that finished (`done`, `discarded`) before *before*.
    # Failed jobs stay until someone retries or discards them.
    def purge(before : Time) : Int64
      @database.write do |db|
        db.exec("DELETE FROM punch_jobs WHERE state IN ('done', 'discarded') AND finished_at < ?", before.to_unix_ms, name: "Punch::Job::Queue.purge").changes
      end
    end

    # The delay before the attempt after *attempt*: 15 s, tripled each
    # time, at most 6 hours, with ±15 % jitter so failed jobs spread out.
    # Ten attempts span about 17 hours.
    def self.backoff(attempt : Int32) : Time::Span
      base = Math.min(15.0 * 3.0 ** (attempt - 1).clamp(0, 20), 6.0 * 3600)
      (base * Random.rand(0.85..1.15)).seconds
    end

    # When a job enqueued at *now* is due.
    def self.run_at(now : Time, at : Time?, delay : Time::Span?) : Time
      raise ArgumentError.new("enqueue takes at: or in:, not both") if at && delay
      at || (delay ? now + delay : now)
    end

    # *text*, cut to `MAX_ERROR` bytes at a character boundary.
    def self.cut(text : String) : String
      return text if text.bytesize <= MAX_ERROR

      cut = text.byte_slice(0, MAX_ERROR)
      until cut.valid_encoding?
        cut = cut.byte_slice(0, cut.bytesize - 1)
      end
      cut + "…"
    end

    # The error of an exception as stored: class, message, and the first
    # lines of the backtrace.
    def self.describe(ex : Exception) : String
      String.build do |io|
        io << ex.class << ": " << ex.message
        ex.backtrace?.try &.first(20).each { |line| io << "\n  " << line }
      end
    end

    # :nodoc:
    def self.check_name(queue : String) : Nil
      raise ArgumentError.new("queue names are lowercase letters, digits, and _: #{queue.inspect}") unless queue.matches?(/\A[a-z][a-z0-9_]{0,62}\z/)
    end

    private def setup(db : Writer) : Nil
      version = db.query_one?("PRAGMA user_version", &.read(Int64)) || 0_i64
      exists = db.query_one?("SELECT 1 FROM sqlite_schema WHERE name = 'punch_jobs'", &.read(Int64))
      if exists
        return if version == LAYOUT

        raise Error.new("#{@database.path} has queue layout #{version}; this binary needs #{LAYOUT}. Its jobs are kept: run the binary that wrote it until the queue is empty, or move the file aside.")
      end
      TABLES.each { |sql| db.exec(sql) }
      db.exec("PRAGMA user_version = #{LAYOUT}")
    end
  end
end
