require "../../database/shell"

module Punch::CLI::Commands
  # Reports the SQLite linked into this binary and, given a path, the state
  # of one database file. Never creates or changes the file.
  class Db < Command
    command "db", "Show the linked SQLite and, given a file, its state: punch db [PATH]"

    record FileState, path : String, filesystem : Punch::Database::Filesystem::Verdict,
      size : Int64, wal_size : Int64?, pragmas : Hash(String, String), collations : Hash(String, String)

    # Read-only pragmas reported for a file.
    # Each with its statement, written out: SQL text is never built from a
    # value, not even a name from a list.
    PRAGMAS = {
      journal_mode: "PRAGMA journal_mode", page_size: "PRAGMA page_size", page_count: "PRAGMA page_count",
      freelist_count: "PRAGMA freelist_count", user_version: "PRAGMA user_version",
      application_id: "PRAGMA application_id", auto_vacuum: "PRAGMA auto_vacuum", encoding: "PRAGMA encoding",
    }

    struct Result
      include Report

      def initialize(@file : FileState?)
      end

      def to_text(io : IO) : Nil
        io.puts "SQLite #{Punch::Database::Driver.version} (#{Punch::Database::Driver.source_id})"
        io.puts "Compile options: #{Punch::Database::Driver.compile_options.join(" ")}"
        io.puts "Collations: #{Punch::Text::Collation::BUILTIN.join(" ", &.name)} (#{Punch::Text::Collation::BUILTIN.map(&.version).uniq!.join(", ")})"
        return unless file = @file

        verdict = file.filesystem
        io.puts
        io.puts file.path
        io.puts "  filesystem: #{verdict.type}#{verdict.refused ? " (refused: WAL snapshots are not reliable there)" : ""}"
        io.puts "  size: #{file.size} bytes#{file.wal_size.try { |size| ", WAL #{size} bytes" }}"
        file.pragmas.each { |key, value| io.puts "  #{key}: #{value}" }
        file.collations.each do |name, version|
          io.puts "  collation #{name}: #{version}#{Db.changed?(name, version) ? " (changed: this binary has #{Db.current(name) || "none"}; REINDEX #{name} in a migration)" : ""}"
        end
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "sqlite" do
            json.object do
              json.field "version", Punch::Database::Driver.version
              json.field "source_id", Punch::Database::Driver.source_id
              json.field "threadsafe", Punch::Database::Driver.threadsafe
              json.field "compile_options", Punch::Database::Driver.compile_options
            end
          end
          json.field "collations" do
            json.array do
              Punch::Text::Collation::BUILTIN.each { |collation| json.object { json.field "name", collation.name; json.field "version", collation.version } }
            end
          end
          if file = @file
            json.field "database" do
              json.object do
                json.field "path", file.path
                json.field "filesystem" do
                  json.object do
                    json.field "type", file.filesystem.type
                    json.field "refused", file.filesystem.refused
                  end
                end
                json.field "size", file.size
                json.field "wal_size", file.wal_size
                json.field "pragmas", file.pragmas
                json.field "collations" do
                  json.array do
                    file.collations.each do |name, version|
                      json.object do
                        json.field "name", name
                        json.field "version", version
                        json.field "changed", Db.changed?(name, version)
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end

    # The version this binary has of collation *name*.
    def self.current(name : String) : String?
      Punch::Text::Collation::BUILTIN.find(&.name.==(name)).try(&.version)
    end

    # Whether a database's indexes were built with another version.
    def self.changed?(name : String, version : String) : Bool
      current(name) != version
    end

    def run(args : Array(String)) : Report | Failure
      return Failure.usage("unexpected_argument", "'punch db' takes at most one path.") if args.size > 1
      return Result.new(nil) unless path = args.first?
      return Failure.new("not_found", "No database at #{path}.") unless File.file?(path)

      Result.new(inspect(path))
    end

    private def inspect(path : String) : FileState
      verdict = Punch::Database::Filesystem.check(path)
      connection = Punch::Database::Driver.open("file:#{URI.encode_path(File.expand_path(path))}?mode=ro")
      pragmas = {} of String => String
      collations = begin
        connection.exec("PRAGMA busy_timeout = 5000")
        PRAGMAS.each { |name, sql| pragmas[name.to_s] = connection.scalar_text(sql) || "" }
        Punch::Database::CollationVersions.recorded(connection)
      ensure
        connection.close
      end
      wal = "#{path}-wal"
      FileState.new(path, verdict, File.size(path), File.exists?(wal) ? File.size(wal) : nil, pragmas, collations)
    end
  end

  # Opens the SQLite shell, built from the same source and options as the
  # linked library, on a database file. Interactive, so it has no JSON mode;
  # inside the shell, `.mode json` gives JSON output.
  class DbShell < Command
    command "db:shell", "Open the SQLite shell on a database: punch db:shell PATH [SQL]"

    def self.json? : Bool
      false
    end

    struct Done
      include Report

      def to_text(io : IO) : Nil
      end

      def to_json(json : JSON::Builder) : Nil
        json.object { }
      end
    end

    def run(args : Array(String)) : Report | Failure
      path = args.first? || return Failure.usage("missing_argument", "Usage: punch db:shell PATH [SQL]")
      unless File.file?(path) || path == ":memory:"
        return Failure.new("not_found", "No database at #{path}. The shell does not create files; Punch creates databases at boot.")
      end

      code = Punch::Database::Shell.run(args)
      code == 0 ? Done.new : Failure.new("shell_failed", "the SQLite shell exited with #{code}", code)
    end
  end
end
