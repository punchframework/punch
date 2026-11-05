module Punch
  # Rewrites every stored JSON document of a composite in its current
  # form (docs/composites.md, "Versions"): what `punch db:upgrade` and the
  # nightly `Database::Upgrade::Run` job do. A document of an older version
  # is read through its frozen types and written as the current one, so
  # the frozen type can go once `db:audit` counts no row of its version.
  # A document is also rewritten when it is not in its stored form
  # (written by hand, keys in another order); keys this release does not
  # know stay. One that does not parse, or that a newer release wrote
  # (`newer_version`), stays as it is and is reported by row.
  #
  # Each batch is one write transaction, and only rows that change are
  # written. `punch db:generate` writes an `upgrade` method into the
  # `Table` of every table with a document column and registers it here.
  class Database::Upgrade
    BATCH  = 500
    SAMPLE =  10

    alias Rewriting = Proc(Writer, Int64, Int32, Database::Upgrade, Int64?)

    @@tables = [] of {String, Rewriting}

    def self.table(table : String, &rewriting : Writer, Int64, Int32, Database::Upgrade -> Int64?) : Nil
      @@tables.reject!(&.[0].==(table))
      @@tables << {table, rewriting}
    end

    def self.tables : Array(String)
      @@tables.map(&.[0]).sort!
    end

    # What happened to one document column.
    class Column
      include JSON::Serializable

      getter table : String
      getter column : String
      getter rewritten = 0_i64
      getter failed = {} of String => Int64
      getter failed_rows = [] of Int64

      def initialize(@table : String, @column : String)
      end

      # :nodoc:
      def rewritten! : Nil
        @rewritten += 1
      end

      # :nodoc:
      def failed!(reason : String, row : Int64) : Nil
        @failed[reason] = (@failed[reason]? || 0_i64) + 1
        @failed_rows << row if @failed_rows.size < SAMPLE && !@failed_rows.includes?(row)
      end

      def failed_count : Int64
        @failed.values.sum(0_i64)
      end
    end

    getter rows = {} of String => Int64
    getter written = {} of String => Int64
    @columns = {} of {String, String} => Column
    @pending = [] of {String, String}

    # Runs every registered table the database has, in batches of
    # *batch* rows, each in its own write transaction.
    def self.run(database : Database, batch : Int32 = BATCH, between : Proc(Nil)? = nil) : Database::Upgrade
      run = Database::Upgrade.new
      after = nil
      loop do
        step = database.write { |writer| Database::Upgrade.batch(writer, after.try(&.[0]), after.try(&.[1]) || 0_i64, run, batch) }
        break unless step
        after = step
        between.try(&.call)
      end
      run
    end

    # One batch: the rows after *after* of *table*, or of the next table
    # once it is done; the first table when *table* is `nil`. Returns the
    # table and the last row read, `nil` when every table is done.
    def self.batch(writer : Writer, table : String?, after : Int64, run : Database::Upgrade, size : Int32 = BATCH) : {String, Int64}?
      present = writer.query_all("SELECT name FROM sqlite_schema WHERE type = 'table'", name: "Punch::Database::Upgrade.tables", &.read(String)).to_set
      @@tables.select { |name, _| present.includes?(name) }.sort_by!(&.[0]).each do |name, rewriting|
        next if table && name < table

        last = rewriting.call(writer, name == table ? after : 0_i64, size, run)
        return {name, last} if last
      end
      nil
    end

    # The columns with something done or found.
    def columns : Array(Column)
      @columns.values.select { |column| column.rewritten + column.failed_count > 0 }.sort_by! { |column| {column.table, column.column} }
    end

    def clean? : Bool
      columns.all?(&.failed_count.zero?)
    end

    # :nodoc:
    def row(table : String) : Nil
      @rows[table] = (@rows[table]? || 0_i64) + 1
      @pending.clear
    end

    # The document *raw* of *table*.*column* in its current form: itself
    # when it is, else read as *type* and written again.
    # :nodoc:
    def document(type : T.class, raw : String?, table : String, column : String, row : Int64) : String? forall T
      raw = raw || return
      current = Stored.dump(Stored.load(T, raw, table, column, row))
      return raw if current == raw

      @pending << {table, column}
      current
    rescue ex : Database::RowError
      entry(table, column).failed!(ex.reason, row)
      raw
    end

    # The same for an encrypted document: decrypted, read, written again,
    # and encrypted under the signing key when it changes.
    # :nodoc:
    def encrypted_document(type : T.class, raw : Bytes?, table : String, column : String, row : Int64) : Bytes? forall T
      raw = raw || return
      plain = Stored.encryptor(table, column).decrypt(raw)
      return failed(table, column, "not_decrypting", row, raw) unless plain

      text = String.new(plain)
      current = Stored.dump(Stored.load(T, text, table, column, row))
      return raw if current == text

      @pending << {table, column}
      Stored.encryptor(table, column).encrypt(current.to_slice)
    rescue ex : Database::RowError
      failed(table, column, ex.reason, row, raw)
    end

    # :nodoc:
    def write(table : String, row : Int64, &) : Nil
      yield
      @written[table] = (@written[table]? || 0_i64) + 1
      @pending.each { |(table_name, column)| entry(table_name, column).rewritten! }
    ensure
      @pending.clear
    end

    private def failed(table : String, column : String, reason : String, row : Int64, raw : Bytes?) : Bytes?
      entry(table, column).failed!(reason, row)
      raw
    end

    private def entry(table : String, column : String) : Column
      @columns[{table, column}] ||= Column.new(table, column)
    end

    # One line per column, without values.
    def messages : Array(String)
      columns.map do |found|
        parts = ["#{found.rewritten} rewritten"]
        if found.failed_count > 0
          reasons = found.failed.join(", ") { |reason, count| "#{count} #{reason}" }
          parts << "#{found.failed_count} left as they are (#{reasons}); rows #{found.failed_rows.join(", ")}#{found.failed_count > SAMPLE ? ", …" : ""}"
        end
        "#{found.table}.#{found.column}: #{parts.join(", ")}"
      end
    end

    def to_json(json : JSON::Builder) : Nil
      json.object do
        json.field "clean", clean?
        json.field "rows", @rows
        json.field "written", @written
        json.field "columns", columns
      end
    end

    # Rewrites documents of older versions every night at 04:30 UTC,
    # after the audit and the encryption run, at the lowest priority, a
    # batch per call of its one step, resumable like `Encryption::Run`.
    # What it did goes into the job's wide event (`punch.upgrade.*`).
    @[Punch::Job::Recurring(cron: "30 4 * * *")]
    @[Punch::Job::Options(priority: -100)]
    struct Run
      include Punch::Job
      include Punch::Job::Stepped

      FINDINGS = 20

      record Position, table : String, after : Int64, rows : Int64 = 0, written : Int64 = 0, findings : Array(String) = [] of String do
        include JSON::Serializable
      end

      # :nodoc:
      class_property batch_size : Int32 = BATCH

      def initialize
      end

      @[Punch::Job::Step]
      def rewrite(job : Punch::Job::Context, position : Punch::Job::Cursor(Position)) : Punch::Job::StepResult
        return if Database::Upgrade.tables.empty?

        at = position.at
        run = Database::Upgrade.new
        job.write do |db|
          batch = Database::Upgrade.batch(db, at.try(&.table), at.try(&.after) || 0_i64, run, Run.batch_size)
          rows = (at.try(&.rows) || 0_i64) + run.rows.values.sum(0_i64)
          written = (at.try(&.written) || 0_i64) + run.written.values.sum(0_i64)
          findings = ((at.try(&.findings) || [] of String) + run.messages.select(&.includes?("left as they are"))).first(FINDINGS)
          Run.report(rows, written, findings)
          batch.try { |table, last| position.continue(Position.new(table, last, rows, written, findings)) }
        end
      end

      # :nodoc:
      def self.report(rows : Int64, written : Int64, findings : Array(String)) : Nil
        event = Trace.event
        return unless event.recording?

        event.set("punch.upgrade.rows", rows)
        event.set("punch.upgrade.written", written)
        event.set("punch.upgrade.findings", findings.join('\n')) unless findings.empty?
      end
    end
  end
end
