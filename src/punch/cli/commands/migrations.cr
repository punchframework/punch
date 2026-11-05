module Punch::CLI::Commands
  # Helpers shared by the migration commands, which work on the app in the
  # current directory: `db/migrations/` and `db/schema.sql`.
  module MigrationCommand
    # The primary database in `PUNCH_STORAGE` (`punch config`).
    def self.default_path : String | Failure
      settings = Config.settings
      settings.is_a?(Failure) ? settings : settings.primary_database
    end

    # The migrations these commands apply: in an app's binary that declares
    # them (`Punch.migrations`), its own, which is what it runs at boot;
    # otherwise the files in `db/migrations/`.
    def self.migrations : Array(Punch::Migrations::Migration)
      Punch::Migrations.app || Punch::Migrations.from_directory
    end

    def self.failure(ex : Exception) : Failure
      case ex
      when Punch::Migrations::Failed        then Failure.new("migration_failed", ex.message || "migration failed")
      when Punch::Migrations::Error         then Failure.new("migration_error", ex.message || "migration error")
      when Punch::Database::FilesystemError then Failure.new("filesystem_refused", ex.message || "filesystem refused")
      when Punch::Database::Error           then Failure.new("database_error", ex.message || "database error")
      else                                       raise ex
      end
    end

    # The schema the migrations produce, built in memory.
    def self.replay(migrations : Array(Punch::Migrations::Migration)) : String
      database = Punch::Database.memory(name: "replay", config: Punch::Database::Config.new(readers: 1))
      begin
        Punch::Migrations::Migrator.new(database, migrations).migrate
        Punch::Migrations::Schema.dump(database)
      ensure
        database.close
      end
    end

    def self.entry_json(json : JSON::Builder, entry : Punch::Migrations::Migrator::Entry) : Nil
      json.object do
        json.field "version", entry.version
        json.field "name", entry.name
        json.field "state", entry.state.to_s.underscore
        json.field "applied_at", entry.applied_at
      end
    end
  end

  # Punch's own tables, which live in the app's migrations (so they can
  # reference its users table): their SQL, and the columns Punch expects,
  # for `punch db:migration --punch NAME` and the `punchtables` step of
  # `punch check`. Each subsystem's definition is in the module that uses
  # the table, so the SQL and the boot-time column check cannot drift from it.
  module PunchTables
    NAMES = %w[outbox steps idempotency webhooks uploads auth roles]

    # Whether the SQL of *name* takes the app's users table.
    def self.users?(name : String) : Bool
      name == "auth" || name == "roles"
    end

    def self.sql(name : String, users : String = "users") : String
      case name
      when "outbox"      then Punch::Job::Outbox.sql
      when "steps"       then Punch::Job::Steps::Progress.sql
      when "idempotency" then Punch::IdempotencyKeys.sql
      when "webhooks"    then Punch::Webhook::Invocations.sql
      when "uploads"     then Punch::Upload.sql
      when "auth"        then Punch::Auth::Schema.sql(users)
      when "roles"       then Punch::Roles::Schema.sql(users)
      else                    raise ArgumentError.new("not a Punch table set: #{name}")
      end
    end

    # Each table of *name* and its columns with their types.
    def self.tables(name : String) : Hash(String, Hash(String, String))
      case name
      when "outbox"      then {"punch_outbox" => Punch::Job::Outbox::COLUMNS}
      when "steps"       then {"punch_job_progress" => Punch::Job::Steps::Progress::COLUMNS}
      when "idempotency" then {"punch_idempotency_keys" => Punch::IdempotencyKeys::COLUMNS}
      when "webhooks"    then {"punch_webhooks" => Punch::Webhook::Invocations::COLUMNS}
      when "uploads"     then {"punch_uploads" => Punch::Upload::COLUMNS}
      when "auth"        then Punch::Auth::Schema::TABLES
      when "roles"       then Punch::Roles::Schema::TABLES
      else                    raise ArgumentError.new("not a Punch table set: #{name}")
      end
    end

    # Every table of *schema* with its columns and their types.
    def self.columns(schema : String) : Hash(String, Hash(String, String))
      database = Punch::Database.memory(name: "punch-tables", config: Punch::Database::Config.new(readers: 1))
      begin
        Punch::Migrations::Schema.load(database, schema)
        found = Hash(String, Hash(String, String)).new
        database.read do |db|
          db.query_all("SELECT m.name, p.name, p.type FROM sqlite_schema m, pragma_table_info(m.name) p WHERE m.type = 'table'", name: "Punch::CLI::PunchTables.columns") do |row|
            {row.read(String), row.read(String), row.read(String).upcase}
          end
        end.each { |table, column, type| (found[table] ||= {} of String => String)[column] = type }
        found
      ensure
        database.close
      end
    end

    # The sets with at least one table in *found*.
    def self.present(found : Hash(String, Hash(String, String))) : Array(String)
      NAMES.select { |name| tables(name).keys.any? { |table| found.has_key?(table) } }
    end

    # The sets every app has, used or not: Punch's own jobs need them.
    REQUIRED = %w[steps]

    # What the schema (*found*, from `columns`) lacks of the sets whose
    # tables it has at least one of, or has of another type, one line each
    # with the migration to write. A set with no table in the schema is the
    # app not using it, which `serve` checks at boot; a set in `REQUIRED`
    # is never left out.
    def self.drift(found : Hash(String, Hash(String, String))) : Array(String)
      present = present(found)
      problems = [] of String
      NAMES.each do |name|
        expected = tables(name)
        fix = "punch db:migration --punch #{name}"
        if REQUIRED.includes?(name) && !present.includes?(name)
          problems << "#{expected.keys.join(", ")} is missing from db/schema.sql; every app has it, since Punch's own jobs run in steps. #{fix} writes it."
          next
        end
        next unless present.includes?(name)
        expected.each do |table, columns|
          unless actual = found[table]?
            problems << "#{table} is missing from db/schema.sql; its set has other tables. #{fix} writes them (leave out the ones you have)."
            next
          end
          columns.each do |column, type|
            if have = actual[column]?
              problems << "#{table}.#{column} is #{have}, Punch needs #{type}. Alter it in a new migration (#{fix} shows the current table)." unless have == type
            else
              problems << "#{table}.#{column} is missing. Add it in a new migration (#{fix} shows the current table)."
            end
          end
        end
      end
      problems
    end
  end

  # Creates a migration file with a timestamped name: empty, or with one of
  # Punch's own tables (`--punch outbox`).
  class DbMigration < Command
    command "db:migration", "Create a migration file: punch db:migration NAME, or punch db:migration --punch outbox|steps|idempotency|webhooks|uploads|auth|roles [--users TABLE] for one of Punch's own tables"

    struct Result
      include Report

      def initialize(@path : String)
      end

      def to_text(io : IO) : Nil
        io.puts "Created #{@path}"
      end

      def to_json(json : JSON::Builder) : Nil
        json.object { json.field "path", @path }
      end
    end

    def run(args : Array(String)) : Report | Failure
      if index = args.index("--punch")
        return punch_tables(args, index)
      end
      return Failure.usage("missing_argument", "Usage: punch db:migration NAME") if args.empty?
      return Failure.usage("unexpected_argument", "'punch db:migration' takes one name; use underscores between words.") if args.size > 1

      write(args.first, "-- #{Punch::Migrations.file_name(args.first)}: write the schema change in SQL. Punch runs it in one transaction.\n")
    rescue ex : Punch::Migrations::Error
      Failure.usage("invalid_name", ex.message || "invalid name")
    end

    # `--punch NAME [--users TABLE]`: the migration with Punch's SQL.
    private def punch_tables(args : Array(String), index : Int32) : Report | Failure
      name = args[index + 1]?
      usage = "Usage: punch db:migration --punch #{PunchTables::NAMES.join("|")} [--users TABLE]"
      return Failure.usage("missing_argument", usage) unless name
      return Failure.usage("unknown_tables", "'#{name}' is not one of Punch's table sets. #{usage}") unless PunchTables::NAMES.includes?(name)

      args.delete_at(index, 2)
      users = "users"
      if option = args.index("--users")
        return Failure.usage("missing_argument", usage) unless table = args[option + 1]?
        return Failure.usage("unexpected_argument", "--users applies to auth and roles, which reference the app's users table.") unless PunchTables.users?(name)

        users = table
        args.delete_at(option, 2)
      end
      return Failure.usage("unexpected_argument", "'punch db:migration --punch' takes a table set and --users, not '#{args.first}'.") unless args.empty?

      sql = begin
        PunchTables.sql(name, users)
      rescue ex : ArgumentError
        return Failure.usage("invalid_name", ex.message || "invalid name")
      end
      write("add_punch_#{name}", sql)
    end

    private def write(name : String, content : String) : Report | Failure
      path = File.join(Punch::Migrations::DIRECTORY, Punch::Migrations.file_name(name))
      return Failure.new("exists", "#{path} exists already.") if File.exists?(path)

      Dir.mkdir_p(Punch::Migrations::DIRECTORY)
      File.write(path, content)
      Result.new(path)
    rescue ex : Punch::Migrations::Error
      Failure.usage("invalid_name", ex.message || "invalid name")
    end
  end

  # Applies pending migrations to a database file and rewrites
  # `db/schema.sql` from it. An app's binary applies its embedded
  # migrations and leaves the schema file to `punch db:migrate`.
  class DbMigrate < Command
    command "db:migrate", "Apply pending migrations to a database and rewrite db/schema.sql: punch db:migrate [PATH]"

    struct Result
      include Report

      # *schema* is `nil` when the migrations came from the binary.
      def initialize(@database : String, @applied : Array(Punch::Migrations::Migration), @schema : String?, @schema_written : Bool)
      end

      def to_text(io : IO) : Nil
        if @applied.empty?
          io.puts "#{@database} is up to date."
        else
          @applied.each { |migration| io.puts "Applied #{migration.file_name}" }
        end
        if schema = @schema
          io.puts @schema_written ? "Wrote #{schema}" : "#{schema} unchanged"
        end
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "database", @database
          json.field "applied" do
            json.array { @applied.each { |migration| json.object { json.field "version", migration.version; json.field "name", migration.name } } }
          end
          json.field "source", @schema ? Punch::Migrations::DIRECTORY : "binary"
          json.field "schema", @schema
          json.field "schema_written", @schema_written
        end
      end
    end

    def run(args : Array(String)) : Report | Failure
      return Failure.usage("unexpected_argument", "'punch db:migrate' takes one path.") if args.size > 1

      path = args.first? || MigrationCommand.default_path
      return path if path.is_a?(Failure)

      Dir.mkdir_p(File.dirname(File.expand_path(path)))
      database = Punch::Database.open(path, name: "primary", config: Punch::Database::Config.new(readers: 1, check_collations: false))
      begin
        applied = Punch::Migrations::Migrator.new(database, MigrationCommand.migrations).migrate
        return Result.new(path, applied, nil, false) if Punch::Migrations.app

        schema = Punch::Migrations::Schema.dump(database)
        # Written only when it changed, so `punch dev` does not see a change.
        written = !File.exists?(Punch::Migrations::SCHEMA) || File.read(Punch::Migrations::SCHEMA) != schema
        if written
          Dir.mkdir_p(File.dirname(Punch::Migrations::SCHEMA))
          File.write(Punch::Migrations::SCHEMA, schema)
        end
        Result.new(path, applied, Punch::Migrations::SCHEMA, written)
      ensure
        database.close
      end
    rescue ex : Punch::Migrations::Error | Punch::Database::Error
      MigrationCommand.failure(ex)
    end
  end

  # Lists every migration and whether it is applied to a database file.
  class DbStatus < Command
    command "db:status", "Show which migrations a database has: punch db:status [PATH]"

    struct Result
      include Report

      def initialize(@database : String, @entries : Array(Punch::Migrations::Migrator::Entry))
      end

      def to_text(io : IO) : Nil
        io.puts "No migrations." if @entries.empty?
        @entries.each do |entry|
          io.puts "#{entry.state.to_s.underscore.ljust(8)} #{entry.version}_#{entry.name}"
        end
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "database", @database
          json.field "source", Punch::Migrations.app ? "binary" : Punch::Migrations::DIRECTORY
          json.field "migrations" { json.array { @entries.each { |entry| MigrationCommand.entry_json(json, entry) } } }
        end
      end
    end

    def run(args : Array(String)) : Report | Failure
      return Failure.usage("unexpected_argument", "'punch db:status' takes one path.") if args.size > 1

      path = args.first? || MigrationCommand.default_path
      return path if path.is_a?(Failure)

      migrations = MigrationCommand.migrations
      unless File.exists?(path)
        # A missing database has every migration pending; do not create it.
        return Result.new(path, migrations.map { |migration| Punch::Migrations::Migrator::Entry.new(migration.version, migration.name, :pending, nil) })
      end
      database = Punch::Database.open(path, name: "primary", config: Punch::Database::Config.new(readers: 1, check_collations: false))
      begin
        Result.new(path, Punch::Migrations::Migrator.new(database, migrations).status)
      ensure
        database.close
      end
    rescue ex : Punch::Migrations::Error | Punch::Database::Error
      MigrationCommand.failure(ex)
    end
  end

  # Prints the schema the migrations produce, built from scratch in memory.
  # With `--check`, compares it with the committed `db/schema.sql` instead,
  # for CI.
  class DbSchema < Command
    command "db:schema", "Print the schema the migrations produce; --check compares it with db/schema.sql"

    struct Result
      include Report

      def initialize(@schema : String, @checked : Bool)
      end

      def to_text(io : IO) : Nil
        @checked ? io.puts("#{Punch::Migrations::SCHEMA} matches the migrations.") : io.print(@schema)
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "schema", @schema
          json.field "matches", true if @checked
        end
      end
    end

    def run(args : Array(String)) : Report | Failure
      check = args.delete("--check")
      return Failure.usage("unexpected_argument", "'punch db:schema' takes only --check.") unless args.empty?

      schema = MigrationCommand.replay(Punch::Migrations.from_directory)
      return Result.new(schema, false) unless check

      committed = File.exists?(Punch::Migrations::SCHEMA) ? File.read(Punch::Migrations::SCHEMA) : ""
      return Result.new(schema, true) if committed == schema

      Failure.new("schema_drift", "#{Punch::Migrations::SCHEMA} does not match db/migrations. Run 'punch db:migrate' on a development database and commit the result; never edit the schema file by hand.")
    rescue ex : Punch::Migrations::Error | Punch::Database::Error
      MigrationCommand.failure(ex)
    end
  end
end
