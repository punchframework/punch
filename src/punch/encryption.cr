module Punch
  # Brings every encrypted column to the key ring's signing key, in
  # batches: what `punch db:encrypt` and the nightly
  # `Database::Encryption::Run` job do.
  #
  # - **Rotation:** a value encrypted under an older key is encrypted
  #   again under the signing key, and a blind index hashed under an older
  #   key is hashed again, so the old key can retire once `db:audit`
  #   counts nothing under it.
  # - **Conversion:** a column mapped as `Punch::Encrypted(T).from(:email)`
  #   gets the ciphertext of the plaintext `email` where it has none; with
  #   `clear: true`, the plaintext is set to NULL once the ciphertext is
  #   there.
  #
  # Each batch is one write transaction, and only rows that change are
  # written. A value that does not decrypt or parse stays as it is and is
  # reported by row; so is a row whose new blind index another row already
  # has (two values that were equal under different keys).
  #
  # `punch db:generate` writes a `reencrypt` method into the `Table` of
  # every table with an encrypted column and registers it here.
  class Database::Encryption
    # Rows read per write transaction.
    BATCH = 500

    # Row IDs kept per finding, for the report.
    SAMPLE = 10

    alias Rewriting = Proc(Writer, Int64, Int32, Database::Encryption, Int64?)

    @@tables = [] of {String, Rewriting}

    # Registers the generated method that brings up to a batch of *table*'s
    # rows after a rowid to the signing key and returns the last one read.
    def self.table(table : String, &rewriting : Writer, Int64, Int32, Database::Encryption -> Int64?) : Nil
      @@tables.reject!(&.[0].==(table))
      @@tables << {table, rewriting}
    end

    def self.tables : Array(String)
      @@tables.map(&.[0]).sort!
    end

    # What happened to one column.
    class Column
      getter table : String
      getter column : String
      getter encrypted = 0_i64
      getter converted = 0_i64
      getter rehashed = 0_i64
      getter cleared = 0_i64
      getter failed = {} of String => Int64
      getter failed_rows = [] of Int64

      def initialize(@table : String, @column : String)
      end

      # :nodoc:
      def count!(what : Symbol) : Nil
        case what
        when :encrypted then @encrypted += 1
        when :converted then @converted += 1
        when :rehashed  then @rehashed += 1
        when :cleared   then @cleared += 1
        end
      end

      # :nodoc:
      def failed!(reason : String, row : Int64) : Nil
        @failed[reason] = (@failed[reason]? || 0_i64) + 1
        @failed_rows << row if @failed_rows.size < SAMPLE && !@failed_rows.includes?(row)
      end

      def failed_count : Int64
        @failed.values.sum(0_i64)
      end

      def changed? : Bool
        @encrypted + @converted + @rehashed + @cleared + failed_count > 0
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "table", @table
          json.field "column", @column
          json.field "encrypted", @encrypted
          json.field "converted", @converted
          json.field "rehashed", @rehashed
          json.field "cleared", @cleared
          json.field "failed", @failed
          json.field "failed_rows", @failed_rows
        end
      end
    end

    # Rows read and rows written per table.
    getter rows = {} of String => Int64
    getter written = {} of String => Int64
    getter signing : UInt32
    @columns = {} of {String, String} => Column
    # What the row being read would count once written: work on a row
    # whose write fails is not counted.
    @pending = [] of {String, String, Symbol}
    # The plaintext columns of the row being read that must keep their
    # value: their ciphertext does not decrypt, or holds something else.
    @keep = Set({String, String}).new

    def initialize(@ring : KeyRing = KeyRing.current)
      @signing = @ring.signing.id
    end

    # Runs every registered table in batches of *batch* rows, each in its
    # own write transaction, with a span per table. *between* runs after
    # each batch: the nightly job yields there.
    def self.run(database : Database, batch : Int32 = BATCH, between : Proc(Nil)? = nil) : Database::Encryption
      run = Database::Encryption.new
      present = database.read { |reader| reader.query_all("SELECT name FROM sqlite_schema WHERE type = 'table'", name: "Punch::Database::Encryption.tables", &.read(String)) }.to_set
      # A binary may register tables a database does not have, such as
      # Punch's own for a part the app does not use.
      @@tables.select { |table, _| present.includes?(table) }.sort_by!(&.[0]).each do |table, rewriting|
        Trace.span("punch.encryption.table") do |span|
          span.set("db.collection.name", table)
          after = 0_i64
          loop do
            last = database.write { |writer| rewriting.call(writer, after, batch, run) }
            break unless last
            after = last
            between.try(&.call)
          end
          span.set("punch.encryption.rows", run.rows[table]? || 0_i64)
          span.set("punch.encryption.written", run.written[table]? || 0_i64)
        end
      end
      run
    end

    # One batch of a run that walks the tables in order: the rows after
    # *after* of *table*, or of the next table the database has once
    # *table* is done; the first table when *table* is `nil`. Returns the
    # table and the last row it rewrote, `nil` when every table is done.
    # The nightly job's step (`Run#rewrite`), in its own transaction.
    def self.batch(writer : Writer, table : String?, after : Int64, run : Database::Encryption, size : Int32 = BATCH) : {String, Int64}?
      present = writer.query_all("SELECT name FROM sqlite_schema WHERE type = 'table'", name: "Punch::Database::Encryption.tables", &.read(String)).to_set
      @@tables.select { |name, _| present.includes?(name) }.sort_by!(&.[0]).each do |name, rewriting|
        next if table && name < table

        last = rewriting.call(writer, name == table ? after : 0_i64, size, run)
        return {name, last} if last
      end
      nil
    end

    # The columns with something done or found, by table and column.
    def columns : Array(Column)
      @columns.values.select(&.changed?).sort_by! { |column| {column.table, column.column} }
    end

    # Whether every value was brought to the signing key.
    def clean? : Bool
      columns.all?(&.failed_count.zero?)
    end

    # Counts a row read from *table*.
    # :nodoc:
    def row(table : String) : Nil
      @rows[table] = (@rows[table]? || 0_i64) + 1
      @pending.clear
      @keep.clear
    end

    # The ciphertext *raw* of *table*.*column* under the signing key:
    # itself when it is, else encrypted again. `nil` stays `nil`; a value
    # that does not decrypt stays as it is and is reported.
    # :nodoc:
    def encrypted(raw : Bytes?, table : String, column : String, row : Int64) : Bytes?
      raw = raw || return
      return raw if key_id(raw) == @signing

      plain = Stored.encryptor(table, column).decrypt(raw)
      return failed(table, column, "not_decrypting", row, raw) unless plain

      @pending << {table, column, :encrypted}
      Stored.encryptor(table, column).encrypt(plain)
    end

    # The ciphertext of a column converted from the plaintext column
    # *plain_column* (`from(:email)`): its own value brought to the signing
    # key, else the plaintext *plain*, parsed as *type* and encrypted. Where
    # the row has both, they must agree: a ciphertext that does not decrypt
    # or holds another value (a write to the plaintext alone, during a
    # deploy) is reported, and the plaintext is not cleared.
    # :nodoc:
    def converted(type : T.class, raw : Bytes?, plain : R?, table : String, column : String, plain_column : String, row : Int64) : Bytes? forall T, R
      if raw
        if plain
          decrypted = Stored.encryptor(table, column).decrypt(raw)
          if decrypted.nil? || decrypted != Stored.plaintext(Stored.dump(Stored.load(T, plain, table, plain_column, row)))
            @keep << {table, plain_column}
            return failed(table, column, decrypted ? "plaintext_differs" : "not_decrypting", row, raw)
          end
        end
        return encrypted(raw, table, column, row)
      end

      plain = plain || return
      value = Stored.load(T, plain, table, plain_column, row)
      @pending << {table, column, :converted}
      Stored.encrypt(Secret.new(value), table, column)
    rescue ex : Database::RowError
      @keep << {table, plain_column}
      failed(table, column, ex.reason, row, raw)
    end

    # The blind index of the encrypted value *source* (the ciphertext the
    # row gets): *raw* when it is that value's hash under the signing key,
    # else hashed again.
    # :nodoc:
    def indexed(raw : Bytes?, source : Bytes?, table : String, column : String, source_column : String, row : Int64) : Bytes?
      source = source || return
      plain = Stored.encryptor(table, source_column).decrypt(source) || return raw
      index = Stored.index(table, column)
      return raw if raw && key_id(raw) == @signing && index.matches?(raw, plain)

      @pending << {table, column, :rehashed}
      index.digest(plain)
    end

    # Writes one row's new values; a unique blind index another row
    # already has is reported, and the row stays as it was.
    # :nodoc:
    def write(table : String, row : Int64, &) : Nil
      yield
      @written[table] = (@written[table]? || 0_i64) + 1
      @pending.each { |(table_name, column, what)| entry(table_name, column).count!(what) }
    rescue ex : Database::ConstraintError
      entry(table, ex.detail.split('.').last).failed!("taken", row)
    ensure
      @pending.clear
    end

    # The plaintext column's new value once its encrypted column has
    # *encrypted* (`from(:email, clear: true)`): NULL, unless `converted`
    # found that the ciphertext does not hold it.
    # :nodoc:
    def cleared(plain : R?, encrypted : Bytes?, table : String, column : String) : R? forall R
      return plain unless plain && encrypted
      return plain if @keep.includes?({table, column})

      @pending << {table, column, :cleared}
      nil
    end

    private def failed(table : String, column : String, reason : String, row : Int64, raw : Bytes?) : Bytes?
      entry(table, column).failed!(reason, row)
      raw
    end

    private def key_id(raw : Bytes) : UInt32?
      IO::ByteFormat::BigEndian.decode(UInt32, raw[1, 4]) if raw.size > 4
    end

    private def entry(table : String, column : String) : Column
      @columns[{table, column}] ||= Column.new(table, column)
    end

    # One line per column, without values.
    def messages : Array(String)
      lines(columns)
    end

    # The lines of the columns with values left as they are.
    def failures : Array(String)
      lines(columns.select(&.failed_count.positive?))
    end

    private def lines(found_columns : Array(Column)) : Array(String)
      found_columns.map do |found|
        done = {"encrypted again" => found.encrypted, "converted" => found.converted, "hashed again" => found.rehashed, "plaintext cleared" => found.cleared}
        parts = done.compact_map { |what, count| "#{count} #{what}" if count > 0 }
        if found.failed_count > 0
          reasons = found.failed.join(", ") { |reason, count| "#{count} #{reason}" }
          parts << "#{found.failed_count} left as they are (#{reasons}); rows #{found.failed_rows.join(", ")}#{found.failed_count > SAMPLE ? ", …" : ""}"
        end
        "#{found.table}.#{found.column}: #{parts.join(", ")}"
      end
    end

    def to_json(json : JSON::Builder) : Nil
      json.object do
        json.field "signing_key", @signing
        json.field "clean", clean?
        json.field "rows", @rows
        json.field "written", @written
        json.field "columns", columns
      end
    end

    # Brings the primary database to the signing key every night at 04:00
    # UTC, after the audit, at the lowest priority, a batch per call of its
    # one step: a deploy or a crash resumes it after the last batch saved,
    # which commits with the batch (docs/jobs.md, "Long jobs: steps"). What
    # it did goes into the job's wide event (`punch.encryption.*`), totals
    # since the run began; it never fails the job.
    @[Punch::Job::Recurring(cron: "0 4 * * *")]
    @[Punch::Job::Options(priority: -100)]
    struct Run
      include Punch::Job
      include Punch::Job::Stepped

      # How many findings (columns with values left as they are, per
      # batch) a run keeps for its wide event.
      FINDINGS = 20

      # Where the run is, and what it did so far.
      record Position, table : String, after : Int64, rows : Int64 = 0, written : Int64 = 0, findings : Array(String) = [] of String do
        include JSON::Serializable
      end

      # Rows per batch; specs make it small.
      # :nodoc:
      class_property batch_size : Int32 = BATCH

      def initialize
      end

      @[Punch::Job::Step]
      def rewrite(job : Punch::Job::Context, position : Punch::Job::Cursor(Position)) : Punch::Job::StepResult
        return if Database::Encryption.tables.empty? || KeyRing.current?.nil?

        at = position.at
        run = Database::Encryption.new
        job.write do |db|
          batch = Database::Encryption.batch(db, at.try(&.table), at.try(&.after) || 0_i64, run, Run.batch_size)
          rows = (at.try(&.rows) || 0_i64) + run.rows.values.sum(0_i64)
          written = (at.try(&.written) || 0_i64) + run.written.values.sum(0_i64)
          findings = ((at.try(&.findings) || [] of String) + run.failures).first(FINDINGS)
          Run.report(rows, written, findings)
          batch.try { |table, last| position.continue(Position.new(table, last, rows, written, findings)) }
        end
      end

      # :nodoc:
      def self.report(rows : Int64, written : Int64, findings : Array(String)) : Nil
        event = Trace.event
        return unless event.recording?

        event.set("punch.encryption.rows", rows)
        event.set("punch.encryption.written", written)
        event.set("punch.encryption.findings", findings.join('\n')) unless findings.empty?
      end
    end
  end
end
