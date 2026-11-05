require "digest/sha256"

module Punch
  # What the ops console shows, kept in `ops.db`: errors grouped by
  # fingerprint, job runs, and published events. Fed by `Ops::Sink` from the
  # wide events every request and job emits, the same instrumentation that
  # feeds the trace export, so the two cannot disagree.
  module Ops
    @@store : Store?

    # Makes *store* the one `Ops::Purge` and the console use. `serve` and
    # `jobs` attach `ops.db`; specs attach an in-memory one
    # (`Punch::Spec.ops`).
    def self.attach(store : Store) : Nil
      @@store = store
    end

    def self.detach : Nil
      @@store = nil
    end

    # The attached store, or `nil` when ops recording is off.
    def self.current? : Store?
      @@store
    end

    # How long job runs, error occurrences, and event records are kept,
    # and resolved errors after they were last seen (`PUNCH_OPS_RETENTION_DAYS`).
    class_property retention : Time::Span = 14.days

    # Requests that take at least this long keep their wide event, like a
    # failed one, for the console's slowest requests (`PUNCH_OPS_SLOW_MS`).
    class_property slow : Time::Span = 500.milliseconds

    # Whether the process runs with `PUNCH_ENV=development`, where the ops
    # console's default policy lets any signed-in user in.
    class_property? development : Bool = false

    class Error < Exception
    end

    # One group of exceptions with the same fingerprint.
    record ErrorGroup, id : Int64, fingerprint : String, exception : String, source : String, message : String?,
      backtrace : String?, first_seen : Time, last_seen : Time, occurrences : Int64, resolved_at : Time? do
      include JSON::Serializable

      def resolved? : Bool
        !resolved_at.nil?
      end
    end

    # One time an error group's exception was raised, linked to the stored
    # wide event of the request or job it was raised in.
    record Occurrence, id : Int64, error_id : Int64, at : Time, trace_id : String?, record_id : Int64?, message : String? do
      include JSON::Serializable
    end

    # A stored wide event: a job run, a failed request, a reported error.
    # *fields* is the event as `JSONEvents` writes it.
    record StoredRecord, id : Int64, at : Time, kind : String, name : String, trace_id : String?,
      duration_ms : Float64?, failed : Bool, job_id : Int64?, fields : String do
      include JSON::Serializable
    end

    # A committed domain event.
    record EventRecord, id : Int64, at : Time, event : String, trace_id : String?, source : String do
      include JSON::Serializable
    end

    # The counts on the console's front page.
    record Summary, open_errors : Int64, occurrences_24h : Int64, failed_runs_24h : Int64, runs_24h : Int64 do
      include JSON::Serializable
    end

    # How long one stats bucket is: performance is kept per operation, job,
    # and named query in buckets of this length.
    BUCKET = 10.minutes

    # The start of the bucket *time* falls in, in Unix milliseconds.
    def self.bucket(time : Time) : Int64
      millis = time.to_unix_ms
      millis - millis % BUCKET.total_milliseconds.to_i64
    end

    # The upper bounds of the duration buckets, in milliseconds: those of
    # the metrics (`Metrics::DURATION_BOUNDS`), so the console and an OTLP
    # backend bucket alike. One more bucket counts what is above the last.
    BOUNDS_MS = Metrics::DURATION_BOUNDS.map(&.*(1000))

    # What requests, jobs, or named queries of one name cost while a
    # stats bucket was open, added up as the sink sees them. *kind* is
    # `request`, `job`, or `query`; *name* is the route (`GET /invoices/:id`),
    # `job <Type>`, or the query's name. *wait_ms* is the time writes waited
    # for the writer, *db_ms* the time in SQL, *queries* the statements run,
    # *rows* the rows a query returned or changed, *replays* the answers
    # replayed for an idempotency key.
    # :nodoc:
    class Tally
      property count = 0_i64
      property failed = 0_i64
      property total_ms = 0.0
      property max_ms = 0.0
      property wait_ms = 0.0
      property db_ms = 0.0
      property queries = 0_i64
      property rows = 0_i64
      property replays = 0_i64
      getter buckets = Array(Int64).new(BOUNDS_MS.size + 1, 0_i64)

      # One run lasting *ms*.
      def run(ms : Float64, failed : Bool) : Nil
        @count += 1
        @failed += 1 if failed
        @total_ms += ms
        @max_ms = ms if ms > @max_ms
        @buckets[Trace::QueryTally.bucket(ms)] += 1
      end

      # A named query's runs in one trace.
      def add(query : Trace::QueryTally) : Nil
        @count += query.count
        @failed += query.failed
        @total_ms += query.total_ms
        @max_ms = query.max_ms if query.max_ms > @max_ms
        @rows += query.rows
        query.buckets.each_with_index { |runs, index| @buckets[index] += runs }
      end
    end

    # Tallies by kind, name, and bucket start.
    # :nodoc:
    alias Tallies = Hash({String, String, Int64}, Tally)

    # What requests, jobs, or queries of one name cost over a window, as
    # the console shows them.
    record Stats, kind : String, name : String, count : Int64, failed : Int64, total_ms : Float64, max_ms : Float64,
      wait_ms : Float64, db_ms : Float64, queries : Int64, rows : Int64, replays : Int64, buckets : Array(Int64),
      bucket : Time? = nil do
      include JSON::Serializable

      def average_ms : Float64
        count > 0 ? total_ms / count : 0.0
      end

      # The duration *quantile* (0.95) of the runs stayed within: the upper
      # bound of the bucket it falls in, at most the longest run. `nil`
      # without runs.
      def percentile(quantile : Float64) : Float64?
        return if count == 0

        wanted = (quantile * count).ceil.to_i64.clamp(1_i64, count)
        seen = 0_i64
        buckets.each_with_index do |runs, index|
          seen += runs
          return Math.min(BOUNDS_MS[index]? || max_ms, max_ms) if seen >= wanted
        end
        max_ms
      end
    end

    # What the sink stores for one wide event: the event itself when
    # *keep*, its exceptions, and the domain events it committed. Built
    # from the span, so the store never sees a span.
    # :nodoc:
    record Capture, at : Time, kind : String, name : String, trace_id : String?, duration_ms : Float64?,
      failed : Bool, job_id : Int64?, fields : String, keep : Bool, raised : Array(RaisedError), events : Array(String)

    # One exception of a capture, fingerprinted.
    # :nodoc:
    record RaisedError, fingerprint : String, exception : String, source : String, message : String?, backtrace : String?

    # `ops.db`: Punch's own file, like `queue.db`, outside the app's
    # migrations. It holds history people want after losing the box, so it
    # is replicated, and a file of another layout is refused, never
    # recreated.
    class Store
      LAYOUT = 3

      TABLES = {
        <<-SQL,
          CREATE TABLE punch_ops_errors (
            id          INTEGER PRIMARY KEY,
            fingerprint TEXT    NOT NULL UNIQUE,
            exception   TEXT    NOT NULL,
            source      TEXT    NOT NULL,
            message     TEXT,
            backtrace   TEXT,
            first_seen  INTEGER NOT NULL,
            last_seen   INTEGER NOT NULL,
            occurrences INTEGER NOT NULL,
            resolved_at INTEGER,
            opened_at   INTEGER NOT NULL DEFAULT 0,
            notified_at INTEGER
          ) STRICT
          SQL
        "CREATE INDEX punch_ops_errors_by_last_seen ON punch_ops_errors (last_seen)",
        <<-SQL,
          CREATE TABLE punch_ops_records (
            id          INTEGER PRIMARY KEY,
            at          INTEGER NOT NULL,
            kind        TEXT    NOT NULL,
            name        TEXT    NOT NULL,
            trace_id    TEXT,
            duration_ms REAL,
            failed      INTEGER NOT NULL,
            job_id      INTEGER,
            fields      TEXT    NOT NULL
          ) STRICT
          SQL
        "CREATE INDEX punch_ops_records_by_time ON punch_ops_records (at)",
        "CREATE INDEX punch_ops_records_by_job ON punch_ops_records (job_id, at) WHERE job_id IS NOT NULL",
        "CREATE INDEX punch_ops_records_by_kind ON punch_ops_records (kind, at)",
        <<-SQL,
          CREATE TABLE punch_ops_occurrences (
            id        INTEGER PRIMARY KEY,
            error_id  INTEGER NOT NULL REFERENCES punch_ops_errors (id) ON DELETE CASCADE,
            at        INTEGER NOT NULL,
            trace_id  TEXT,
            record_id INTEGER REFERENCES punch_ops_records (id) ON DELETE SET NULL,
            message   TEXT
          ) STRICT
          SQL
        "CREATE INDEX punch_ops_occurrences_by_error ON punch_ops_occurrences (error_id, at)",
        "CREATE INDEX punch_ops_occurrences_by_time ON punch_ops_occurrences (at)",
        "CREATE INDEX punch_ops_occurrences_by_record ON punch_ops_occurrences (record_id) WHERE record_id IS NOT NULL",
        <<-SQL,
          CREATE TABLE punch_ops_events (
            id       INTEGER PRIMARY KEY,
            at       INTEGER NOT NULL,
            event    TEXT    NOT NULL,
            trace_id TEXT,
            source   TEXT    NOT NULL
          ) STRICT
          SQL
        "CREATE INDEX punch_ops_events_by_time ON punch_ops_events (at)",
        "CREATE INDEX punch_ops_events_by_event ON punch_ops_events (event, at)",
      } + STATS_TABLES + NOTICE_TABLES

      # Added in layout 2: performance per request route, job type, and
      # named query, in buckets of `BUCKET`. A file of layout 1 gets them
      # when opened; its history stays.
      STATS_TABLES = {
        <<-SQL,
          CREATE TABLE punch_ops_stats (
            kind     TEXT    NOT NULL,
            name     TEXT    NOT NULL,
            bucket   INTEGER NOT NULL,
            count    INTEGER NOT NULL,
            failed   INTEGER NOT NULL,
            total_ms REAL    NOT NULL,
            max_ms   REAL    NOT NULL,
            wait_ms  REAL    NOT NULL,
            db_ms    REAL    NOT NULL,
            queries  INTEGER NOT NULL,
            rows     INTEGER NOT NULL,
            replays  INTEGER NOT NULL,
            b0 INTEGER NOT NULL, b1 INTEGER NOT NULL, b2 INTEGER NOT NULL, b3 INTEGER NOT NULL, b4 INTEGER NOT NULL,
            b5 INTEGER NOT NULL, b6 INTEGER NOT NULL, b7 INTEGER NOT NULL, b8 INTEGER NOT NULL, b9 INTEGER NOT NULL,
            b10 INTEGER NOT NULL, b11 INTEGER NOT NULL, b12 INTEGER NOT NULL, b13 INTEGER NOT NULL, b14 INTEGER NOT NULL,
            PRIMARY KEY (kind, name, bucket)
          ) STRICT, WITHOUT ROWID
          SQL
        "CREATE INDEX punch_ops_stats_by_bucket ON punch_ops_stats (bucket)",
        "CREATE INDEX punch_ops_records_by_duration ON punch_ops_records (kind, duration_ms) WHERE duration_ms IS NOT NULL",
      }

      # Added in layout 3, for `Ops::Notify`: when an error group opened, or
      # opened again by recurring after it was resolved, and up to which
      # opening it was notified; the notices of ongoing job failures and
      # stale backups. A file of layout 2 gets them when opened, its groups
      # counted as notified, so nothing already there is announced.
      NOTICE_TABLES = {
        <<-SQL,
          CREATE TABLE punch_ops_notices (
            key TEXT    NOT NULL PRIMARY KEY,
            at  INTEGER NOT NULL
          ) STRICT, WITHOUT ROWID
          SQL
      }

      NOTICE_UPGRADE = {
        "ALTER TABLE punch_ops_errors ADD COLUMN opened_at INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE punch_ops_errors ADD COLUMN notified_at INTEGER",
        "UPDATE punch_ops_errors SET opened_at = first_seen, notified_at = first_seen",
      } + NOTICE_TABLES

      STATS_SUMS = "sum(count), sum(failed), sum(total_ms), max(max_ms), sum(wait_ms), sum(db_ms), sum(queries), sum(rows), sum(replays), " \
                   "sum(b0), sum(b1), sum(b2), sum(b3), sum(b4), sum(b5), sum(b6), sum(b7), sum(b8), sum(b9), sum(b10), sum(b11), sum(b12), sum(b13), sum(b14)"

      # Stored messages and backtraces are cut to these many bytes.
      MAX_MESSAGE   =  2048
      MAX_BACKTRACE = 16384

      getter database : Database

      def initialize(@database : Database)
        @database.write { |db| setup(db) }
      end

      # Stores a batch of captures in one transaction.
      def store(captures : Array(Capture)) : Nil
        return if captures.empty?

        @database.write do |db|
          captures.each { |capture| store(db, capture) }
        end
      end

      private def store(db : Writer, capture : Capture) : Nil
        at = capture.at.to_unix_ms
        record_id = if capture.keep
                      db.exec(<<-SQL, at, capture.kind, capture.name, capture.trace_id, capture.duration_ms, capture.failed ? 1_i64 : 0_i64, capture.job_id, capture.fields, name: "Punch::Ops.record").last_insert_id
                        INSERT INTO punch_ops_records (at, kind, name, trace_id, duration_ms, failed, job_id, fields)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        SQL
                    end
        capture.raised.each do |raised|
          error_id = db.query_one?(<<-SQL, raised.fingerprint, raised.exception, raised.source, raised.message, raised.backtrace, at, at, name: "Punch::Ops.error", &.read(Int64)) || raise Error.new("error upsert returned no row")
            INSERT INTO punch_ops_errors (fingerprint, exception, source, message, backtrace, first_seen, last_seen, occurrences, opened_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 1, ?6)
            ON CONFLICT (fingerprint) DO UPDATE SET
              message = excluded.message, backtrace = excluded.backtrace,
              last_seen = max(last_seen, excluded.last_seen), occurrences = occurrences + 1, resolved_at = NULL,
              opened_at = CASE WHEN resolved_at IS NULL THEN opened_at ELSE max(excluded.last_seen, resolved_at + 1) END
            RETURNING id
            SQL
          db.exec("INSERT INTO punch_ops_occurrences (error_id, at, trace_id, record_id, message) VALUES (?, ?, ?, ?, ?)",
            error_id, at, capture.trace_id, record_id, raised.message, name: "Punch::Ops.occurrence")
        end
        capture.events.each do |event|
          db.exec("INSERT INTO punch_ops_events (at, event, trace_id, source) VALUES (?, ?, ?, ?)",
            at, event, capture.trace_id, capture.name, name: "Punch::Ops.event")
        end
      end

      # Adds *tallies* to the stats, in one transaction.
      def store(tallies : Tallies) : Nil
        return if tallies.empty?

        @database.write do |db|
          tallies.each do |(kind, name, bucket), tally|
            b = tally.buckets
            db.exec(<<-SQL, kind, name, bucket, tally.count, tally.failed, tally.total_ms, tally.max_ms, tally.wait_ms, tally.db_ms,
              INSERT INTO punch_ops_stats (kind, name, bucket, count, failed, total_ms, max_ms, wait_ms, db_ms, queries, rows, replays,
                b0, b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11, b12, b13, b14)
              VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
              ON CONFLICT (kind, name, bucket) DO UPDATE SET
                count = count + excluded.count, failed = failed + excluded.failed, total_ms = total_ms + excluded.total_ms,
                max_ms = max(max_ms, excluded.max_ms), wait_ms = wait_ms + excluded.wait_ms, db_ms = db_ms + excluded.db_ms,
                queries = queries + excluded.queries, rows = rows + excluded.rows, replays = replays + excluded.replays,
                b0 = b0 + excluded.b0, b1 = b1 + excluded.b1, b2 = b2 + excluded.b2, b3 = b3 + excluded.b3, b4 = b4 + excluded.b4,
                b5 = b5 + excluded.b5, b6 = b6 + excluded.b6, b7 = b7 + excluded.b7, b8 = b8 + excluded.b8, b9 = b9 + excluded.b9,
                b10 = b10 + excluded.b10, b11 = b11 + excluded.b11, b12 = b12 + excluded.b12, b13 = b13 + excluded.b13,
                b14 = b14 + excluded.b14
              SQL
              tally.queries, tally.rows, tally.replays, b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11],
              b[12], b[13], b[14], name: "Punch::Ops.stats_add")
          end
        end
      end

      # Requests, jobs, or named queries (*kind*) since *since*, one row per
      # name, the most time spent first.
      def stats(kind : String, *, since : Time, limit : Int32 = 200) : Array(Stats)
        @database.read do |db|
          db.query_all(<<-SQL, kind, Ops.bucket(since), limit.to_i64, name: "Punch::Ops.stats") { |row| Store.stats(row, kind) }
            SELECT name, #{STATS_SUMS} FROM punch_ops_stats
            WHERE kind = ?1 AND bucket >= ?2
            GROUP BY name ORDER BY sum(total_ms) DESC, name LIMIT ?3
            SQL
        end
      end

      # One name's stats per bucket since *since*, oldest first.
      def series(kind : String, name : String, *, since : Time) : Array(Stats)
        @database.read do |db|
          db.query_all(<<-SQL, kind, name, Ops.bucket(since), name: "Punch::Ops.series") do |row|
            SELECT name, #{STATS_SUMS}, bucket FROM punch_ops_stats
            WHERE kind = ?1 AND name = ?2 AND bucket >= ?3
            GROUP BY bucket ORDER BY bucket
            SQL
            stats = Store.stats(row, kind)
            stats.copy_with(bucket: Time.unix_ms(row.read(Int64)))
          end
        end
      end

      # The slowest stored requests since *since*: failed ones, and those
      # kept for taking longer than `Ops.slow`.
      def slowest(*, since : Time, limit : Int32 = 20) : Array(StoredRecord)
        @database.read do |db|
          db.query_all(<<-SQL, since.to_unix_ms, limit.to_i64, name: "Punch::Ops.slowest") { |row| Store.stored_record(row) }
            SELECT #{RECORD_COLUMNS} FROM punch_ops_records
            WHERE kind = 'request' AND duration_ms IS NOT NULL AND at >= ?1
            ORDER BY duration_ms DESC LIMIT ?2
            SQL
        end
      end

      # Committed events since *since*, per type: how many, and when the
      # last one was.
      def event_counts(*, since : Time) : Array({String, Int64, Time})
        @database.read do |db|
          db.query_all(<<-SQL, since.to_unix_ms, name: "Punch::Ops.event_counts") { |row| {row.read(String), row.read(Int64), Time.unix_ms(row.read(Int64))} }
            SELECT event, count(*), max(at) FROM punch_ops_events WHERE at >= ? GROUP BY event ORDER BY count(*) DESC, event
            SQL
        end
      end

      # Error groups, most recently seen first: open ones, resolved ones,
      # or all.
      def errors(*, resolved : Bool? = false, limit : Int32 = 50) : Array(ErrorGroup)
        flag = resolved.nil? ? nil : (resolved ? 1_i64 : 0_i64)
        @database.read do |db|
          db.query_all(<<-SQL, flag, limit.to_i64, name: "Punch::Ops.errors") { |row| Store.error_group(row) }
            SELECT #{ERROR_COLUMNS} FROM punch_ops_errors
            WHERE ?1 IS NULL OR (resolved_at IS NOT NULL) = ?1
            ORDER BY last_seen DESC, id DESC LIMIT ?2
            SQL
        end
      end

      # One error group, or `nil`.
      def error(id : Int64) : ErrorGroup?
        @database.read do |db|
          db.query_one?("SELECT #{ERROR_COLUMNS} FROM punch_ops_errors WHERE id = ?", id, name: "Punch::Ops.find_error") { |row| Store.error_group(row) }
        end
      end

      # The latest occurrences of an error group, newest first.
      def occurrences(error_id : Int64, *, limit : Int32 = 20) : Array(Occurrence)
        @database.read do |db|
          db.query_all(<<-SQL, error_id, limit.to_i64, name: "Punch::Ops.occurrences") do |row|
            SELECT id, error_id, at, trace_id, record_id, message FROM punch_ops_occurrences
            WHERE error_id = ? ORDER BY at DESC, id DESC LIMIT ?
            SQL
            Occurrence.new(row.read(Int64), row.read(Int64), Time.unix_ms(row.read(Int64)), row.read(String?), row.read(Int64?), row.read(String?))
          end
        end
      end

      # One stored wide event, or `nil`.
      def record(id : Int64) : StoredRecord?
        @database.read do |db|
          db.query_one?("SELECT #{RECORD_COLUMNS} FROM punch_ops_records WHERE id = ?", id, name: "Punch::Ops.find_record") { |row| Store.stored_record(row) }
        end
      end

      # Stored wide events, newest first, of one *kind* (`request`, `job`,
      # `other`), one *job_id*, failed ones only, or all.
      def records(*, kind : String? = nil, job_id : Int64? = nil, failed : Bool = false, limit : Int32 = 50) : Array(StoredRecord)
        @database.read do |db|
          db.query_all(<<-SQL, kind, job_id, failed ? 1_i64 : 0_i64, limit.to_i64, name: "Punch::Ops.records") { |row| Store.stored_record(row) }
            SELECT #{RECORD_COLUMNS} FROM punch_ops_records
            WHERE (?1 IS NULL OR kind = ?1) AND (?2 IS NULL OR job_id = ?2) AND (?3 = 0 OR failed = 1)
            ORDER BY at DESC, id DESC LIMIT ?4
            SQL
        end
      end

      # Committed domain events, newest first, of one type or all.
      def events(*, event : String? = nil, limit : Int32 = 50) : Array(EventRecord)
        @database.read do |db|
          db.query_all(<<-SQL, event, limit.to_i64, name: "Punch::Ops.events") do |row|
            SELECT id, at, event, trace_id, source FROM punch_ops_events
            WHERE ?1 IS NULL OR event = ?1 ORDER BY at DESC, id DESC LIMIT ?2
            SQL
            EventRecord.new(row.read(Int64), Time.unix_ms(row.read(Int64)), row.read(String), row.read(String?), row.read(String))
          end
        end
      end

      # Open errors, and what happened in the last 24 hours.
      def summary : Summary
        since = (Time.utc - 24.hours).to_unix_ms
        @database.read do |db|
          db.query_one?(<<-SQL, since, name: "Punch::Ops.summary") { |row| Summary.new(row.read(Int64), row.read(Int64), row.read(Int64), row.read(Int64)) } || raise Error.new("summary returned no row")
            SELECT
              (SELECT count(*) FROM punch_ops_errors WHERE resolved_at IS NULL),
              (SELECT count(*) FROM punch_ops_occurrences WHERE at >= ?1),
              (SELECT count(*) FROM punch_ops_records WHERE kind = 'job' AND failed = 1 AND at >= ?1),
              (SELECT count(*) FROM punch_ops_records WHERE kind = 'job' AND at >= ?1)
            SQL
        end
      end

      # Marks an open error group resolved. A new occurrence opens it again.
      # `false` when there is no such open group.
      def resolve(id : Int64) : Bool
        @database.write do |db|
          db.exec("UPDATE punch_ops_errors SET resolved_at = ? WHERE id = ? AND resolved_at IS NULL", Time.utc.to_unix_ms, id, name: "Punch::Ops.resolve").changes == 1
        end
      end

      # Opens a resolved error group again. `false` when there is no such
      # resolved group.
      def reopen(id : Int64) : Bool
        @database.write do |db|
          db.exec("UPDATE punch_ops_errors SET resolved_at = NULL WHERE id = ? AND resolved_at IS NOT NULL", id, name: "Punch::Ops.reopen").changes == 1
        end
      end

      # An error group that opened, or opened again, since it was last
      # notified; *opened_at* is that opening, in Unix milliseconds.
      record Unnotified, group : ErrorGroup, opened_at : Int64 do
        # Whether the group was resolved before and recurred.
        def reopened? : Bool
          opened_at > group.first_seen.to_unix_ms
        end
      end

      # Open error groups not notified since they opened (`Ops::Notify`),
      # the earliest opened first.
      def unnotified(*, limit : Int32 = 20) : Array(Unnotified)
        @database.read do |db|
          db.query_all(<<-SQL, limit.to_i64, name: "Punch::Ops.unnotified") { |row| Unnotified.new(Store.error_group(row), row.read(Int64)) }
            SELECT #{ERROR_COLUMNS}, opened_at FROM punch_ops_errors
            WHERE resolved_at IS NULL AND (notified_at IS NULL OR notified_at < opened_at)
            ORDER BY opened_at, id LIMIT ?
            SQL
        end
      end

      # Marks each group notified up to the opening it was notified for.
      # A later opening is notified again.
      def notified(groups : Array(Unnotified)) : Nil
        return if groups.empty?

        @database.write do |db|
          groups.each do |unnotified|
            db.exec("UPDATE punch_ops_errors SET notified_at = ? WHERE id = ?", unnotified.opened_at, unnotified.group.id,
              name: "Punch::Ops.notified")
          end
        end
      end

      # The keys of the notices kept, starting with *prefix*: something
      # announced that is still going on (failing jobs of a type, a
      # stale backup).
      def notices(prefix : String) : Array(String)
        @database.read do |db|
          db.query_all("SELECT key FROM punch_ops_notices WHERE substr(key, 1, length(?1)) = ?1 ORDER BY key", prefix,
            name: "Punch::Ops.notices", &.read(String))
        end
      end

      # Keeps the notices *added* and removes those *ended*, in one
      # transaction.
      def notices(*, added : Array(String), ended : Array(String)) : Nil
        return if added.empty? && ended.empty?

        at = Time.utc.to_unix_ms
        @database.write do |db|
          added.each do |key|
            db.exec("INSERT INTO punch_ops_notices (key, at) VALUES (?, ?) ON CONFLICT (key) DO NOTHING", key, at, name: "Punch::Ops.notice")
          end
          ended.each { |key| db.exec("DELETE FROM punch_ops_notices WHERE key = ?", key, name: "Punch::Ops.notice_ended") }
        end
      end

      # Removes job runs, occurrences, and event records from before
      # *before*, and resolved error groups last seen before it. Open
      # groups stay, with their counts. Returns how many rows went.
      def purge(before : Time) : Int64
        cutoff = before.to_unix_ms
        @database.write do |db|
          removed = db.exec("DELETE FROM punch_ops_errors WHERE resolved_at IS NOT NULL AND last_seen < ?", cutoff, name: "Punch::Ops.purge_errors").changes
          removed += db.exec("DELETE FROM punch_ops_occurrences WHERE at < ?", cutoff, name: "Punch::Ops.purge_occurrences").changes
          removed += db.exec("DELETE FROM punch_ops_records WHERE at < ?", cutoff, name: "Punch::Ops.purge_records").changes
          removed += db.exec("DELETE FROM punch_ops_stats WHERE bucket < ?", Ops.bucket(before), name: "Punch::Ops.purge_stats").changes
          removed + db.exec("DELETE FROM punch_ops_events WHERE at < ?", cutoff, name: "Punch::Ops.purge_events").changes
        end
      end

      ERROR_COLUMNS  = "id, fingerprint, exception, source, message, backtrace, first_seen, last_seen, occurrences, resolved_at"
      RECORD_COLUMNS = "id, at, kind, name, trace_id, duration_ms, failed, job_id, fields"

      # :nodoc:
      def self.error_group(row : Database::Row) : ErrorGroup
        ErrorGroup.new(row.read(Int64), row.read(String), row.read(String), row.read(String), row.read(String?), row.read(String?),
          Time.unix_ms(row.read(Int64)), Time.unix_ms(row.read(Int64)), row.read(Int64), row.read(Int64?).try { |millis| Time.unix_ms(millis) })
      end

      # :nodoc:
      def self.stats(row : Database::Row, kind : String) : Stats
        Stats.new(kind, row.read(String), row.read(Int64), row.read(Int64), row.read(Float64), row.read(Float64), row.read(Float64),
          row.read(Float64), row.read(Int64), row.read(Int64), row.read(Int64), Array(Int64).new(BOUNDS_MS.size + 1) { row.read(Int64) })
      end

      # :nodoc:
      def self.stored_record(row : Database::Row) : StoredRecord
        StoredRecord.new(row.read(Int64), Time.unix_ms(row.read(Int64)), row.read(String), row.read(String), row.read(String?),
          row.read(Float64?), row.read(Int64) == 1, row.read(Int64?), row.read(String))
      end

      private def setup(db : Writer) : Nil
        version = db.query_one?("PRAGMA user_version", &.read(Int64)) || 0_i64
        exists = db.query_one?("SELECT 1 FROM sqlite_schema WHERE name = 'punch_ops_errors'", &.read(Int64))
        if exists
          return if version == LAYOUT

          if version.in?(1, 2)
            # Layouts 2 and 3 only add: the history stays.
            STATS_TABLES.each { |sql| db.exec(sql) } if version == 1
            NOTICE_UPGRADE.each { |sql| db.exec(sql) }
            db.exec("PRAGMA user_version = #{LAYOUT}")
            return
          end
          raise Error.new("#{@database.path} has ops layout #{version}; this binary needs #{LAYOUT}. Its history is kept: move the file aside to start a new one.")
        end
        TABLES.each { |sql| db.exec(sql) }
        db.exec("PRAGMA user_version = #{LAYOUT}")
      end
    end

    # The fingerprint of an exception: its class, where it was handled
    # (*source*: the route, job, or subscriber), and the files of the top
    # frames of its backtrace, without line numbers, so a deploy that moves
    # code keeps the group. Method names are left out: the symbolizer
    # names frames of macro-generated code differently from one build to
    # the next (an operation's `call` showed as `path`). The message is
    # left out too: it often holds values.
    def self.fingerprint(exception : Exception, source : String) : String
      digest = Digest::SHA256.new
      digest << exception.class.name << "\n" << source
      frames(exception).each { |frame| digest << "\n" << frame }
      digest.hexfinal[0, 32]
    end

    # The files of the top five frames of *exception*'s backtrace that are
    # not raising machinery.
    # :nodoc:
    def self.frames(exception : Exception) : Array(String)
      frames = [] of String
      exception.backtrace?.try &.each do |line|
        if match = line.match(/\A(.*?):\d+(?::\d+)? in '(.*)'\z/)
          method = match[2]
          next if method.starts_with?("raise") || method.starts_with?("*raise") || method.starts_with?("__crystal")
          frames << File.basename(match[1])
        else
          frames << line.gsub(/0x[0-9a-f]+/, "")
        end
        break if frames.size == 5
      end
      frames
    end

    # :nodoc:
    def self.cut(text : String?, max : Int32) : String?
      return text if text.nil? || text.bytesize <= max

      text.byte_slice(0, max).scrub
    end
  end
end
