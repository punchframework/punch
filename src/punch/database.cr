require "log"
require "./trace"
require "./metrics"
require "./database/error"
require "./database/driver"
require "./database/limits"
require "./database/collation_versions"
require "./database/filesystem"
require "./database/handles"
require "./database/databases"
require "./database/pages"
require "./database/search_text"
require "./database/signals"

module Punch
  # One SQLite database file and its connections:
  #
  # - **one writer connection**, owned by a fiber on its own thread that runs
  #   write transactions one after another, each in `BEGIN IMMEDIATE`. Within
  #   the process, writes never meet `SQLITE_BUSY`; across processes,
  #   `busy_timeout` waits for the other writer;
  # - **a pool of read-only connections** (`query_only`), used by whichever
  #   fiber needs one. Each `read` is one read transaction, so all its
  #   queries see the same snapshot.
  #
  # ```
  # db = Punch::Database.open("/var/lib/app/primary.db")
  # db.write { |writer| writer.exec("INSERT INTO notes (body) VALUES (?)", "hi") }
  # db.read { |reader| reader.query_all("SELECT body FROM notes") { |row| row.read(String) } }
  # db.close
  # ```
  #
  # Operations never see a `Database`, only the `Reader` or `Writer` the
  # router hands them.
  class Database
    Log = ::Log.for("punch.database")

    struct Config
      # Starting values. `busy_timeout` is always set first: otherwise a
      # second process fails while setting `journal_mode`.
      PRAGMAS = {
        "busy_timeout"       => "5000",
        "journal_mode"       => "WAL",
        "synchronous"        => "NORMAL",
        "foreign_keys"       => "ON",
        "mmap_size"          => "134217728",
        "journal_size_limit" => "67108864",
        "cache_size"         => "2000",
        "temp_store"         => "MEMORY",
        # Deleted and overwritten content is zeroed, freed pages too, so
        # that a cleared or dropped value is not left readable in the
        # file and the WAL (an encrypted column's plaintext).
        "secure_delete" => "ON",
      }

      # SQLite's run-time limits, unless the app changes them for a database
      # (`Database.limits`).
      LIMITS = Limits.new

      # Persistent or writer-only settings that readers leave alone.
      WRITER_ONLY = %w[journal_mode journal_size_limit secure_delete]

      # Number of read connections.
      getter readers : Int32
      # How long `read` waits for a free read connection.
      getter checkout_timeout : Time::Span
      # Writes waiting for the writer before `write` blocks.
      getter queue_size : Int32
      # How long a write waits for room in the writer's full queue before
      # it gives up (`WriterBusy`).
      getter enqueue_timeout : Time::Span
      # How often the writer runs `PRAGMA optimize`.
      getter optimize_interval : Time::Span
      # WAL frames (pages) after which the writer checkpoints, between
      # transactions: SQLite's automatic checkpoint, timed (`Signals`).
      getter checkpoint_pages : Int32
      getter pragmas : Hash(String, String)
      # Registered on every connection: Punch's own (`Text::Collation::BUILTIN`)
      # unless replaced, plus any the app adds.
      getter collations : Array(Text::Collation)
      # Whether opening a file refuses indexes built with other collation
      # versions (`CollationVersions`). Off only for the migration commands,
      # which must open the database to rebuild them.
      getter? check_collations : Bool

      def initialize(*, @readers : Int32 = Config.default_readers, @checkout_timeout : Time::Span = 5.seconds,
                     @queue_size : Int32 = 256, @enqueue_timeout : Time::Span = 5.seconds, @optimize_interval : Time::Span = 1.hour,
                     @checkpoint_pages : Int32 = 1000,
                     pragmas : Hash(String, String) = {} of String => String,
                     @collations : Array(Text::Collation) = Text::Collation::BUILTIN, @check_collations : Bool = true)
        raise ArgumentError.new("readers must be at least 1") if @readers < 1
        raise ArgumentError.new("checkpoint_pages must be at least 1") if @checkpoint_pages < 1
        pragmas.each do |key, value|
          unless key.matches?(/\A[a-z_]+\z/) && value.matches?(/\A[A-Za-z0-9_-]+\z/)
            raise ArgumentError.new("invalid pragma #{key} = #{value}")
          end
        end
        @pragmas = PRAGMAS.merge(pragmas.transform_keys(&.downcase))
        if @pragmas.has_key?("wal_autocheckpoint")
          raise ArgumentError.new("the writer checkpoints itself: set checkpoint_pages instead of the wal_autocheckpoint pragma")
        end
      end

      # One read connection per thread the default execution context may
      # run, at least two. `serve` sizes the context first (`PUNCH_THREADS`).
      def self.default_readers : Int32
        Math.max(Fiber::ExecutionContext.default.capacity, 2)
      end

      # The pragmas in the order they are set: `busy_timeout` first.
      def ordered_pragmas(writer : Bool) : Array({String, String})
        ordered = [{"busy_timeout", pragmas["busy_timeout"]}]
        pragmas.each do |key, value|
          next if key == "busy_timeout" || (!writer && WRITER_ONLY.includes?(key))
          ordered << {key, value}
        end
        ordered
      end
    end

    getter name : String
    getter path : String
    getter config : Config
    # What the writer reports: queue depth, WAL frames, checkpoints.
    getter signals : Signals

    @writer : WriterLoop
    @readers : Database::Driver::Pool
    # Keeps the boxed collation procs alive while connections use them.
    getter collation_boxes : Hash(String, Void*)
    @closed = Atomic(Bool).new(false)

    # Opens the database at *path*, creating the file if needed. Refuses a
    # directory on a network or virtual filesystem (`FilesystemError`).
    def self.open(path : String, *, name : String = File.basename(path, ".db"), config : Config = Config.new) : self
      Filesystem.check!(path)
      new(path, name, config, memory: false)
    end

    # A fresh in-memory database, shared by its writer and readers through
    # SQLite's memdb VFS. Without WAL, readers and the writer take turns on
    # one lock; good for specs, not for production load.
    def self.memory(*, name : String = "memory", config : Config = Config.new) : self
      new("file:/punch-#{name}-#{Random::Secure.hex(8)}?vfs=memdb", name, config, memory: true)
    end

    protected def initialize(@path : String, @name : String, @config : Config, @memory : Bool)
      @collation_boxes = Database.box(config.collations)
      @signals = Signals.new
      writer = Database::Driver.open(path)
      begin
        setup(writer, writer: true)
        CollationVersions.check(writer, config.collations, path) if config.check_collations? && !memory
      rescue ex
        writer.close
        raise ex
      end
      # After setup: SQLite checkpointed automatically until here.
      writer.watch_wal(@signals.frames) unless memory
      @writer = WriterLoop.new(writer, name, config, @signals)
      @readers = Database::Driver::Pool.new(path, config.readers, config.checkout_timeout) { |reader| setup(reader, writer: false) }
    end

    # Runs *block* in a read transaction and returns its value. The
    # transaction is a span below the current one (`Punch::Trace`), and so
    # is each statement in it.
    def read(& : Reader -> T) : T forall T
      check_open
      # The body is inlined into every Query's endpoint, so the tracing
      # around it lives in `begin_read` and `end_read` (compile-time budget).
      @readers.using do |connection|
        lease = begin_read(connection)
        begin
          value = yield Reader.new(lease)
          ok = true
          value
        ensure
          end_read(connection, lease, ok == true)
        end
      end
    end

    # Starts the read transaction and its span, and makes the span current.
    private def begin_read(connection : Database::Driver::Connection) : Lease
      parent = Trace.current
      span = transaction_span(parent, "read")
      begin
        connection.exec("BEGIN")
      rescue ex
        span.error(ex)
        span.finish
        raise ex
      end
      fiber = Fiber.current
      lease = Lease.new(connection, name, span, parent.root, previous: fiber.punch_span)
      lease.previous_epoch = fiber.punch_read_epoch
      fiber.punch_span = span
      # Before the snapshot, which `BEGIN` takes at the first read: a cache
      # value computed in this transaction is kept only if its key was not
      # invalidated since (`Punch::Cache`).
      fiber.punch_read_epoch ||= Caches.epoch
      lease
    end

    private def end_read(connection : Database::Driver::Connection, lease : Lease, ok : Bool) : Nil
      Fiber.current.punch_span = lease.previous
      Fiber.current.punch_read_epoch = lease.previous_epoch
      lease.close
      span = lease.span
      span.error("failed") unless ok
      span.finish
      connection.exec("ROLLBACK") if connection.in_transaction?
    end

    # Runs *block* on the writer in a `BEGIN IMMEDIATE` transaction and
    # returns its value. An exception rolls the transaction back and is
    # raised here; a returned value commits, unless the framework marked
    # the transaction rollback-only (a Command's failure result). The span records how long the
    # write waited for the writer and its lock (`punch.db.writer_wait_ms`).
    #
    # Once the transaction has committed, the work it left with
    # `Lease#after_commit` (event delivery) runs here, in the caller's
    # fiber, before `write` returns.
    def write(&block : Writer -> T) : T forall T
      check_open
      parent = Trace.current
      span = transaction_span(parent, "write")
      enqueued = Time.instant
      committed = nil.as(Array(Proc(Nil))?)
      value = begin
        @writer.run do |connection|
          lease = Lease.new(connection, name, span, parent.root, waited_since: enqueued)
          begin
            result = Trace.with(span) { block.call(Writer.new(lease)) }
            if lease.rollback_only?
              connection.exec("ROLLBACK")
              span.set("punch.db.rolled_back", true)
              # What must stay although the rest rolled back, in a new
              # transaction in the same turn of the writer.
              if kept = lease.after_rollback
                # Work the rolled-back writes left is dropped; the kept
                # writes' own (events they publish) runs after their commit.
                lease.drop_committed
                connection.exec("BEGIN IMMEDIATE")
                kept.call(Writer.new(lease))
                committed = lease.committed
              end
            else
              committed = lease.committed
            end
            result
          ensure
            lease.close
          end
        end
      rescue ex
        span.error(ex)
        raise ex
      ensure
        span.finish
      end
      Database.after_commit(committed)
      value
    end

    # Runs what a committed transaction left behind, in order.
    # :nodoc:
    def self.after_commit(work : Array(Proc(Nil))?) : Nil
      work.try &.each(&.call)
    end

    private def transaction_span(parent : Trace::Span, kind : String) : Trace::Span
      span = parent.child("#{name} #{kind}")
      span.set("db.namespace", name) if span.recording?
      span
    end

    # :nodoc:
    # Runs *block* on the writer's connection with no transaction around it,
    # for framework code that needs connection-level settings outside one,
    # such as migrations. Never handed to application code.
    def with_writer_connection(&block : Database::Driver::Connection -> T) : T forall T
      check_open
      @writer.run(transaction: false, &block)
    end

    # Closes the readers, then the writer, which runs `PRAGMA optimize` and
    # lets SQLite checkpoint the WAL. Idempotent.
    def close : Nil
      return if @closed.swap(true)

      @readers.close
      @writer.close
    end

    def closed? : Bool
      @closed.get
    end

    def memory? : Bool
      @memory
    end

    # `nil` while the writer is running, otherwise why not: for `/up`.
    def health : String?
      return "#{name}: closed" if closed?

      @writer.alive? ? nil : "#{name}: writer stopped"
    end

    # Registers this database's signals with *registry*: writer queue
    # depth, WAL size and frames, checkpoint durations (`docs/metrics.md`).
    # A closed database reports nothing.
    def observe(registry : Metrics::Registry) : Nil
      signals.observe(registry, self)
    end

    private def check_open : Nil
      raise Error.new("database #{name} is closed", code: 21) if closed?
    end

    # Each collation's compare proc, boxed for SQLite, by name.
    def self.box(collations : Array(Text::Collation)) : Hash(String, Void*)
      collations.to_h { |collation| {collation.name, Box(Text::Collation::Compare).box(collation.compare)} }
    end

    private def setup(connection : Database::Driver::Connection, writer : Bool) : Nil
      # Before any statement: limits, and no ATTACH (Punch never attaches).
      connection.harden(Database.limits_for(name))
      # First: `PRAGMA optimize` below may analyze indexes on collated
      # columns.
      connection.install(@collation_boxes)
      config.ordered_pragmas(writer).each do |key, value|
        # The one statement Punch builds from values: SQLite cannot bind a
        # PRAGMA's value. `Config.new` admits only names matching
        # /\A[a-z_]+\z/ and values matching /\A[A-Za-z0-9_-]+\z/, and the
        # values come from the app's code, never from a request.
        connection.exec("PRAGMA #{key} = #{value}") # ameba:disable Punch/SQLText
      end
      if writer
        mode = connection.scalar_text("PRAGMA journal_mode")
        if !@memory && mode != config.pragmas["journal_mode"].downcase
          raise Error.new("#{path}: journal_mode is #{mode}, expected #{config.pragmas["journal_mode"]}", code: 1)
        end
        # Analyze what needs it on a long-lived connection (SQLite's advice).
        Database.optimize(connection, on_open: true)
      else
        connection.exec("PRAGMA query_only = ON")
      end
    end

    # Runs `PRAGMA optimize` in its own `BEGIN IMMEDIATE` transaction. Run
    # outside one, it reads first and writes the statistics after: if another
    # process committed in between, SQLite answers SQLITE_BUSY at once,
    # without waiting for `busy_timeout`.
    # :nodoc:
    def self.optimize(connection : Database::Driver::Connection, *, on_open : Bool = false) : Nil
      connection.exec("BEGIN IMMEDIATE")
      begin
        connection.exec(on_open ? "PRAGMA optimize = 0x10002" : "PRAGMA optimize")
        connection.exec("COMMIT")
      ensure
        connection.exec("ROLLBACK") if connection.in_transaction?
      end
    end

    # Hands a connection to a `Reader` or `Writer` for the length of one
    # block. A handle kept past its block raises instead of using a
    # connection that belongs to someone else by then.
    # :nodoc:
    class Lease
      getter span : Trace::Span
      # The span that was current before the transaction's.
      getter previous : Trace::Span?
      # Set by the framework when a Command's result is a failure: the
      # write ends with `ROLLBACK` instead of `COMMIT`.
      property? rollback_only = false
      # Work for after the commit, in the order it was left.
      getter committed : Array(Proc(Nil))?
      # Writes that stay when the transaction rolls back (`rollback_only`):
      # they run in a transaction of their own right after the rollback,
      # before the writer takes other work. The stored answer of a Command
      # that failed under an idempotency key.
      property after_rollback : Proc(Writer, Nil)?
      # The live role assignments of users this transaction asked about
      # (`Roles.check`), so a page whose links ask many policies reads
      # them once. `Roles.assign` and `revoke` clear it.
      property roles_held : Hash(Int64, Array(Roles::Held))?
      # The fiber's `punch_read_epoch` before a read transaction began.
      property previous_epoch : Int64?

      def initialize(@connection : Database::Driver::Connection, @database : String, @span : Trace::Span,
                     @event : Trace::Span, waited_since : Time::Instant? = nil, @previous : Trace::Span? = nil)
        @open = true
        if waited_since && @event.recording?
          waited = (Time.instant - waited_since).total_milliseconds
          @span.set("punch.db.writer_wait_ms", waited.round(3))
          @event.add("punch.db.writer_wait_ms", waited)
        end
      end

      def connection : Database::Driver::Connection
        raise Error.new("a database handle was used after its block ended", code: 21) unless @open
        @connection
      end

      def close : Nil
        @open = false
      end

      # Forgets the work left so far, after a rollback. :nodoc:
      def drop_committed : Nil
        @committed = nil
      end

      # Leaves *work* to run once the transaction has committed, in the
      # fiber that asked for the write. Dropped on rollback.
      def after_commit(work : Proc(Nil)) : Nil
        raise Error.new("a database handle was used after its block ended", code: 21) unless @open
        (@committed ||= [] of Proc(Nil)) << work
      end

      def probe(sql : String, name : String?) : Probe
        Probe.start(@database, @span, @event, sql, name)
      end

      def exec(sql : String, args : Enumerable, name : String?) : ExecResult
        probe = probe(sql, name)
        begin
          result = connection.exec(sql, args)
        ensure
          probe.finish(result.try(&.changes) || 0_i64, !result.nil?, changed: true)
        end
      end
    end

    # Times one statement: a client span below the transaction when the
    # trace is sampled, and the totals on the wide event (`punch.db.queries`,
    # `punch.db.duration_ms`, `punch.db.rows`) whenever there is one, with
    # the named query's tally for the ops console (`Span#tally_query`).
    # Records the SQL text, never the arguments.
    # :nodoc:
    struct Probe
      def self.start(database : String, parent : Trace::Span, event : Trace::Span, sql : String, name : String?) : Probe
        return new(Trace::Span::NOOP, event, nil, nil) unless event.recording?

        operation = Probe.operation(sql)
        span = parent.child(name || operation, :client)
        if span.recording?
          span.set("db.system.name", "sqlite")
          span.set("db.namespace", database)
          span.set("db.operation.name", operation)
          span.set("db.query.text", sql)
          span.set("punch.query", name) if name
        end
        new(span, event, Time.instant, name)
      end

      def initialize(@span : Trace::Span, @event : Trace::Span, @started : Time::Instant?, @name : String?)
      end

      # *ok* is false when the statement or the block reading its rows
      # raised. The exception itself reaches the transaction and the request.
      def finish(rows : Int, ok : Bool, changed : Bool = false) : Nil
        started = @started || return
        @span.set(changed ? "punch.db.changes" : "db.response.returned_rows", rows)
        @span.error("failed") unless ok
        @span.finish
        ms = (Time.instant - started).total_milliseconds
        @event.add({"punch.db.queries", 1_i64}, {"punch.db.duration_ms", ms},
          {changed ? "punch.db.changes" : "punch.db.rows", rows.to_i64}, {"punch.db.errors", ok ? 0_i64 : 1_i64})
        @name.try { |name| @event.tally_query(name, ms, rows.to_i64, ok) }
      end

      # The statement's first keyword: `SELECT`, `INSERT`, `WITH`, …
      def self.operation(sql : String) : String
        start = 0
        while start < sql.bytesize && sql.byte_at(start).unsafe_chr.ascii_whitespace?
          start += 1
        end
        finish = start
        while finish < sql.bytesize && sql.byte_at(finish).unsafe_chr.ascii_letter?
          finish += 1
        end
        sql.byte_slice(start, finish - start).upcase
      end
    end

    # The writer: a fiber on an isolated thread, draining a channel of write
    # transactions.
    private class WriterLoop
      record Job, work : Proc(Database::Driver::Connection, Nil), done : Channel(Exception?), transaction : Bool

      @jobs : Channel(Job)
      @context : Fiber::ExecutionContext::Isolated
      @fiber : Fiber? = nil
      @alive = Atomic(Bool).new(true)
      @last_optimize = Time.instant
      # WAL frames at which the next checkpoint runs, and the WAL's size at
      # the last one (see `checkpoint`).
      @checkpoint_at : Int32
      @checkpoint_log = 0

      def initialize(@connection : Database::Driver::Connection, @name : String, @config : Config, @signals : Signals)
        @checkpoint_at = @config.checkpoint_pages
        @jobs = Channel(Job).new(@config.queue_size)
        @context = Fiber::ExecutionContext::Isolated.new("punch-writer:#{@name}") { drain }
      end

      def run(transaction : Bool = true, &block : Database::Driver::Connection -> T) : T forall T
        if Fiber.current.same?(@fiber)
          raise Error.new("write called inside a write on #{@name}: it would wait for itself. Use the Writer you have.", code: 1)
        end
        # A one-element tuple rather than `uninitialized T`: with a block that
        # always raises (T = NoReturn), a captured `uninitialized T` sends
        # Crystal 1.21.1's code generator into an endless loop.
        result = nil.as({T}?)
        done = Channel(Exception?).new(1)
        @signals.queued.add(1)
        begin
          job = Job.new(->(connection : Database::Driver::Connection) { result = {block.call(connection)}; nil }, done, transaction)
          select
          when @jobs.send(job)
          when timeout(@config.enqueue_timeout)
            @signals.queued.sub(1)
            raise WriterBusy.new("the writer of #{@name} has had #{@config.queue_size} writes waiting for #{@config.enqueue_timeout.total_seconds.to_i} s")
          end
        rescue Channel::ClosedError
          @signals.queued.sub(1)
          raise Error.new("database #{@name} is closed", code: 21)
        end
        if error = done.receive
          raise error
        end
        # A local copy: a variable captured by a closure is not narrowed.
        value = result
        raise Error.new("the writer finished a job without a result", code: 1) unless value
        value[0]
      end

      def alive? : Bool
        @alive.get
      end

      def close : Nil
        @jobs.close
        @context.wait
      end

      private def drain : Nil
        @fiber = Fiber.current
        Fiber.current.punch_writer = true
        loop do
          select
          when job = @jobs.receive?
            break unless job
            @signals.queued.sub(1)
            job.done.send(job.transaction ? transaction(job) : bare(job))
            # After the caller has its answer: the next write waits instead.
            frames = @signals.frames.value.get
            # A smaller WAL than at the last checkpoint: it started over.
            @checkpoint_at = @config.checkpoint_pages if frames < @checkpoint_log
            checkpoint if frames >= @checkpoint_at
          when timeout(@config.optimize_interval)
          end
          optimize if Time.instant - @last_optimize >= @config.optimize_interval
        end
      ensure
        @alive.set(false)
        optimize
        @connection.close
      end

      private def transaction(job : Job) : Exception?
        @connection.exec("BEGIN IMMEDIATE")
        job.work.call(@connection)
        # A job may have rolled back already (`Lease#rollback_only?`).
        @connection.exec("COMMIT") if @connection.in_transaction?
        nil
      rescue ex
        rollback
        ex
      end

      private def rollback : Nil
        @connection.exec("ROLLBACK") if @connection.in_transaction?
      rescue error
        Log.error(exception: error) { "#{@name}: rollback failed" }
      end

      # A job that manages its own transaction, such as a migration. One left
      # open is rolled back and reported as a bug.
      private def bare(job : Job) : Exception?
        job.work.call(@connection)
        return unless @connection.in_transaction?

        @connection.exec("ROLLBACK")
        Error.new("#{@name}: a job left a transaction open; rolled back", code: 1)
      rescue ex
        rollback
        ex
      end

      # A passive checkpoint. One that leaves frames behind, because a
      # reader still needs them (Litestream holds a read transaction between
      # its own checkpoints), is tried again only after `checkpoint_pages`
      # more frames, not after every write.
      private def checkpoint : Nil
        started = Time.instant
        log, checkpointed = @connection.checkpoint
        @signals.checkpointed((Time.instant - started).total_seconds, log, checkpointed)
        @checkpoint_log = log
        @checkpoint_at = checkpointed >= log ? @config.checkpoint_pages : log + @config.checkpoint_pages
      rescue ex
        Log.error(exception: ex) { "#{@name}: checkpoint failed" }
      end

      private def optimize : Nil
        @last_optimize = Time.instant
        Database.optimize(@connection)
      rescue ex
        Log.error(exception: ex) { "#{@name}: PRAGMA optimize failed" }
      end
    end
  end
end

class Fiber
  # Set on a database's writer fiber: work there runs inside a write
  # transaction, so a direct enqueue would escape it (`Punch::Job::Queue`).
  # :nodoc:
  property? punch_writer = false
end
