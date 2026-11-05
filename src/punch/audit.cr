module Punch
  # Parses every stored value of every mapped column against today's
  # domain types: what `punch db:audit` and the nightly
  # `Database::Audit::Run` job report. Tightening a type is then a two-step
  # change: run the audit with the new type, fix the data, ship.
  #
  # Two findings per column: values that no longer **parse** (they would
  # raise `Database::RowError` when read), and values that parse but are
  # not in their **canonical** stored form, such as a time written by
  # SQLite's `datetime()` or text that normalization changes. The second
  # reads fine, but compares and sorts unlike what Punch writes, which a
  # page cursor relies on. Findings carry row IDs and reasons, never values,
  # so personal data stays out of reports.
  #
  # `punch db:generate` writes an `audit` method for every mapped table
  # into its `records.gen.cr` and registers it here with `Database::Audit.table`.
  class Database::Audit
    # Rows read per read transaction, so a long audit never holds one open.
    BATCH = 500

    # Row IDs kept per finding, for the report.
    SAMPLE = 10

    alias Reading = Proc(Reader, Int64, Int32, Database::Audit, Int64?)

    @@tables = [] of {String, Reading}

    # Registers the audit of *table*: the generated method that checks up
    # to a batch of rows after a rowid and returns the last one it read.
    def self.table(table : String, &reading : Reader, Int64, Int32, Database::Audit -> Int64?) : Nil
      @@tables.reject!(&.[0].==(table))
      @@tables << {table, reading}
    end

    # The tables with an audit, by name.
    def self.tables : Array(String)
      @@tables.map(&.[0]).sort!
    end

    # What one column's values showed: how many failed to parse per
    # reason, how many are not canonical, and the first row IDs of each.
    class Column
      getter table : String
      getter column : String
      getter type : String
      getter invalid = {} of String => Int64
      getter invalid_rows = [] of Int64
      getter noncanonical = 0_i64
      getter noncanonical_rows = [] of Int64
      # For an encrypted column or a blind index: how many values each root
      # key wrote, by key ID, read from the header without decrypting. A
      # key still listed here is not safe to retire (`docs/keys.md`).
      getter keys = {} of UInt32 => Int64
      # For a JSON document (docs/composites.md): how many objects of each
      # composite each version wrote, "Billing::Address version 1". A
      # frozen type whose version is still listed is not safe to delete.
      getter versions = {} of String => Int64

      def initialize(@table : String, @column : String, @type : String)
      end

      def encrypted? : Bool
        @type.starts_with?("Punch::Encrypted(")
      end

      def blind_index? : Bool
        @type.starts_with?("Punch::BlindIndex.")
      end

      # :nodoc:
      def key!(id : UInt32) : Nil
        @keys[id] = (@keys[id]? || 0_i64) + 1
      end

      def invalid_count : Int64
        @invalid.values.sum(0_i64)
      end

      # :nodoc:
      def invalid!(reason : String, row : Int64) : Nil
        @invalid[reason] = (@invalid[reason]? || 0_i64) + 1
        @invalid_rows << row if @invalid_rows.size < SAMPLE
      end

      # :nodoc:
      def noncanonical!(row : Int64) : Nil
        @noncanonical += 1
        @noncanonical_rows << row if @noncanonical_rows.size < SAMPLE
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "table", @table
          json.field "column", @column
          json.field "type", @type
          json.field "invalid", @invalid
          json.field "invalid_rows", @invalid_rows
          json.field "noncanonical", @noncanonical
          json.field "noncanonical_rows", @noncanonical_rows
          json.field "keys", @keys.transform_keys(&.to_s) if encrypted? || blind_index?
          json.field "versions", @versions unless @versions.empty?
        end
      end
    end

    # Rows read per table.
    # A column converted from plaintext: how many values are only in the
    # plaintext column, and how many plaintext copies are left.
    class Conversion
      include JSON::Serializable

      getter table : String
      getter column : String
      getter plaintext_column : String
      property unconverted = 0_i64
      property plaintext = 0_i64

      def initialize(@table : String, @column : String, @plaintext_column : String)
      end
    end

    getter rows = {} of String => Int64
    @conversions = {} of {String, String} => Conversion
    getter started_at : Time
    getter finished_at : Time? = nil
    @columns = {} of {String, String} => Column

    def initialize(@started_at : Time = Time.utc)
    end

    # The columns with a finding, by table and column.
    def findings : Array(Column)
      @columns.values.select { |column| column.invalid_count > 0 || column.noncanonical > 0 }.sort_by! { |column| {column.table, column.column} }
    end

    # The encrypted columns and blind indexes, by table and column, with
    # their values per key.
    def encrypted : Array(Column)
      @columns.values.select { |column| column.encrypted? || column.blind_index? }.sort_by! { |column| {column.table, column.column} }
    end

    # Whether every value parsed. Values that are not canonical do not
    # count against it.
    def clean? : Bool
      findings.all?(&.invalid_count.zero?)
    end

    # Reads every registered table of *database* in batches of *batch*
    # rows, each in its own read transaction, with a span per table.
    # *between* runs after each batch: the nightly job yields there, so
    # requests go first.
    def self.run(database : Database, batch : Int32 = BATCH, now : Time = Time.utc, between : Proc(Nil)? = nil) : Database::Audit
      audit = Database::Audit.new(now)
      @@tables.sort_by(&.[0]).each do |table, reading|
        Trace.span("punch.audit.table") do |span|
          span.set("db.collection.name", table)
          after = 0_i64
          loop do
            last = database.read { |reader| reading.call(reader, after, batch, audit) }
            break unless last
            after = last
            between.try(&.call)
          end
          span.set("punch.audit.rows", audit.rows[table]? || 0_i64)
        end
      end
      audit.finish(Time.utc)
    end

    # :nodoc:
    def finish(at : Time) : self
      @finished_at = at
      self
    end

    # Checks one stored value: *raw* as read, `nil` for SQL NULL, which a
    # nullable column allows (the schema says whether it may be NULL).
    def check(type : T.class, raw : R?, table : String, column : String, row : Int64) : Nil forall T, R
      entry(type, table, column) # listed even when every value is NULL
      return if raw.nil?

      {% if T.name(generic_args: false) == "Punch::Encrypted" %}
        entry(type, table, column).key!(IO::ByteFormat::BigEndian.decode(UInt32, raw[1, 4])) if raw.size > 4
        plain = Stored.encryptor(table, column).decrypt(raw)
        {% inner = T.type_vars.first %}
        {% if inner < ::Punch::Composite || (inner.union? && inner.union_types.all? { |member| member < ::Punch::Composite }) %}
          plain.try { |bytes| versions({{ inner.stringify.gsub(::Punch::NAME_STARTS, "::").id }}, String.new(bytes), entry(type, table, column)) }
        {% end %}
        value = Stored.load(T, raw, table, column, row)
        canonical = Stored.plaintext(Stored.dump(value.unwrap)) == plain
        entry(type, table, column).noncanonical!(row) unless canonical
      {% else %}
        {% if T < ::Punch::Composite || (T.union? && T.union_types.all? { |member| member < ::Punch::Composite }) %}
          versions(T, raw, entry(type, table, column))
        {% end %}
        value = Stored.load(T, raw, table, column, row)
        canonical = {% if T == R || T == Bool %} true {% else %} Stored.dump(value) == raw {% end %}
        entry(type, table, column).noncanonical!(row) unless canonical
      {% end %}
    rescue ex : Database::RowError
      entry(type, table, column).invalid!(ex.reason, row)
    end

    # Counts a document's objects per composite and version, also of one
    # that does not parse (a newer release's, or one written by hand).
    private def versions(type : T.class, text : String, found : Column) : Nil forall T
      Composite.versions(T, JSON.parse(text), found.versions)
    rescue JSON::ParseException
    end

    # Checks the blind index value *index* against the ciphertext *source*
    # of its encrypted column in the same row: present exactly
    # when the value is, and the hash of the value's stored form under the
    # key it names, which is what a lookup computes. Otherwise it is
    # `index_missing` or `index_stale`, and lookups miss the row. A value
    # that does not decrypt is the encrypted column's finding, not this
    # one's. Values are counted per key, like an encrypted column's.
    def check_index(type : Encrypted(T).class, index : Bytes?, source : Bytes?, table : String, column : String, source_column : String, row : Int64) : Nil forall T
      found = @columns[{table, column}] ||= Column.new(table, column, "Punch::BlindIndex.of(:#{source_column})")
      index.try { |value| KeyRing::BlindIndex.key_id(value).try { |id| found.key!(id) } }
      unless source
        found.invalid!("index_stale", row) if index
        return
      end
      return found.invalid!("index_missing", row) unless index

      value = begin
        Stored.load(type, source, table, source_column, row)
      rescue Database::RowError
        return
      end
      found.invalid!("index_stale", row) unless Stored.index(table, column).matches?(index, Stored.plaintext(Stored.dump(value.unwrap)))
    end

    # Counts, for a column converted from plaintext (`from(:email)`),
    # whether this row's value is still only in plaintext and whether a
    # plaintext copy is left.
    def conversion(table : String, column : String, plain_column : String, unconverted : Bool, plaintext : Bool) : Nil
      key = {table, column}
      found = @conversions[key] ||= Conversion.new(table, column, plain_column)
      found.unconverted += 1 if unconverted
      found.plaintext += 1 if plaintext
    end

    # Counts a row read from *table*.
    def row(table : String) : Nil
      @rows[table] = (@rows[table]? || 0_i64) + 1
    end

    private def entry(type : T.class, table : String, column : String) : Column forall T
      @columns[{table, column}] ||= Column.new(table, column, T.name)
    end

    # One line per encrypted column and blind index: its values per key.
    def key_lines : Array(String)
      encrypted.map do |found|
        counts = found.keys.to_a.sort_by! { |id, _| -id.to_i64 }.join(", ") { |id, count| "#{count} under key #{id}" }
        "#{found.table}.#{found.column}: #{found.blind_index? ? "blind index" : "encrypted"}, #{counts.presence || "no values"}"
      end
    end

    # The document columns, by table and column, with their objects per
    # composite and version.
    def documents : Array(Column)
      @columns.values.reject(&.versions.empty?).sort_by! { |column| {column.table, column.column} }
    end

    # One line per document column: its objects per composite and version.
    def version_lines : Array(String)
      documents.map do |found|
        "#{found.table}.#{found.column}: #{found.versions.to_a.sort!.join(", ") { |name, count| "#{count} #{name}" }}"
      end
    end

    # The columns being converted from plaintext, by table and column.
    def conversions : Array(Conversion)
      @conversions.values.sort_by! { |found| {found.table, found.column} }
    end

    # One line per column being converted: what is left in plaintext.
    def conversion_lines : Array(String)
      conversions.map do |found|
        "#{found.table}.#{found.column}: converting from #{found.plaintext_column}, #{found.unconverted} only in plaintext, #{found.plaintext} plaintext #{found.plaintext == 1 ? "copy" : "copies"} left"
      end
    end

    # One line per finding, without values.
    def messages : Array(String)
      findings.flat_map do |found|
        lines = [] of String
        if found.invalid_count > 0
          reasons = found.invalid.join(", ") { |reason, count| "#{count} #{reason}" }
          one = found.invalid_count == 1
          what = if found.blind_index?
                   "#{one ? "value is" : "values are"} not the hash of #{found.type.lchop("Punch::BlindIndex.of(:").rchop(")")}"
                 else
                   "#{one ? "value does" : "values do"} not parse as #{found.type}"
                 end
          lines << "#{found.table}.#{found.column}: #{found.invalid_count} #{what} (#{reasons}); rows #{found.invalid_rows.join(", ")}#{found.invalid_count > SAMPLE ? ", …" : ""}"
        end
        if found.noncanonical > 0
          lines << "#{found.table}.#{found.column}: #{found.noncanonical} #{found.noncanonical == 1 ? "value is" : "values are"} not in #{found.type}'s stored form; rows #{found.noncanonical_rows.join(", ")}#{found.noncanonical > SAMPLE ? ", …" : ""}"
        end
        lines
      end
    end

    def to_json(json : JSON::Builder) : Nil
      json.object do
        json.field "started_at", @started_at.to_rfc3339
        json.field "finished_at", @finished_at.try(&.to_rfc3339)
        json.field "clean", clean?
        json.field "rows", @rows
        json.field "findings", findings
        json.field "encrypted", encrypted
        json.field "conversions", conversions
        json.field "documents", documents
      end
    end

    # A column whose values do not parse, recorded by `Database::Audit::Run` so that
    # it shows among the ops console's errors, one group per column.
    class Unparseable < Exception
    end

    # Audits the primary database every night at 03:00 UTC, at the lowest
    # priority, yielding after every batch. Findings go into the job's
    # wide event (`punch.audit.*`, shown with the run in the ops console),
    # and each column that does not parse is recorded as an
    # `Database::Audit::Unparseable` error.
    @[Punch::Job::Recurring(cron: "0 3 * * *")]
    @[Punch::Job::Options(priority: -100)]
    struct Run
      include Punch::Job

      def initialize
      end

      def perform(job : Punch::Job::Context) : Punch::Job::Result
        audit = job.audit
        event = Trace.event
        if event.recording?
          event.set("punch.audit.rows", audit.rows.values.sum(0_i64))
          event.set("punch.audit.tables", audit.rows.size.to_i64)
          event.set("punch.audit.invalid", audit.findings.sum(0_i64, &.invalid_count))
          event.set("punch.audit.noncanonical", audit.findings.sum(0_i64, &.noncanonical))
          event.set("punch.audit.findings", audit.messages.join('\n')) unless audit.findings.empty?
        end
        audit.findings.each do |found|
          next if found.invalid_count.zero?
          event.record_exception(Unparseable.new(audit.messages.find!(&.starts_with?("#{found.table}.#{found.column}: "))), "punch.audit #{found.table}.#{found.column}")
        end
        nil
      end
    end
  end

  struct Job::Context
    # Audits the primary database (`Punch::Database::Audit`), yielding to other
    # fibers after every batch.
    # :nodoc:
    def audit : Database::Audit
      Database::Audit.run(@database, now: Time.utc, between: -> { Fiber.yield })
    end
  end
end
