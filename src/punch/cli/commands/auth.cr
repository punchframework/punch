module Punch::CLI::Commands
  # Helpers shared by the session and token commands, which work on the
  # app's primary database in `PUNCH_STORAGE` (docs/auth.md).
  module AuthCommand
    # Runs *block* with the primary database, which must exist.
    def self.with_database(& : Punch::Database -> Report | Failure) : Report | Failure
      settings = Config.settings
      return settings if settings.is_a?(Failure)

      path = settings.primary_database
      return Failure.new("no_database", "#{path} does not exist; run db:migrate first.") unless File.exists?(path)

      database = Punch::Database.open(path, name: "primary", config: Punch::Database::Config.new(readers: 1))
      begin
        yield database
      ensure
        database.close
      end
    rescue ex : Punch::Database::Error
      Failure.new("database_error", ex.message || "database error")
    end

    # The value of `--name VALUE` in *args*, removed from them; `nil` when
    # absent, a failure when the value is missing.
    def self.option(args : Array(String), name : String) : String | Failure?
      index = args.index(name) || return
      value = args[index + 1]?
      return Failure.usage("missing_value", "#{name} needs a value.") if value.nil? || value.starts_with?("--")

      args.delete_at(index, 2)
      value
    end

    def self.id(text : String, what : String) : Int64 | Failure
      id = text.to_i64?
      id && id > 0 ? id : Failure.usage("invalid_id", "#{what} must be a positive number, got '#{text}'.")
    end

    def self.time(value : Time?) : String
      value ? value.to_s("%F %R") : "never"
    end
  end

  # Lists live sessions, of one user with `--user ID`.
  class SessionsList < Command
    command "sessions", "List live sessions: punch sessions [--user ID]"

    struct Result
      include Report

      def initialize(@sessions : Array(Punch::Auth::Session))
      end

      def to_text(io : IO) : Nil
        io.puts "No live sessions." if @sessions.empty?
        @sessions.each do |session|
          io.puts "#{session.id.to_s.rjust(6)}  user #{session.user_id}  #{session.method}  seen #{AuthCommand.time(session.last_seen_at)}  " \
                  "expires #{AuthCommand.time(session.expires_at)}  #{session.ip || "-"}  #{session.user_agent || "-"}"
        end
      end

      def to_json(json : JSON::Builder) : Nil
        json.object { json.field "sessions", @sessions }
      end
    end

    def run(args : Array(String)) : Report | Failure
      args = args.dup
      user = AuthCommand.option(args, "--user")
      return user if user.is_a?(Failure)
      return Failure.usage("unexpected_argument", "'punch sessions' takes only --user ID.") unless args.empty?

      user_id = user.try { |text| AuthCommand.id(text, "--user") }
      return user_id if user_id.is_a?(Failure)

      AuthCommand.with_database do |database|
        Result.new(database.read { |db| Punch::Auth::Sessions.list(db, user_id) })
      end
    end
  end

  # Ends one session by its ID, or every session of a user.
  class SessionsRevoke < Command
    command "sessions:revoke", "End a session, or all of a user's: punch sessions:revoke ID | --user ID"

    struct Result
      include Report

      def initialize(@revoked : Int64)
      end

      def to_text(io : IO) : Nil
        io.puts "Ended #{@revoked} session#{@revoked == 1 ? "" : "s"}."
      end

      def to_json(json : JSON::Builder) : Nil
        json.object { json.field "revoked", @revoked }
      end
    end

    def run(args : Array(String)) : Report | Failure
      args = args.dup
      user = AuthCommand.option(args, "--user")
      return user if user.is_a?(Failure)

      given = user ? args.empty? : args.size == 1
      return Failure.usage("missing_argument", "Usage: punch sessions:revoke ID | --user ID") unless given

      id = AuthCommand.id(user || args.first, user ? "--user" : "ID")
      return id if id.is_a?(Failure)

      AuthCommand.with_database { |database| user ? revoke_all(database, id) : revoke(database, id) }
    end

    private def revoke_all(database : Punch::Database, user_id : Int64) : Report
      Result.new(database.write { |db| Punch::Auth::Sessions.revoke_all(db, user_id) })
    end

    private def revoke(database : Punch::Database, id : Int64) : Report | Failure
      database.write { |db| Punch::Auth::Sessions.revoke(db, id) } ? Result.new(1) : Failure.new("not_found", "No session #{id}.")
    end
  end

  # Lists live API tokens, of one user with `--user ID`. Never the tokens
  # themselves, which only `tokens:create` shows.
  class TokensList < Command
    command "tokens", "List live API tokens: punch tokens [--user ID]"

    struct Result
      include Report

      def initialize(@tokens : Array(Punch::Auth::APIToken))
      end

      def to_text(io : IO) : Nil
        io.puts "No live API tokens." if @tokens.empty?
        @tokens.each do |token|
          io.puts "#{token.id.to_s.rjust(6)}  user #{token.user_id}  #{token.name}  used #{AuthCommand.time(token.last_used_at)}  " \
                  "expires #{AuthCommand.time(token.expires_at)}"
        end
      end

      def to_json(json : JSON::Builder) : Nil
        json.object { json.field "tokens", @tokens }
      end
    end

    def run(args : Array(String)) : Report | Failure
      args = args.dup
      user = AuthCommand.option(args, "--user")
      return user if user.is_a?(Failure)
      return Failure.usage("unexpected_argument", "'punch tokens' takes only --user ID.") unless args.empty?

      user_id = user.try { |text| AuthCommand.id(text, "--user") }
      return user_id if user_id.is_a?(Failure)

      AuthCommand.with_database do |database|
        Result.new(database.read { |db| Punch::Auth::APITokens.list(db, user_id) })
      end
    end
  end

  # Creates an API token for a user and shows it, once.
  class TokensCreate < Command
    command "tokens:create", "Create an API token, shown once: punch tokens:create --user ID --name NAME [--days 30]"

    struct Result
      include Report

      def initialize(@token : Punch::Auth::APIToken, @secret : Punch::Secret(String))
      end

      def to_text(io : IO) : Nil
        io.puts @secret.unwrap
        io.puts "Token #{@token.id} for user #{@token.user_id}, expires #{AuthCommand.time(@token.expires_at)}. It is shown only now."
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "token", @secret.unwrap
          json.field "api_token", @token
        end
      end
    end

    def run(args : Array(String)) : Report | Failure
      args = args.dup
      user = AuthCommand.option(args, "--user")
      return user if user.is_a?(Failure)

      name = AuthCommand.option(args, "--name")
      return name if name.is_a?(Failure)

      days = AuthCommand.option(args, "--days")
      return days if days.is_a?(Failure)
      unless user && name && args.empty?
        return Failure.usage("missing_argument", "Usage: punch tokens:create --user ID --name NAME [--days 30]")
      end

      user_id = AuthCommand.id(user, "--user")
      return user_id if user_id.is_a?(Failure)

      valid = days ? days.to_i? : 30
      return Failure.usage("invalid_days", "--days must be a whole number, got '#{days}'.") unless valid

      AuthCommand.with_database do |database|
        now = Time.utc

        case created = database.write { |db| Punch::Auth::APITokens.create(db, user_id, name, now + valid.days, now: now) }
        in Punch::Invalid
          Failure.new("invalid_#{created.code}", "Token not created: #{created.code} #{created.params.join(", ") { |key, value| "#{key} #{value}" }}".strip)
        in Tuple(Punch::Auth::APIToken, Punch::Secret(String))
          Result.new(*created)
        end
      rescue ex : Punch::Database::ConstraintError
        Failure.new("no_such_user", "Token not created: #{ex.message}")
      end
    end
  end

  # Revokes one API token by its ID.
  class TokensRevoke < Command
    command "tokens:revoke", "Revoke an API token: punch tokens:revoke ID"

    struct Result
      include Report

      def initialize(@id : Int64)
      end

      def to_text(io : IO) : Nil
        io.puts "Revoked token #{@id}."
      end

      def to_json(json : JSON::Builder) : Nil
        json.object { json.field "revoked", @id }
      end
    end

    def run(args : Array(String)) : Report | Failure
      return Failure.usage("missing_argument", "Usage: punch tokens:revoke ID") unless args.size == 1

      id = AuthCommand.id(args.first, "ID")
      return id if id.is_a?(Failure)

      AuthCommand.with_database do |database|
        database.write { |db| Punch::Auth::APITokens.revoke(db, id) } ? Result.new(id) : Failure.new("not_found", "No token #{id}.")
      end
    end
  end
end

module Punch::CLI::Commands
  # How passwords are hashed, and how many stored hashes use which
  # parameters: after raising the iterations, the old ones go as users sign
  # in (docs/auth.md).
  class PasswordsReport < Command
    command "passwords", "Show password hashing settings and stored hashes by parameters: punch passwords"

    struct Result
      include Report

      def initialize(@config : Punch::Auth::Passwords::Config, @census : Hash(String, Int64))
      end

      def to_text(io : IO) : Nil
        io.puts "Hashing: #{Punch::Auth::Passwords::ALGORITHM}, #{@config.iterations} iterations, #{@config.threads} threads, queue #{@config.queue}"
        if @census.empty?
          io.puts "No stored passwords."
        else
          current = "#{Punch::Auth::Passwords::ALGORITHM} i=#{@config.iterations}"
          @census.to_a.sort_by! { |parameters, _| parameters }.each do |parameters, count|
            note = parameters == current ? "current" : "rehashed at the next sign-in"
            io.puts "#{count.to_s.rjust(8)}  #{parameters}  (#{note})"
          end
        end
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "algorithm", Punch::Auth::Passwords::ALGORITHM
          json.field "iterations", @config.iterations
          json.field "threads", @config.threads
          json.field "queue", @config.queue
          json.field "stored", @census
        end
      end
    end

    def run(args : Array(String)) : Report | Failure
      return Failure.usage("unexpected_argument", "'punch passwords' takes no arguments.") unless args.empty?

      AuthCommand.with_database do |database|
        Result.new(Punch::Auth::Passwords.config, database.read { |db| Punch::Auth::Passwords.census(db) })
      end
    end
  end

  # The email identities of a user, and whether they have a password.
  class IdentitiesList < Command
    command "identities", "List a user's email identities and password: punch identities --user ID"

    struct Result
      include Report

      def initialize(@user_id : Int64, @identities : Array(Punch::Auth::EmailIdentity), @password : Bool)
      end

      def to_text(io : IO) : Nil
        io.puts "No email identities." if @identities.empty?
        @identities.each do |identity|
          io.puts "#{identity.id.to_s.rjust(6)}  #{identity.email}  #{identity.verified_at ? "verified #{AuthCommand.time(identity.verified_at)}" : "unverified"}"
        end
        io.puts @password ? "Has a password." : "No password."
      end

      def to_json(json : JSON::Builder) : Nil
        json.object do
          json.field "user_id", @user_id
          json.field "identities", @identities
          json.field "password", @password
        end
      end
    end

    def run(args : Array(String)) : Report | Failure
      args = args.dup
      user = AuthCommand.option(args, "--user")
      return user if user.is_a?(Failure)
      return Failure.usage("missing_argument", "Usage: punch identities --user ID") unless user && args.empty?

      user_id = AuthCommand.id(user, "--user")
      return user_id if user_id.is_a?(Failure)

      AuthCommand.with_database do |database|
        database.read { |db| Result.new(user_id, Punch::Auth::EmailIdentities.list(db, user_id), Punch::Auth::Passwords.set?(db, user_id)) }
      end
    end
  end
end
