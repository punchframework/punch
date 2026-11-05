module Punch::CLI::Commands
  # `punch db:audit [PATH]`: parses every mapped column of every row
  # against the app's domain types, on the primary database or the file at
  # PATH, such as a restored replica. Fails when a value does not parse;
  # values that parse but are not in their stored form are reported without
  # failing; so are encrypted columns, with their values per key. Asked of
  # the app's binary, which has the generated audits and the credentials of
  # the environment (`--env NAME`, else `PUNCH_ENV`) whose key ring
  # decrypts.
  class DbAudit < Command
    command "db:audit", "Parse every mapped column of every row against the app's domain types: punch db:audit [PATH] [--env NAME]"

    struct Result
      include Report

      def initialize(@path : String, @audit : Punch::Database::Audit)
      end

      def to_text(io : IO) : Nil
        rows = @audit.rows.values.sum(0_i64)
        io.puts "#{@path}: #{rows} rows in #{@audit.rows.size} tables, #{@audit.clean? ? "every value parses" : "values that do not parse"}."
        @audit.messages.each { |line| io.puts "  #{line}" }
        @audit.key_lines.each { |line| io.puts "  #{line}" }
        @audit.conversion_lines.each { |line| io.puts "  #{line}" }
        @audit.version_lines.each { |line| io.puts "  #{line}" }
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "database", @path
          json.field "audit" { @audit.to_json(json) }
        end
      end
    end

    def run(args : Array(String)) : Report | Failure
      environment = Creds.environment(args, "db:audit")
      return environment if environment.is_a?(Failure)
      return Failure.usage("unexpected_argument", "'punch db:audit' takes one path.") if args.size > 1
      if Punch::Database::Audit.tables.empty?
        return Failure.new("no_audits", "This binary has no generated audits: run db:audit with the app's binary (bin/<app> db:audit), after 'punch db:generate' mapped a table.")
      end

      path = args.first? || MigrationCommand.default_path
      return path if path.is_a?(Failure)
      return Failure.new("no_database", "#{path} does not exist.") unless File.exists?(path)

      # Encrypted columns decrypt with the environment's key ring; the
      # credentials' problems matter only when one needs it.
      credentials = Punch::Credentials.boot(environment)

      database = Punch::Database.open(path, name: "primary", config: Punch::Database::Config.new(readers: 1, check_collations: false))
      begin
        audit = Punch::Database::Audit.run(database)
        result = Result.new(path, audit)
        return result if audit.clean?

        Failure.new("values_do_not_parse", "#{path}: values that do not parse as their columns' types:\n  #{audit.messages.join("\n  ")}\n" \
                                           "Fix the rows (or the type) before shipping the type change (lib/punch/docs/queries.md#auditing-stored-values-dbaudit).",
          details: JSON.parse(result.to_json))
      ensure
        database.close
      end
    rescue Punch::Credentials::NotLoaded
      credentials.try { |source| return CredsCheck.failure(source) unless source.problems.empty? }
      Failure.new("no_key_ring", "Encrypted columns need the key ring: declare `getter secret_key_base : Punch::KeyRing` in the app's credentials (lib/punch/docs/keys.md).")
    rescue ex : Punch::Database::Error
      Failure.new("database_error", ex.message || "database error")
    end
  end
end
