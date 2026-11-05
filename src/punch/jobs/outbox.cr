module Punch
  # The jobs a Command may enqueue, asked for in its `call`:
  # `jobs : Punch::Jobs(Remind | Export)`. Each enqueue is written to the
  # outbox in `primary.db`, in the Command's transaction: the job exists if
  # and only if the Command's writes commit. Enqueuing a job outside the
  # type does not compile.
  struct Jobs(T)
    private def initialize(@writer : Writer)
    end

    # The handle for one write transaction. Only the router, which reads
    # the type from `call`, and `Punch::Spec.jobs` make one.
    # :nodoc:
    def self.for_transaction(writer : Writer) : self
      new(writer)
    end

    # Enqueues *job* through the outbox, due now, *at* a time, or *in* a
    # span from now. It reaches `queue.db` once the transaction commits. A
    # job the handle's type does not list matches no overload, which the
    # compiler reports where it is enqueued (add the job to the type in
    # `call`, docs/jobs.md).
    def enqueue(job : T, *, at : Time? = nil, in delay : Time::Span? = nil) : Nil
      run_at = Job::Queue.run_at(Time.utc, at, delay)
      Job::Outbox.add(@writer, Job::Queue.entry(job, run_at, traceparent: Trace.current.span_context.try(&.traceparent)))
    end
  end

  # The outbox: jobs written to `primary.db` in a Command's transaction, by
  # `Punch::Jobs#enqueue` and by deferred subscribers, and handed over to
  # `queue.db` once committed.
  #
  # Hand-over is idempotent: every entry has a random key that becomes the
  # job's unique key, so an entry handed over twice (a crash between the
  # insert and the mark, two processes, a restore) makes one job. Entries
  # are kept for the retention window after hand-over, for the
  # reconciliation after a restore.
  module Job::Outbox
    Log = ::Log.for("punch.outbox")

    # The table lives in the app's migrations, like the auth tables; its
    # columns are Punch's, checked when the server starts.
    COLUMNS = {
      "id" => "INTEGER", "key" => "TEXT", "queue" => "TEXT", "type" => "TEXT", "version" => "INTEGER",
      "payload" => "TEXT", "priority" => "INTEGER", "run_at" => "INTEGER", "max_attempts" => "INTEGER",
      "concurrency_key" => "TEXT", "concurrency_limit" => "INTEGER", "traceparent" => "TEXT",
      "created_at" => "INTEGER", "handed_over_at" => "INTEGER",
    }

    # The table as a migration: `punch db:migration --punch outbox` writes it.
    def self.sql : String
      <<-SQL
        -- The outbox: jobs written in a Command's transaction, handed over
        -- to queue.db after the commit (lib/punch/docs/jobs.md). The columns are Punch's.
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

        SQL
    end

    # Whether this binary enqueues through an outbox: some Command takes
    # `Punch::Jobs`, or some subscriber is deferred.
    def self.used? : Bool
      {% begin %}
        {% operations = ::Punch::Operation.all_subclasses.reject(&.abstract?).select(&.has_constant?("PunchCallExtras")) %}
        {% enqueuers = operations.select { |operation| parse_type("::#{operation}::PunchCallExtras").resolve.type_vars.any? { |type| type.name(generic_args: false) == "Punch::Jobs" } } %}
        {% deferred = ::Punch::Subscriber.includers.select { |subscriber| (delivery = subscriber.annotation(::Punch::Subscriber::Delivery)) && delivery[0] == :deferred } %}
        {{ !enqueuers.empty? || !deferred.empty? }}
      {% end %}
    end

    # What is missing or of another type, one line each; empty when the
    # table is as Punch needs it.
    def self.problems(database : Database) : Array(String)
      found = database.read do |db|
        db.query_all("SELECT name, type FROM pragma_table_info('punch_outbox')", name: "Punch::Job::Outbox.columns") do |row|
          {row.read(String), row.read(String).upcase}
        end.to_h
      end
      return ["table punch_outbox is missing; add it with a migration (lib/punch/docs/jobs.md)"] if found.empty?

      COLUMNS.compact_map do |column, type|
        if actual = found[column]?
          "punch_outbox.#{column} is #{actual}, Punch needs #{type}" unless actual == type
        else
          "punch_outbox.#{column} is missing (lib/punch/docs/jobs.md)"
        end
      end
    end

    # Whether *database* has the table, for spec helpers that hand over
    # only when there is one.
    def self.present?(database : Database) : Bool
      database.read { |db| !!db.query_one?("SELECT 1 FROM sqlite_schema WHERE name = 'punch_outbox'", &.read(Int64)) }
    end

    @@wake = [] of Proc(Nil)
    @@wake_lock = Mutex.new

    # Calls *listener* after every commit that wrote outbox entries, in
    # the committing fiber: the relay's wake-up.
    def self.on_commit(&listener : -> Nil) : Nil
      @@wake_lock.synchronize { @@wake << listener }
    end

    # :nodoc:
    def self.committed : Nil
      @@wake_lock.synchronize { @@wake.dup }.each(&.call)
    end

    WAKE = -> { Job::Outbox.committed; nil }

    # Writes *entry* to the outbox in *writer*'s transaction.
    def self.add(writer : Writer, entry : Job::Queue::Entry) : Nil
      writer.exec(<<-SQL, Random::Secure.hex(16), entry.queue, entry.type, entry.version.to_i64, entry.payload, entry.priority.to_i64,
        INSERT INTO punch_outbox (key, queue, type, version, payload, priority, run_at, max_attempts,
          concurrency_key, concurrency_limit, traceparent, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        SQL
        entry.run_at.to_unix_ms, entry.max_attempts.to_i64, entry.concurrency_key, entry.concurrency_limit.try(&.to_i64),
        entry.traceparent, Time.utc.to_unix_ms, name: "Punch::Job::Outbox.add")
      lease = writer.lease
      lease.after_commit(WAKE) unless lease.committed.try(&.includes?(WAKE))
      wide = Trace.event
      wide.add("punch.jobs.enqueued", 1) if wide.recording?
    end

    # Removes entries handed over before *before*.
    def self.purge(db : Writer, before : Time) : Int64
      db.exec("DELETE FROM punch_outbox WHERE handed_over_at < ?", before.to_unix_ms, name: "Punch::Job::Outbox.purge").changes
    end

    # Marks the entries *ids* as not handed over, so the relay hands them
    # over again: a restore brought back a queue without their jobs. The
    # queue ignores keys it has. Returns how many.
    def self.hand_over_again(db : Writer, ids : Array(Int64)) : Int64
      db.exec("UPDATE punch_outbox SET handed_over_at = NULL WHERE id IN carray(?) AND handed_over_at IS NOT NULL",
        Database::Values.new(ids), name: "Punch::Job::Outbox.hand_over_again").changes
    end

    # Entries not handed over yet per type and payload version, for
    # `jobs:versions`.
    def self.pending_versions(db : Reader) : Array({String, Int32, Int64})
      db.query_all("SELECT type, version, count(*) FROM punch_outbox WHERE handed_over_at IS NULL GROUP BY type, version ORDER BY type, version",
        name: "Punch::Job::Outbox.pending_versions") { |row| {row.read(String), row.read(Int64).to_i32, row.read(Int64)} }
    end

    # Entries not handed over yet and when the oldest was written, or `nil`
    # when *db* has no outbox: the ops console's depth and lag.
    def self.backlog(db : Reader) : {Int64, Time?}?
      return unless db.query_one?("SELECT 1 FROM sqlite_schema WHERE name = 'punch_outbox'", name: "Punch::Job::Outbox.exists", &.read(Int64))

      db.query_one?("SELECT count(*), min(created_at) FROM punch_outbox WHERE handed_over_at IS NULL", name: "Punch::Job::Outbox.backlog") do |row|
        {row.read(Int64), row.read(Int64?).try { |millis| Time.unix_ms(millis) }}
      end
    end

    # Entries not handed over yet, for `jobs:stats`.
    def self.pending(db : Reader) : Int64
      db.query_one?("SELECT count(*) FROM punch_outbox WHERE handed_over_at IS NULL", name: "Punch::Job::Outbox.pending", &.read(Int64)) || 0_i64
    end

    # Moves committed outbox entries into `queue.db`: woken by every commit
    # that wrote some in this process, polling for those of other
    # processes and for any left by a crash.
    class Relay
      # Where a spec makes the hand-over stop, as a crash would: after
      # reading the entries, after inserting the jobs, after marking them.
      # :nodoc:
      class_property crash : Proc(Symbol, Nil)?

      @wake = Channel(Nil).new(1)
      @stop = Channel(Nil).new(1)
      @stopped = Channel(Nil).new(1)
      @started = false
      @reported = false

      def initialize(@primary : Database, @queue : Job::Queue, *, @batch : Int32 = 100, @poll_interval : Time::Span = 1.second)
      end

      def start(context : Fiber::ExecutionContext = Fiber::ExecutionContext.default) : Nil
        return if @started

        @started = true
        Job::Outbox.on_commit { wake }
        context.spawn(name: "punch-outbox") { run }
      end

      # Starts the relay only in a binary that enqueues (`Job::Outbox.used?`):
      # without Commands taking `Punch::Jobs` and deferred subscribers,
      # there is no outbox to poll.
      def start_when_used(context : Fiber::ExecutionContext = Fiber::ExecutionContext.default) : Nil
        start(context) if Job::Outbox.used?
      end

      # Stops the relay after a last hand-over, so that entries committed
      # by the last requests reach the queue before the databases close.
      def stop : Nil
        return unless @started

        @started = false
        @stop.send(nil)
        @stopped.receive
      end

      def wake : Nil
        select
        when @wake.send(nil)
        else
        end
      end

      # Hands over every pending entry, batch by batch. Returns how many.
      def drain : Int32
        total = 0
        loop do
          count = handover
          total += count
          break if count < @batch
        end
        total
      end

      # Hands over one batch of pending entries, oldest first: insert into
      # `queue.db` (entries seen before are ignored by their key), then
      # mark them in `primary.db`. Returns how many it read.
      def handover : Int32
        rows = @primary.read do |db|
          db.query_all(<<-SQL, @batch.to_i64, name: "Punch::Job::Outbox.pending_entries") do |row|
            SELECT id, key, queue, type, version, payload, priority, run_at, max_attempts, concurrency_key,
              concurrency_limit, traceparent
            FROM punch_outbox WHERE handed_over_at IS NULL ORDER BY id LIMIT ?
            SQL
            id = row.read(Int64)
            key = row.read(String)
            {id, Job::Queue::Entry.new(queue: row.read(String), type: row.read(String), version: row.read(Int64).to_i32,
              payload: row.read(String), priority: row.read(Int64).to_i32, run_at: Time.unix_ms(row.read(Int64)),
              max_attempts: row.read(Int64).to_i32, unique_key: "outbox:#{key}", concurrency_key: row.read(String?),
              concurrency_limit: row.read(Int64?).try(&.to_i32), traceparent: row.read(String?))}
          end
        end
        return 0 if rows.empty?

        Relay.crash.try(&.call(:read))
        @queue.insert(rows.map(&.[1]))
        Relay.crash.try(&.call(:inserted))
        ids = rows.map(&.[0])
        @primary.write do |db|
          db.exec("UPDATE punch_outbox SET handed_over_at = ? WHERE id IN carray(?) AND handed_over_at IS NULL",
            Time.utc.to_unix_ms, Database::Values.new(ids), name: "Punch::Job::Outbox.handed_over")
        end
        Relay.crash.try(&.call(:marked))
        rows.size
      end

      # A missing table is told once, with its fix, not with a backtrace
      # every poll; anything else is logged each time.
      private def report(ex : Exception) : Nil
        if (ex.message || "").includes?("no such table: punch_outbox")
          Log.error { MISSING_TABLE } unless @reported
          @reported = true
        else
          Log.error(exception: ex) { "handing over outbox entries failed" }
        end
      end

      MISSING_TABLE = "the table punch_outbox is missing, so entries cannot be handed over: run 'punch db:migration --punch outbox', then 'punch db:migrate' (lib/punch/docs/jobs.md)"

      private def run : Nil
        loop do
          begin
            drain
            @reported = false
          rescue ex
            report(ex)
          end
          select
          when @stop.receive
            begin
              drain
            rescue ex
              report(ex)
            end
            break
          when @wake.receive
          when timeout(@poll_interval)
          end
        end
      ensure
        @stopped.send(nil)
      end
    end
  end
end
