module Punch::QueryGen
  # The tables of `db/schema.sql`, read from a database it was loaded into,
  # with the domain types from the mapping file applied.
  class Schema
    class Column
      getter name : String
      getter declared : String
      # `nil` when the declared type says nothing (`ANY`, or none at all).
      property type : Type?
      # Position in the primary key, from 1; 0 when not part of it.
      getter pk : Int32
      getter default : String?
      getter? generated : Bool
      # For a blind index, the encrypted column it hashes.
      property source : String? = nil
      # For a plaintext column being converted, the encrypted column it
      # becomes, and whether generated code leaves it out already
      # (`from(:column, clear: true)`): then only the conversion clears it.
      property plaintext_of : String? = nil
      property? cleared = false
      # For a column of a group (`{type: Composite, columns: "prefix_"}`):
      # the group, and the fields that lead to it in the composite
      # (`["geo", "lat"]` for `address_geo_lat`).
      property group : Group? = nil
      property member = [] of String
      # For a generated column, its expression (`AS (…)`).
      property expression : String? = nil

      def initialize(@name, @declared, @type, @pk, @default, @generated)
      end
    end

    # A unique index, a `UNIQUE` or `PRIMARY KEY` constraint, or the rowid:
    # what a write can violate and SQLite names in its message.
    class Unique
      # The index, or `rowid` for an `INTEGER PRIMARY KEY`.
      getter name : String
      # Key columns as declared; empty when the key has an expression.
      getter columns : Array(String)
      # Every column the index reads: its key and its `WHERE`.
      getter referenced : Array(String)
      getter? rowid : Bool
      # SQLite's message when the constraint fails: `UNIQUE constraint
      # failed: customers.email`, or `… index 'name'` for expressions.
      getter message : String
      # The Crystal struct, set by the generator: `EmailTaken`.
      property type_name : String = ""
      # The input field it belongs to by default, `nil` for the whole input.
      property field : String? = nil
      # For a rule a trigger enforces (`Punch.violation`): its code, raised
      # as `RAISE(ABORT, 'punch:<code>')`, the status it answers with, and
      # the writes that fire the triggers raising it.
      property code : String? = nil
      property status : Int32 = 422
      property events = Set(String).new

      def initialize(@name, @columns, @referenced, @rowid, @message)
      end

      # A rule raised by the triggers *triggers*, all on one table.
      def self.trigger(code : String, triggers : Array(Trigger)) : Unique
        any_column = triggers.any? { |trigger| trigger.event == "UPDATE" && trigger.columns.empty? }
        columns = any_column ? [] of String : triggers.flat_map(&.columns).uniq!
        unique = new(triggers.join(", ", &.name), [] of String, columns, false, "#{Trigger::PREFIX}#{code}")
        unique.code = code
        unique.events = triggers.map(&.event).to_set
        unique
      end

      def trigger? : Bool
        !code.nil?
      end

      # `customers.email`, or `customers: index` for expressions; for a
      # trigger's rule, `invoices: trigger invoices_locked`.
      def constraint(table : String) : String
        return "#{table}: trigger #{name}" if trigger?

        columns.empty? ? "#{table}: #{name}" : columns.join(", ") { |column| "#{table}.#{column}" }
      end

      # Whether a write of *event* fires it: for an `UPDATE`, one that sets
      # a column of its `UPDATE OF` list, or any when it has none.
      def fired_by?(event : String, set : Set(String) = Set(String).new) : Bool
        return false unless events.includes?(event)

        event != "UPDATE" || referenced.empty? || referenced.any? { |column| set.includes?(column) }
      end
    end

    # A trigger, and the codes it raises for Punch (`'punch:<code>'`).
    class Trigger
      # What a message names a Punch code with.
      PREFIX = "punch:"

      getter name : String
      getter table : String
      # `INSERT`, `UPDATE`, or `DELETE`.
      getter event : String
      # The `UPDATE OF` columns; empty for any.
      getter columns : Array(String)
      # Codes raised with `RAISE(ABORT, 'punch:…')`.
      getter codes : Array(String)
      # Codes raised with `ROLLBACK`, `FAIL`, or `IGNORE`, which cannot be values.
      getter refused : Array(String)

      def initialize(@name, @table, @event, @columns, @codes, @refused)
      end

      # Reads one from its `CREATE TRIGGER` statement.
      def self.parse(name : String, table : String, sql : String) : Trigger
        tokens = SQL.tokenize(sql)
        on = tokens.index(&.keyword?("ON")) || tokens.size
        at = (0...on).find { |i| tokens[i].keyword?("INSERT", "UPDATE", "DELETE") } || 0
        event = tokens[at].text.upcase
        columns = [] of String
        if event == "UPDATE" && tokens[at + 1]?.try(&.keyword?("OF"))
          columns = tokens[(at + 2)...on].select(&.kind.ident?).map(&.text)
        end
        codes, refused = [] of String, [] of String
        tokens.each_with_index do |token, i|
          next unless token.keyword?("RAISE") && tokens[i + 1]?.try(&.punct?("("))
          kind, message = tokens[i + 2]?, tokens[i + 4]?
          next unless kind && message && message.kind.string?
          text = message.text[1...-1].gsub("''", "'")
          next unless text.starts_with?(PREFIX)
          (kind.keyword?("ABORT") ? codes : refused) << text.lchop(PREFIX)
        end
        new(name, table, event, columns, codes, refused)
      end
    end

    # A composite stored in prefixed columns (docs/composites.md): the
    # record's field, the composite, the prefix, whether the whole group
    # may be absent, and its columns in the order of the composite's
    # fields.
    class Group
      getter field : String
      getter composite : Composite
      getter prefix : String
      getter? nilable : Bool
      getter columns = [] of Column

      def initialize(@field : String, @composite : Composite, @prefix : String, @nilable : Bool)
      end
    end

    class Table
      getter name : String
      getter columns : Array(Column)
      getter uniques = [] of Unique
      # Columns that reference another table.
      getter foreign_keys = Set(String).new
      getter? strict : Bool
      getter? without_rowid : Bool
      # Whether the rowid is `AUTOINCREMENT`: SQLite then never hands out
      # the rowid of a deleted row again.
      property? autoincrement = false
      # The module from the mapping file, which receives `Record` and `Table`.
      property mod : String? = nil
      # Where the mapping file maps it.
      property mapped_at : Location? = nil
      # The mapping file, beside which its record is generated.
      property mapped_in : String? = nil
      # The hand-written file that adds behaviour to its record.
      property behaviour : String? = nil
      # Every index, unique or not, with the columns it reads.
      getter indexes = [] of {String, Array(String)}
      # The columns a `CHECK` constraint reads, and each constraint's text.
      getter checked = Set(String).new
      getter checks = [] of String
      # Groups of columns that hold a composite, by record field.
      getter groups = [] of Group

      def initialize(@name, @columns, @strict, @without_rowid)
      end

      def column(name : String) : Column?
        columns.find { |column| column.name.compare(name, case_insensitive: true) == 0 }
      end

      # The columns of its record and of the generated SQL: all but a
      # plaintext column that is being cleared, which a later release drops.
      def record_columns : Array(Column)
        columns.reject(&.cleared?)
      end

      def primary_key : Array(Column)
        columns.select(&.pk.positive?).sort_by!(&.pk)
      end

      # The column that is the rowid (`INTEGER PRIMARY KEY`), if any.
      def rowid : Column?
        key = primary_key
        return if without_rowid? || key.size != 1

        key.first.declared.compare("INTEGER", case_insensitive: true) == 0 ? key.first : nil
      end
    end

    getter tables = {} of String => Table
    # Every trigger that raises a Punch code.
    getter triggers = [] of Trigger
    # Every composite of the app, by name (docs/composites.md).
    property composites = {} of String => Composite
    # How the app's domain primitives are stored, as far as the generator
    # can see (`Primitives`); read when a typed path ends at one.
    property primitives : Primitives? = nil

    def initialize(database : Database)
      database.read do |reader|
        names = reader.query_all(<<-SQL, Migrations::TABLE, Database::CollationVersions::TABLE) { |row| {row.read(String), row.read(Int64) == 1, row.read(Int64) == 1} }
          SELECT name, strict, wr FROM pragma_table_list
          WHERE schema = 'main' AND type IN ('table', 'virtual') AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\' AND name NOT IN (?, ?)
          ORDER BY name
          SQL
        names.each do |name, strict, without_rowid|
          columns = reader.query_all("SELECT name, type, \"notnull\", dflt_value, pk, hidden FROM pragma_table_xinfo(?) ORDER BY cid", name) do |row|
            column_name, declared, not_null = row.read(String), row.read(String), row.read(Int64) == 1
            default, key, hidden = row.read(String?), row.read(Int64).to_i32, row.read(Int64)
            {column_name, declared, not_null, default, key, hidden}
          end
          table = Table.new(name, [] of Column, strict, without_rowid)
          rowid_key = !without_rowid && columns.count { |column| column[4] > 0 } == 1
          columns.each do |column_name, declared, not_null, default, key, hidden|
            next if hidden == 1 # hidden columns of virtual tables
            # An INTEGER PRIMARY KEY is the rowid and never NULL.
            rowid = rowid_key && key > 0 && declared.compare("INTEGER", case_insensitive: true) == 0
            type = QueryGen.stored_type(declared).try { |stored| Type.new(stored, nil, !(not_null || rowid)) }
            table.columns << Column.new(column_name, declared, type, key, default, hidden >= 2)
          end
          sql = reader.query_one?("SELECT sql FROM sqlite_schema WHERE type = 'table' AND name = ?", name) { |row| row.read(String?) }
          table.autoincrement = !!sql.try(&.gsub(/--[^\n]*/, "").matches?(/\bAUTOINCREMENT\b/i))
          @tables[name.downcase] = table
          read_uniques(reader, table)
          read_indexes(reader, table)
        end
        reader.query_all("SELECT name, tbl_name, sql FROM sqlite_schema WHERE type = 'trigger' ORDER BY name") { |row| {row.read(String), row.read(String), row.read(String)} }.each do |name, table, sql|
          trigger = Trigger.parse(name, table, sql)
          @triggers << trigger unless trigger.codes.empty? && trigger.refused.empty?
        end
      end
    end

    private def read_uniques(reader : Reader, table : Table) : Nil
      reader.query_all("SELECT \"from\" FROM pragma_foreign_key_list(?)", table.name) { |row| row.read(String) }.each do |column|
        table.foreign_keys << column
      end
      if rowid = table.rowid
        table.uniques << Unique.new("rowid", [rowid.name], [rowid.name], true, "UNIQUE constraint failed: #{table.name}.#{rowid.name}")
      end
      indexes = reader.query_all("SELECT name, partial FROM pragma_index_list(?) WHERE \"unique\" = 1 ORDER BY name", table.name) { |row| {row.read(String), row.read(Int64) == 1} }
      full = [] of Array(String)
      full << [rowid.name] if rowid
      indexes.each do |index, partial|
        keys = reader.query_all("SELECT name FROM pragma_index_xinfo(?) WHERE key = 1 ORDER BY seqno", index) { |row| row.read(String?) }
        sql = reader.query_one?("SELECT sql FROM sqlite_schema WHERE type = 'index' AND name = ?", index) { |row| row.read(String?) }.try(&.itself)
        if keys.all?
          columns = keys.compact
          full << columns unless partial
          message = "UNIQUE constraint failed: #{columns.join(", ") { |column| "#{table.name}.#{column}" }}"
        else
          columns = [] of String
          message = "UNIQUE constraint failed: index '#{index}'"
        end
        table.uniques << Unique.new(index, columns, (columns + referenced(table, sql)).uniq, false, message)
      end
      # A key that contains a smaller full key cannot be violated:
      # `UNIQUE (owner_id, id)`, there for a composite foreign key, is
      # unique through `id` alone.
      table.uniques.reject! do |unique|
        !unique.rowid? && full.any? { |key| key.size < unique.columns.size && key.all? { |column| unique.columns.includes?(column) } }
      end
    end

    # Every index of *table* with the columns it reads, and the columns
    # its `CHECK` constraints read: what an encrypted column must stay out
    # of.
    private def read_indexes(reader : Reader, table : Table) : Nil
      names = reader.query_all("SELECT name FROM pragma_index_list(?) ORDER BY name", table.name) { |row| row.read(String) }
      names.each do |index|
        keys = reader.query_all("SELECT name FROM pragma_index_xinfo(?) WHERE key = 1 ORDER BY seqno", index) { |row| row.read(String?) }
        sql = reader.query_one?("SELECT sql FROM sqlite_schema WHERE type = 'index' AND name = ?", index) { |row| row.read(String?) }.try(&.itself)
        table.indexes << {index, (keys.compact + referenced(table, sql)).uniq}
      end
      sql = reader.query_one?("SELECT sql FROM sqlite_schema WHERE type = 'table' AND name = ?", table.name) { |row| row.read(String?) }.try(&.itself) || return
      tokens = SQL.tokenize(sql)
      tokens.each_with_index do |token, i|
        next unless token.keyword?("CHECK") && tokens[i + 1]?.try(&.punct?("("))
        close = SQL.matching(tokens, i + 1)
        tokens[i + 2...close].each do |inner|
          table.column(inner.text).try { |column| table.checked << column.name } if inner.kind.ident?
        end
        table.checks << sql[tokens[i + 2].offset...tokens[close].offset] if close > i + 2
      end
      read_generated(table, tokens, sql)
    end

    # The expression of each generated column: `name TYPE … AS (expr)`,
    # for typed paths over a document (docs/composites.md).
    private def read_generated(table : Table, tokens : Array(SQL::Token), sql : String) : Nil
      table.columns.select(&.generated?).each do |column|
        start = tokens.index { |token| token.kind.ident? && token.text.compare(column.name, case_insensitive: true) == 0 } || next
        open = (start...tokens.size).find { |i| tokens[i].keyword?("AS") && tokens[i + 1]?.try(&.punct?("(")) } || next
        close = SQL.matching(tokens, open + 1)
        column.expression = sql[tokens[open + 2].offset...tokens[close].offset] if close > open + 2
      end
    end

    # The table's columns named in a `CREATE INDEX` after its `ON`: in key
    # expressions and the `WHERE` of a partial index.
    private def referenced(table : Table, sql : String?) : Array(String)
      tokens = SQL.tokenize(sql || return [] of String)
      start = tokens.index(&.keyword?("ON")) || return [] of String
      tokens[start + 2..].compact_map { |token| table.column(token.text).try(&.name) if token.kind.ident? }
    end

    def table(name : String) : Table?
      @tables[name.downcase]?
    end

    def column(table : String, name : String) : Column?
      table(table).try(&.column(name))
    end
  end
end
