require "../migrations"
require "../query_gen/sql"

module Punch::Migrations
  # What a statement costs on a large table, while it holds the database's
  # single write lock.
  enum Cost
    # Changes the schema only; the same on an empty table and a large one.
    Instant
    # Reads every row of a table once (building an index, checking a
    # constraint, writing data), but keeps the table.
    Scan
    # Writes a new copy of every row: SQLite's 12-step procedure (create,
    # copy, drop, rename) or `DROP COLUMN`. Needs `-- rebuild: <table>`.
    Rebuild
  end

  # Sorts every statement of a set of migrations into instant, scan, or
  # rebuild. The migrations are replayed from the first in an empty
  # in-memory database, one statement at a time, and the schema before and
  # after each statement tells what it created, dropped, or renamed; the
  # statement's own words tell the rest.
  #
  # Rows are counted as present in every table that existed before the
  # migration, and in a table the migration filled from a query: that is
  # where a statement's cost grows with the table. A table the migration
  # creates is empty, so indexing or altering it is instant.
  #
  # A rebuild must be acknowledged in the migration file, naming the
  # table: `-- rebuild: customers`. An acknowledgement of a table the
  # migration does not rebuild is an error too, so the line stays true.
  module Costs
    ACKNOWLEDGEMENT = /\A[ \t]*--[ \t]*rebuild:[ \t]*(.+)\z/i

    record Statement, line : Int32, sql : String, cost : Cost, table : String?, reason : String do
      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "line", line
          json.field "sql", sql
          json.field "cost", cost.to_s.downcase
          json.field "table", table
          json.field "reason", reason
        end
      end
    end

    # One migration's statements and what it rebuilds.
    struct Report
      getter migration : Migrations::Migration
      getter statements : Array(Statement)
      # The tables the migration rebuilds, in the order of their first
      # rebuilding statement.
      getter rebuilds : Array(String)
      # The tables named by `-- rebuild:` lines.
      getter acknowledged : Array(String)

      def initialize(@migration : Migrations::Migration, @statements : Array(Statement), @rebuilds : Array(String), @acknowledged : Array(String))
      end

      # The most expensive statement's cost.
      def cost : Cost
        @statements.max_of?(&.cost) || Cost::Instant
      end

      # What makes the migration fail the check: rebuilds nobody
      # acknowledged, and acknowledgements of tables it does not rebuild.
      def problems : Array(String)
        problems = [] of String
        (@rebuilds - @acknowledged).each do |table|
          statement = @statements.find { |candidate| candidate.cost.rebuild? && candidate.table.try(&.downcase) == table }
          location = statement ? "#{@migration.source}:#{statement.line}" : @migration.source
          problems << "#{location}: rebuilds #{table}: #{statement.try(&.reason) || "copies every row"}. " \
                      "That holds the write lock for as long as copying the table takes. Prefer a change that keeps the table " \
                      "(a unique index, a trigger, ALTER COLUMN ... SET NOT NULL, ADD CHECK; lib/punch/docs/migrations.md), " \
                      "or acknowledge it with a line '-- rebuild: #{table}' in the file."
        end
        (@acknowledged - @rebuilds).each do |table|
          problems << "#{@migration.source}: '-- rebuild: #{table}' names a table the migration does not rebuild; remove the line."
        end
        problems
      end

      def to_json(json : JSON::Builder) : Nil
        json.object { fields(json) }
      end

      # The report's fields, for an object that adds its own.
      def fields(json : JSON::Builder) : Nil
        json.field "version", @migration.version
        json.field "name", @migration.name
        json.field "file", @migration.source
        json.field "cost", cost.to_s.downcase
        json.field "rebuilds", @rebuilds
        json.field "acknowledged", @acknowledged
        json.field "problems", problems
        json.field "statements", @statements
      end
    end

    # One entry of `sqlite_schema`.
    private record Entry, type : String, name : String, table : String, rootpage : Int64

    # The schema at one point: entries by lowercase name, and the STRICT
    # tables.
    private record Snapshot, entries : Hash(String, Entry), strict : Set(String)

    # Classifies every migration in *migrations*, replaying all of them.
    # Raises `Migrations::Failed` for one that does not run.
    def self.classify(migrations : Enumerable(Migrations::Migration)) : Array(Report)
      database = Database.memory(name: "costs", config: Database::Config.new(readers: 1))
      begin
        database.with_writer_connection do |connection|
          connection.exec("PRAGMA foreign_keys = OFF")
          Migrations.sorted(migrations).map { |migration| classify(connection, migration) }
        end
      ensure
        database.close
      end
    end

    # The tables a migration file acknowledges rebuilding.
    def self.acknowledged(sql : String) : Array(String)
      sql.lines.compact_map { |line| ACKNOWLEDGEMENT.match(line).try(&.[1]) }
        .flat_map(&.split(/[\s,]+/)).reject(&.empty?).map(&.downcase).uniq!
    end

    private def self.classify(connection : Database::Driver::Connection, migration : Migrations::Migration) : Report
      starts = [] of Int32
      snapshots = [snapshot(connection)]
      connection.exec("BEGIN")
      begin
        # A migration is a `.sql` file of the app's, replayed in memory.
        connection.exec_script(migration.sql) do |start| # ameba:disable Punch/SQLText
          starts << start
          snapshots << snapshot(connection)
        end
      rescue ex : Database::ScriptError
        raise Failed.new(migration, ex.detail, ex.line, ex.column, cause: ex)
      ensure
        connection.exec("COMMIT") if connection.in_transaction?
      end
      Classifier.new(migration, starts, snapshots).report
    end

    private def self.snapshot(connection : Database::Driver::Connection) : Snapshot
      entries = {} of String => Entry
      connection.query("SELECT type, name, tbl_name, rootpage FROM sqlite_schema WHERE name NOT LIKE 'sqlite\\_%' ESCAPE '\\'", Tuple.new) do |row|
        entry = Entry.new(row.read(String), row.read(String), row.read(String), row.read(Int64?) || 0_i64)
        entries[entry.name.downcase] = entry
      end
      strict = Set(String).new
      connection.query("SELECT name FROM pragma_table_list WHERE schema = 'main' AND strict = 1", Tuple.new) do |row|
        strict << row.read(String).downcase
      end
      Snapshot.new(entries, strict)
    end

    # Walks one migration's statements with the schema around each.
    private class Classifier
      alias Token = QueryGen::SQL::Token

      @statements = [] of Statement
      # Tables that hold rows at this point, by lowercase name: every
      # table from before the migration, and those filled from a query.
      @full : Set(String)
      # Tables from before the migration that a statement dropped.
      @dropped = Set(String).new
      # Indexes of rebuild steps, by the rebuilt table, filled in by
      # `rebuilds` at the end: the copy into the new table, the drop, the
      # rename.
      @copies = {} of String => Array(Int32)
      @renames = {} of String => Int32
      @drops = {} of String => Int32

      def initialize(@migration : Migrations::Migration, @starts : Array(Int32), @snapshots : Array(Snapshot))
        @before = @snapshots.first
        @full = tables(@before).to_set
      end

      def report : Report
        @starts.each_with_index do |start, index|
          stop = @starts[index + 1]? || @migration.sql.bytesize
          text = @migration.sql.byte_slice(start, stop - start)
          tokens = QueryGen::SQL.tokenize(text)
          next if tokens.empty?
          line = @migration.sql.byte_slice(0, start).count('\n') + 1
          cost, table, reason = statement(tokens, @snapshots[index], @snapshots[index + 1], index)
          @statements << Statement.new(line, summary(text), cost, table, reason)
        end
        Report.new(@migration, @statements, rebuilds, Costs.acknowledged(@migration.sql))
      end

      # The first line of a statement, shortened.
      private def summary(text : String) : String
        first = text.strip.lines.first? || ""
        first = first.rstrip(';').rstrip
        first.size > 72 ? "#{first[0, 71]}…" : first
      end

      private def tables(snapshot : Snapshot) : Array(String)
        snapshot.entries.compact_map { |key, entry| key if entry.type == "table" }
      end

      # Tables from before the migration that exist again at its end, after
      # a statement dropped them: rebuilt. Marks their steps, and returns
      # them with the tables rewritten by `DROP COLUMN`.
      private def rebuilds : Array(String)
        after = @snapshots.last.entries
        replaced = @dropped.select { |table| after[table]?.try(&.type) == "table" }.to_set
        replaced.each do |table|
          name = after[table].name
          steps = (@copies[table]? || [] of Int32).map { |index| {index, "copies every row of #{name} into its new table"} }
          @drops[table]?.try { |index| steps << {index, "drops #{name}, which a new table replaces"} }
          @renames[table]?.try { |index| steps << {index, "renames the new table to #{name}"} }
          steps.each do |index, reason|
            statement = @statements[index]
            @statements[index] = Statement.new(statement.line, statement.sql, Cost::Rebuild, name, reason)
          end
        end
        @statements.select(&.cost.rebuild?).compact_map(&.table.try(&.downcase)).uniq!
      end

      private def full?(table : String) : Bool
        @full.includes?(table.downcase)
      end

      private def name_of(table : String, snapshot : Snapshot) : String
        snapshot.entries[table.downcase]?.try(&.name) || table
      end

      # The cost, table, and reason of one statement.
      private def statement(tokens : Array(Token), before : Snapshot, after : Snapshot, index : Int32) : {Cost, String?, String}
        tokens = tokens.reject(&.punct?(";"))
        head = tokens.first

        case
        when head.keyword?("CREATE") then create(tokens, before, after)
        when head.keyword?("DROP")   then drop(before, after, index)
        when head.keyword?("ALTER")  then alter(tokens, before, after, index)
        when head.keyword?("INSERT", "REPLACE", "UPDATE", "DELETE", "WITH")
          write(tokens, before, index)
        when head.keyword?("REINDEX") then {Cost::Scan, nil, "rebuilds every index it names"}
        when head.keyword?("ANALYZE") then {Cost::Scan, nil, "reads the indexes it names"}
        else                               {Cost::Scan, nil, "Punch does not know what #{head.text.upcase} costs; counted as a scan"}
        end
      end

      private def created(before : Snapshot, after : Snapshot) : Array(Entry)
        after.entries.compact_map { |key, entry| entry unless before.entries.has_key?(key) }
      end

      private def create(tokens : Array(Token), before : Snapshot, after : Snapshot) : {Cost, String?, String}
        entry = created(before, after).first? || return {Cost::Instant, nil, "creates nothing new (IF NOT EXISTS)"}

        case entry.type
        when "index"
          return {Cost::Instant, entry.table, "indexes a table this migration created empty"} unless full?(entry.table)

          {Cost::Scan, entry.table, "builds the index from every row"}
        when "table"
          if tokens.any?(&.keyword?("SELECT")) && !tokens.any?(&.keyword?("VIRTUAL"))
            @full << entry.name.downcase
            return {Cost::Scan, entry.name, "copies the rows of a query"}
          end
          {Cost::Instant, entry.name, "creates an empty table"}
        else
          {Cost::Instant, entry.table, "creates a #{entry.type}"}
        end
      end

      private def drop(before : Snapshot, after : Snapshot, index : Int32) : {Cost, String?, String}
        gone = before.entries.compact_map { |key, entry| entry unless after.entries.has_key?(key) }
        table = gone.find(&.type.==("table"))
        unless table
          entry = gone.first? || return {Cost::Instant, nil, "drops nothing (IF EXISTS)"}
          return {Cost::Scan, entry.table, "frees every page of the index"} if entry.type == "index" && full?(entry.table)

          return {Cost::Instant, entry.table, "drops a #{entry.type}"}
        end
        key = table.name.downcase
        if tables(@before).includes?(key) && !@dropped.includes?(key)
          @dropped << key
          @drops[key] = index
        end
        return {Cost::Instant, table.name, "drops a table this migration created empty"} unless full?(key)

        @full.delete(key)
        {Cost::Scan, table.name, "frees every page of the table"}
      end

      # The table an `ALTER TABLE` names, after an optional schema.
      private def target(tokens : Array(Token), at : Int32) : {String, Int32}
        return {tokens[at + 2].text, at + 3} if tokens[at + 1]?.try(&.punct?("."))

        {tokens[at].text, at + 1}
      end

      private def alter(tokens : Array(Token), before : Snapshot, after : Snapshot, index : Int32) : {Cost, String?, String}
        table, at = target(tokens, 2)
        name = name_of(table, before)
        words = tokens[at..]
        verb = words.first
        return rename(table, name_of(words[2].text, after), index) if verb.keyword?("RENAME") && words[1]?.try(&.keyword?("TO"))
        return {Cost::Instant, name, "renames a column"} if verb.keyword?("RENAME")

        full = full?(table)
        return add(words, name, full, before.strict.includes?(table.downcase)) if verb.keyword?("ADD")
        if verb.keyword?("DROP")
          return {Cost::Instant, name, "drops a constraint"} if words[1]?.try(&.keyword?("CONSTRAINT"))
          return {Cost::Instant, name, "drops a column of a table this migration created empty"} unless full

          return {Cost::Rebuild, name, "DROP COLUMN rewrites every row"}
        end
        if verb.keyword?("ALTER")
          return {Cost::Instant, name, "drops a NOT NULL constraint"} if words.any?(&.keyword?("DROP"))

          return {full ? Cost::Scan : Cost::Instant, name, "SET NOT NULL checks every row"}
        end
        {Cost::Scan, name, "Punch does not know what this ALTER TABLE costs; counted as a scan"}
      end

      # `ALTER TABLE old RENAME TO renamed`: rows and copies move with the
      # name, and a rename onto a dropped table is a rebuild's last step.
      private def rename(old : String, renamed : String, index : Int32) : {Cost, String?, String}
        from, to = old.downcase, renamed.downcase
        @full << to if @full.delete(from)
        if steps = @copies.delete(from)
          (@copies[to] ||= [] of Int32).concat(steps)
        end
        @renames[to] = index if @dropped.includes?(to)
        {Cost::Instant, renamed, "renames the table"}
      end

      # `ALTER TABLE ... ADD`: a constraint, or a column, which SQLite checks
      # against every row when the table is STRICT or the column has a CHECK
      # or is generated and NOT NULL.
      private def add(words : Array(Token), name : String, full : Bool, strict : Bool) : {Cost, String?, String}
        return {full ? Cost::Scan : Cost::Instant, name, "checks every row against the new CHECK constraint"} if words[1]?.try(&.keyword?("CONSTRAINT", "CHECK"))
        return {Cost::Instant, name, "adds a column to a table this migration created empty"} unless full
        return {Cost::Scan, name, "adds a column with a CHECK constraint: SQLite checks every row"} if words.any?(&.keyword?("CHECK"))
        if words.any?(&.keyword?("GENERATED", "AS")) && not_null?(words)
          return {Cost::Scan, name, "adds a generated NOT NULL column: SQLite checks every row"}
        end
        return {Cost::Scan, name, "adds a column to a STRICT table: SQLite checks every row's types"} if strict

        {Cost::Instant, name, "adds a column"}
      end

      private def not_null?(words : Array(Token)) : Bool
        words.each_cons_pair.any? { |a, b| a.keyword?("NOT") && b.keyword?("NULL") }
      end

      # Where the data verb of a statement is: 0, or after a leading `WITH`,
      # the first verb outside parentheses.
      private def verb_index(tokens : Array(Token)) : Int32?
        return 0 unless tokens.first.keyword?("WITH")

        depth = 0
        tokens.index do |token|
          depth += 1 if token.punct?("(")
          depth -= 1 if token.punct?(")")
          depth == 0 && token.keyword?("INSERT", "REPLACE", "UPDATE", "DELETE", "SELECT")
        end
      end

      # The table an `INSERT`, `REPLACE`, `UPDATE`, or `DELETE` writes to.
      private def write(tokens : Array(Token), before : Snapshot, index : Int32) : {Cost, String?, String}
        start = verb_index(tokens) || return {Cost::Scan, nil, "Punch does not know what this WITH statement costs; counted as a scan"}
        verb = tokens[start]
        return {Cost::Scan, nil, "a query: reads what it names"} if verb.keyword?("SELECT")
        return insert(tokens, start, before, index) if verb.keyword?("INSERT", "REPLACE")

        at = verb.keyword?("DELETE") ? (tokens.index(start, &.keyword?("FROM")) || start) + 1 : start + 1
        at += 2 if tokens[at]?.try(&.keyword?("OR")) # UPDATE OR IGNORE
        table, _ = target(tokens, at)
        name = name_of(table, before)
        return {Cost::Instant, name, "writes to a table this migration created empty"} unless full?(table)

        {Cost::Scan, name, verb.keyword?("DELETE") ? "deletes every matching row" : "updates every matching row"}
      end

      # An insert of listed rows is instant; one from a query copies, and
      # fills its table.
      private def insert(tokens : Array(Token), start : Int32, before : Snapshot, index : Int32) : {Cost, String?, String}
        into = tokens.index(start, &.keyword?("INTO")) || return {Cost::Scan, nil, "Punch does not know what this INSERT costs; counted as a scan"}
        table, _ = target(tokens, into + 1)
        name = name_of(table, before)
        return {Cost::Instant, name, "inserts the rows it lists"} unless tokens[start..].any?(&.keyword?("SELECT"))

        @full << table.downcase
        (@copies[table.downcase] ||= [] of Int32) << index
        {Cost::Scan, name, "copies the rows of a query"}
      end
    end
  end
end
