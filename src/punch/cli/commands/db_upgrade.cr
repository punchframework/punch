module Punch::CLI::Commands
  # `punch db:upgrade [PATH]`: rewrites every JSON document of a composite
  # in the primary database, or the file at PATH, in its current form now
  # (docs/composites.md, "Versions"): documents of older versions are
  # read through their frozen types and written as the current one. The
  # nightly `Database::Upgrade::Run` job does the same. Safe beside a
  # running app: one write transaction per batch. Fails when a document
  # was left as it was. Asked of the app's binary, with the credentials of
  # the environment (`--env NAME`), which encrypted documents need.
  class DbUpgrade < Command
    command "db:upgrade", "Rewrite every stored document of a composite in its current version now: punch db:upgrade [PATH] [--env NAME]"

    struct Result
      include Report

      def initialize(@path : String, @run : Punch::Database::Upgrade)
      end

      def to_text(io : IO) : Nil
        rows = @run.rows.values.sum(0_i64)
        written = @run.written.values.sum(0_i64)
        io.puts "#{@path}: #{rows} rows read, #{written} written."
        @run.messages.each { |line| io.puts "  #{line}" }
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "database", @path
          json.field "upgrade" { @run.to_json(json) }
        end
      end
    end

    def run(args : Array(String)) : Report | Failure
      environment = Creds.environment(args, "db:upgrade")
      return environment if environment.is_a?(Failure)
      return Failure.usage("unexpected_argument", "'punch db:upgrade' takes one path.") if args.size > 1
      if Punch::Database::Upgrade.tables.empty?
        return Failure.new("no_documents", "This binary maps no document columns: run db:upgrade with the app's binary (bin/<app> db:upgrade), after 'punch db:generate' mapped one.")
      end

      path = args.first? || MigrationCommand.default_path
      return path if path.is_a?(Failure)
      return Failure.new("no_database", "#{path} does not exist.") unless File.exists?(path)

      Punch::Credentials.boot(environment)
      database = Punch::Database.open(path, name: "primary", config: Punch::Database::Config.new(readers: 1, check_collations: false))
      begin
        run = Punch::Database::Upgrade.run(database)
        result = Result.new(path, run)
        return result if run.clean?

        Failure.new("documents_left", "#{path}: documents left as they are:\n  #{run.messages.join("\n  ")}\n" \
                                      "Fix the rows, then run db:upgrade again (lib/punch/docs/composites.md#versions).",
          details: JSON.parse(result.to_json))
      ensure
        database.close
      end
    rescue Punch::Credentials::NotLoaded
      Failure.new("no_key_ring", "Encrypted documents need the key ring: declare `getter secret_key_base : Punch::KeyRing` in the app's credentials (lib/punch/docs/keys.md).")
    rescue ex : Punch::Database::Error
      Failure.new("database_error", ex.message || "database error")
    end
  end
end
