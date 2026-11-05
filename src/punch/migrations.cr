require "digest/sha256"
require "./database"

module Punch
  # A schema change: one plain `.sql` file in `db/migrations/`, named
  # `<14-digit UTC timestamp>_<name>.sql`. Migrations only go forward; there
  # is no down migration.
  struct Migrations::Migration
    FILE_NAME = /\A(\d{14})_([a-z0-9_]+)\.sql\z/

    getter version : Int64
    getter name : String
    getter sql : String
    # Where the migration came from, for messages: a file path.
    getter source : String
    # SHA-256 of the SQL, hex. An applied migration whose file changed later
    # no longer matches it.
    getter checksum : String

    def initialize(@version : Int64, @name : String, @sql : String, @source : String)
      @checksum = Digest::SHA256.hexdigest(@sql)
    end

    # Parses a file name. Raises `Migrations::Error` for one that does not
    # follow the pattern, so a typo cannot hide a migration.
    def self.from_file(file_name : String, sql : String, source : String = file_name) : self
      match = FILE_NAME.match(File.basename(file_name)) ||
              raise Migrations::Error.new("#{source}: migration files are named <14-digit timestamp>_<name>.sql, such as 20261008153000_create_invoices.sql")
      new(match[1].to_i64, match[2], sql, source)
    end

    def file_name : String
      "#{version}_#{name}.sql"
    end
  end

  module Migrations
    # The app's migrations and schema file, relative to its root.
    DIRECTORY = "db/migrations"
    SCHEMA    = "db/schema.sql"

    # The table that records applied migrations.
    TABLE = "punch_schema_migrations"

    class Error < Exception
    end

    # A migration failed; nothing of it was applied.
    class Failed < Error
      getter migration : Migrations::Migration
      getter line : Int32?
      getter column : Int32?

      def initialize(@migration : Migrations::Migration, message : String, @line : Int32? = nil, @column : Int32? = nil, cause : Exception? = nil)
        location = line ? "#{migration.source}:#{line}:#{column}" : migration.source
        super("#{location}: #{message}", cause: cause)
      end
    end

    # Reads every migration in *directory*, sorted by version. Anything
    # else in the directory, except dotfiles and a README, is an error.
    def self.from_directory(directory : String = DIRECTORY) : Array(Migrations::Migration)
      return [] of Migrations::Migration unless Dir.exists?(directory)

      migrations = Dir.children(directory).sort!.compact_map do |child|
        next if child.starts_with?('.') || child.downcase.starts_with?("readme")
        path = File.join(directory, child)
        Migrations::Migration.from_file(child, File.read(path), path)
      end
      sorted(migrations)
    end

    @@app : Array(Migrations::Migration)?

    # The app's migrations, embedded by `Punch.migrations`; `nil` in a
    # binary that declares none, such as the standalone `punch`.
    def self.app : Array(Migrations::Migration)?
      @@app
    end

    # :nodoc:
    def self.app=(@@app : Array(Migrations::Migration)?) : Nil
    end

    # Checks a set of migrations and sorts it: versions must be unique.
    def self.sorted(migrations : Enumerable(Migrations::Migration)) : Array(Migrations::Migration)
      list = migrations.to_a.sort_by!(&.version)
      list.each_cons_pair do |a, b|
        raise Error.new("#{a.source} and #{b.source} have the same version #{a.version}") if a.version == b.version
      end
      list
    end

    # Embeds the migrations of *directory*, relative to the calling file,
    # at compile time, so the binary migrates without its source tree:
    # `MIGRATIONS = Punch::Migrations.embed("../db/migrations")`.
    macro embed(directory, base = __DIR__)
      {% path = "#{base.id}/#{directory.id}" %}
      {% files = `ls -1 #{path.id} 2>/dev/null || true`.stringify.split("\n").reject { |name| name.empty? || name.starts_with?(".") || name.downcase.starts_with?("readme") } %}
      {% versions = {} of String => String %}
      {% for file in files %}
        {% parts = file.split("_") %}
        {% unless file =~ /\A\d{14}_[a-z0-9_]+\.sql\z/ %}
          {% raise "#{directory.id}/#{file.id}: migration files are named <14-digit timestamp>_<name>.sql, such as 20261008153000_create_invoices.sql" %}
        {% end %}
        {% raise "#{directory.id}: #{versions[parts[0]].id} and #{file.id} have the same version #{parts[0].id}" if versions[parts[0]] %}
        {% versions[parts[0]] = file %}
      {% end %}
      Punch::Migrations.sorted([
        {% for file in files %}
          Punch::Migrations::Migration.from_file({{ file }}, {{ read_file("#{path.id}/#{file.id}") }}, {{ "#{directory.id}/#{file.id}" }}),
        {% end %}
      ] of Punch::Migrations::Migration)
    end

    # A file name for a new migration: `20261008153000_create_invoices.sql`.
    def self.file_name(name : String, now : Time = Time.utc) : String
      slug = name.strip.underscore.gsub(/[^a-z0-9]+/, "_").strip('_')
      raise Error.new("a migration needs a name of letters and digits, such as create_invoices") if slug.empty?
      "#{now.to_utc.to_s("%Y%m%d%H%M%S")}_#{slug}.sql"
    end
  end

  # Embeds the app's migrations, *dir* relative to the calling file, so its
  # binary migrates itself without a source tree: `serve` and `jobs` apply
  # pending ones at boot, and the binary's `db:migrate` and `db:status`
  # use these (`docs/deployment.md`). Declared once per app:
  # `Punch.migrations "../db/migrations"`.
  macro migrations(dir)
    {% if @top_level.has_constant?("PunchMigrationsDeclared") %}
      {% raise "Punch.migrations: an app has one migrations directory, and it is already declared" %}
    {% end %}
    {% base = @caller.first.filename.split("/")[0..-2].join("/") %}
    {% unless `test -d '#{base.id}/#{dir.id}' && echo yes || echo no`.stringify.strip == "yes" %}
      {% raise "Punch.migrations: no directory #{base.id}/#{dir.id}" %}
    {% end %}
    # Whether the app declared its migrations (`Punch.migrations`).
    PunchMigrationsDeclared = true

    ::Punch::Migrations.app = ::Punch::Migrations.embed({{ dir }}, {{ base }})
  end

  # Applies migrations to one database and reports their state.
  #
  # ```
  # migrator = Punch::Migrations::Migrator.new(databases.primary, MIGRATIONS)
  # migrator.migrate # => the migrations it applied
  # ```
  #
  # Each migration runs in its own `BEGIN IMMEDIATE` transaction on the
  # writer, as SQLite's procedure for schema changes prescribes: foreign keys
  # are switched off around it (so a table rebuild does not cascade) and
  # `PRAGMA foreign_key_check` must find nothing before it commits. Two
  # processes migrating at once apply each migration once.
  class Migrations::Migrator
    enum State
      # Recorded and unchanged.
      Applied
      # Not yet recorded.
      Pending
      # Recorded with another checksum: the file was edited after it ran.
      Changed
      # Recorded, but this binary does not have it: a newer binary ran it,
      # as during a rollback or a deploy handover.
      Unknown
    end

    record Entry, version : Int64, name : String, state : State, applied_at : String?

    @migrations : Array(Migrations::Migration)

    def initialize(@database : Database, migrations : Enumerable(Migrations::Migration))
      @migrations = Migrations.sorted(migrations)
    end

    # Every migration, known or recorded, by version.
    def status : Array(Entry)
      recorded = applied
      entries = @migrations.map do |migration|
        if row = recorded[migration.version]?
          Entry.new(migration.version, migration.name, row[:checksum] == migration.checksum ? State::Applied : State::Changed, row[:applied_at])
        else
          Entry.new(migration.version, migration.name, State::Pending, nil)
        end
      end
      known = @migrations.map(&.version).to_set
      recorded.each do |version, row|
        entries << Entry.new(version, row[:name], State::Unknown, row[:applied_at]) unless known.includes?(version)
      end
      entries.sort_by!(&.version)
    end

    def pending : Array(Migrations::Migration)
      recorded = applied
      @migrations.reject { |migration| recorded.has_key?(migration.version) }
    end

    # Applies every pending migration in version order and returns them.
    # Refuses to start while an applied migration was changed. Stops at the
    # first failure, which raises `Migrations::Failed`; the migrations
    # before it stay applied.
    def migrate : Array(Migrations::Migration)
      changed = status.select(&.state.changed?)
      unless changed.empty?
        raise Migrations::Error.new("applied migrations were changed afterwards: #{changed.join(", ") { |entry| "#{entry.version}_#{entry.name}" }}. " \
                                    "Restore them and put the change in a new migration.")
      end
      todo = pending
      reindexed = todo.reduce(Set(String).new) { |names, migration| names | Database::CollationVersions.reindexed(migration.sql) }
      check_collations(reindexed)
      todo.select { |migration| apply(migration) }
    end

    # Refuses to migrate while a collation's or text function's rules
    # changed and no pending migration rebuilds its indexes.
    private def check_collations(reindexed : Set(String)) : Nil
      @database.with_writer_connection do |connection|
        open = Database::CollationVersions.mismatches(connection, @database.config.collations).reject { |mismatch| reindexed.includes?(mismatch.name) || reindexed.includes?(Database::CollationVersions::ALL) }
        raise Database::CollationVersions::Changed.new(@database.path, open) unless open.empty?
      end
    end

    # Applies one migration unless another process did first. Returns
    # whether it ran here.
    private def apply(migration : Migrations::Migration) : Bool
      @database.with_writer_connection do |connection|
        connection.exec("PRAGMA foreign_keys = OFF")
        begin
          connection.exec("BEGIN IMMEDIATE")
          Migrations::Migrator.create_table(connection)
          done = connection.query("SELECT 1 FROM #{Migrations::TABLE} WHERE version = ?", {migration.version}) { |_| break true }
          if done
            connection.exec("ROLLBACK")
            next false
          end
          run(connection, migration)
          violations = [] of String
          connection.query("PRAGMA foreign_key_check", Tuple.new) do |row|
            violations << "#{row.read(String)} row #{row.read(Int64?)} references #{row.read(String)}"
          end
          raise Migrations::Failed.new(migration, "foreign key violations: #{violations.first(5).join("; ")}") unless violations.empty?
          Database::CollationVersions.record(connection, @database.config.collations, Database::CollationVersions.reindexed(migration.sql))
          connection.exec("INSERT INTO #{Migrations::TABLE} (version, name, checksum, applied_at) VALUES (?, ?, ?, ?)",
            {migration.version, migration.name, migration.checksum, Time.utc.to_rfc3339})
          connection.exec("COMMIT")
          true
        rescue ex
          connection.exec("ROLLBACK") if connection.in_transaction?
          raise ex
        ensure
          connection.exec("PRAGMA foreign_keys = ON")
        end
      end
    end

    private def run(connection : Database::Driver::Connection, migration : Migrations::Migration) : Nil
      # A migration is a `.sql` file of the app's, read or embedded as written.
      connection.exec_script(migration.sql) do |start| # ameba:disable Punch/SQLText
        next if connection.in_transaction?
        line = migration.sql.byte_slice(0, start).count('\n') + 1
        raise Migrations::Failed.new(migration, "a migration must not end its transaction (COMMIT, ROLLBACK, or END); Punch commits it", line, 1)
      end
    rescue ex : Database::ScriptError
      raise Migrations::Failed.new(migration, ex.detail, ex.line, ex.column, cause: ex)
    end

    # :nodoc:
    def self.create_table(connection : Database::Driver::Connection) : Nil
      connection.exec(<<-SQL)
        CREATE TABLE IF NOT EXISTS #{Migrations::TABLE} (
          version INTEGER PRIMARY KEY,
          name TEXT NOT NULL,
          checksum TEXT NOT NULL,
          applied_at TEXT
        ) STRICT
        SQL
    end

    private def applied : Hash(Int64, NamedTuple(name: String, checksum: String, applied_at: String?))
      recorded = {} of Int64 => NamedTuple(name: String, checksum: String, applied_at: String?)
      @database.read do |reader|
        exists = reader.query_one?("SELECT 1 FROM sqlite_schema WHERE type = 'table' AND name = ?", Migrations::TABLE, &.read(Int64))
        next unless exists
        reader.query_each("SELECT version, name, checksum, applied_at FROM #{Migrations::TABLE}") do |row|
          recorded[row.read(Int64)] = {name: row.read(String), checksum: row.read(String), applied_at: row.read(String?)}
        end
      end
      recorded
    end
  end
end

module Punch
  # `db/schema.sql`: the complete structure of a database in one file, the
  # place to learn it. Written after every migration, committed, never
  # edited by hand. It ends with the applied migrations, so a database
  # loaded from it knows which migrations it already has.
  module Migrations::Schema
    HEADER = <<-TEXT
      -- The complete schema, written by `punch db:migrate` after every migration.
      -- Do not edit: change the schema with a new file in db/migrations.

      TEXT

    # The schema of *database* as SQL, in a stable order: tables, indexes,
    # views in creation order, triggers, then the applied migrations.
    # Litestream's tables (`_litestream_seq`, `_litestream_lock`), which it
    # adds to every file it replicates, and Punch's `_punch_heartbeat`
    # (`Backup::Heartbeat`) are left out.
    def self.dump(database : Database) : String
      database.read do |reader|
        shadow = reader.query_all("SELECT name FROM pragma_table_list WHERE type = 'shadow'", &.read(String)).to_set
        objects = reader.query_all(<<-SQL) { |row| {row.read(String), row.read(String), row.read(String)} }
          SELECT type, name, sql FROM sqlite_schema
          WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\'
            AND tbl_name NOT LIKE '\\_litestream\\_%' ESCAPE '\\' AND tbl_name <> '_punch_heartbeat'
          ORDER BY CASE type WHEN 'table' THEN 0 WHEN 'index' THEN 1 WHEN 'view' THEN 2 ELSE 3 END,
                   CASE type WHEN 'view' THEN printf('%020d', rowid) ELSE name END
          SQL
        String.build do |io|
          io << HEADER
          objects.each do |_, name, sql|
            next if shadow.includes?(name)
            io << sql << ";\n\n"
          end
          dump_versions(reader, io)
          dump_collations(reader, io)
        end
      end
    end

    private def self.dump_versions(reader : Reader, io : IO) : Nil
      exists = reader.query_one?("SELECT 1 FROM sqlite_schema WHERE type = 'table' AND name = ?", Migrations::TABLE, &.read(Int64))
      return unless exists

      rows = reader.query_all("SELECT version, name, checksum FROM #{Migrations::TABLE} ORDER BY version") do |row|
        "  (#{row.read(Int64)}, #{literal(row.read(String))}, #{literal(row.read(String))})"
      end
      return if rows.empty?

      io << "INSERT INTO " << Migrations::TABLE << " (version, name, checksum) VALUES\n"
      io << rows.join(",\n") << ";\n"
    end

    # The collation versions the indexes were built with, so a database
    # loaded from the file knows them too.
    private def self.dump_collations(reader : Reader, io : IO) : Nil
      table = Database::CollationVersions::TABLE
      exists = reader.query_one?("SELECT 1 FROM sqlite_schema WHERE type = 'table' AND name = ?", table, &.read(Int64))
      return unless exists

      rows = reader.query_all("SELECT name, version FROM #{Database::CollationVersions::TABLE} ORDER BY name") do |row|
        "  (#{literal(row.read(String))}, #{literal(row.read(String))})"
      end
      return if rows.empty?

      io << "INSERT INTO " << table << " (name, version) VALUES\n"
      io << rows.join(",\n") << ";\n"
    end

    # *text* as an SQL string literal, for the rows the schema file ends
    # with. The file is text that `Migrations.load` runs, so the values
    # Punch's tables hold (migration names, checksums, collation versions)
    # are quoted here, in one place, though none can hold a quote today.
    private def self.literal(text : String) : String
      raise ArgumentError.new("NUL in a value for db/schema.sql") if text.includes?('\0')
      "'#{text.gsub('\'', "''")}'"
    end

    # Loads a schema file into an empty database, in one transaction.
    def self.load(database : Database, sql : String, source : String = Migrations::SCHEMA) : Nil
      database.with_writer_connection do |connection|
        connection.exec("BEGIN IMMEDIATE")
        begin
          # The schema file, `db/schema.sql`, as written by `Migrations::Schema.dump`.
          connection.exec_script(sql) { } # ameba:disable Punch/SQLText
          connection.exec("COMMIT")
        rescue ex : Database::ScriptError
          raise Migrations::Error.new("#{source}:#{ex.line}:#{ex.column}: #{ex.detail}")
        ensure
          connection.exec("ROLLBACK") if connection.in_transaction?
        end
      end
    end
  end
end
