module Punch::CLI::Commands
  # `punch db:encrypt [PATH]`: brings every encrypted column of the primary
  # database, or the file at PATH, to the key ring's signing key now:
  # converts plaintext columns mapped with `from(:column)`, re-encrypts and
  # rehashes values under older keys, and clears plaintext copies with
  # `clear: true`. The nightly `Database::Encryption::Run` job does the
  # same. Safe beside a running app: one write transaction per batch. Fails
  # when a value was left as it was. Asked of the app's binary, with the
  # credentials of the environment (`--env NAME`).
  class DbEncrypt < Command
    command "db:encrypt", "Bring every encrypted column to the signing key now: convert, re-encrypt, rehash, clear: punch db:encrypt [PATH] [--env NAME]"

    struct Result
      include Report

      def initialize(@path : String, @run : Punch::Database::Encryption)
      end

      def to_text(io : IO) : Nil
        rows = @run.rows.values.sum(0_i64)
        written = @run.written.values.sum(0_i64)
        io.puts "#{@path}: #{rows} rows read, #{written} written, under key #{@run.signing}."
        @run.messages.each { |line| io.puts "  #{line}" }
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "database", @path
          json.field "encryption" { @run.to_json(json) }
        end
      end
    end

    def run(args : Array(String)) : Report | Failure
      environment = Creds.environment(args, "db:encrypt")
      return environment if environment.is_a?(Failure)
      return Failure.usage("unexpected_argument", "'punch db:encrypt' takes one path.") if args.size > 1
      if Punch::Database::Encryption.tables.empty?
        return Failure.new("no_encrypted_columns", "This binary has no encrypted columns: run db:encrypt with the app's binary (bin/<app> db:encrypt), after 'punch db:generate' mapped one.")
      end

      path = args.first? || MigrationCommand.default_path
      return path if path.is_a?(Failure)
      return Failure.new("no_database", "#{path} does not exist.") unless File.exists?(path)

      credentials = Punch::Credentials.boot(environment)
      Punch::KeyRing.current # fails here, before the database opens, without a ring
      database = Punch::Database.open(path, name: "primary", config: Punch::Database::Config.new(readers: 1, check_collations: false))
      begin
        run = Punch::Database::Encryption.run(database)
        result = Result.new(path, run)
        return result if run.clean?

        Failure.new("values_left", "#{path}: values left under an older key or in plaintext:\n  #{run.messages.join("\n  ")}\n" \
                                   "Fix the rows, then run db:encrypt again (lib/punch/docs/queries.md#converting-and-re-encrypting-dbencrypt).",
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
