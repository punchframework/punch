module Punch::Auth
  # The tables behind sessions and tokens live in the app's own migrations,
  # so they can reference its users table (docs/auth.md has the SQL). Their
  # columns are Punch's: this is what Punch's statements need, checked
  # when the server starts.
  module Schema
    TABLES = {
      "punch_sessions" => {
        "id" => "INTEGER", "token_hash" => "BLOB", "user_id" => "INTEGER", "method" => "TEXT",
        "authenticated_at" => "TEXT", "created_at" => "TEXT", "last_seen_at" => "TEXT", "expires_at" => "TEXT",
        "ip" => "TEXT", "user_agent" => "TEXT",
      },
      "punch_api_tokens" => {
        "id" => "INTEGER", "token_hash" => "BLOB", "user_id" => "INTEGER", "name" => "TEXT",
        "created_at" => "TEXT", "expires_at" => "TEXT", "last_used_at" => "TEXT",
      },
      "punch_one_time_tokens" => {
        "token_hash" => "BLOB", "purpose" => "TEXT", "user_id" => "INTEGER", "subject" => "TEXT",
        "created_at" => "TEXT", "expires_at" => "TEXT",
      },
      "punch_email_identities" => {
        "id" => "INTEGER", "user_id" => "INTEGER", "email" => "TEXT", "verified_at" => "TEXT", "created_at" => "TEXT",
      },
      "punch_passwords" => {
        "user_id" => "INTEGER", "hash" => "TEXT", "created_at" => "TEXT", "updated_at" => "TEXT",
      },
      "punch_totp_authenticators" => {
        "user_id" => "INTEGER", "secret" => "BLOB", "confirmed_at" => "TEXT", "last_step" => "INTEGER",
        "unseen_codes" => "BLOB", "created_at" => "TEXT",
      },
      "punch_recovery_codes" => {
        "code_hash" => "BLOB", "user_id" => "INTEGER", "created_at" => "TEXT",
      },
    }

    # The tables as a migration for an app whose users are in *users*.
    # `punch new` writes it; until then, copy it from docs/auth.md.
    def self.sql(users : String = "users") : String
      raise ArgumentError.new("not a table name: #{users.inspect}") unless users.matches?(/\A[a-z_][a-z0-9_]*\z/)
      <<-SQL
        -- Auth::Sessions, API tokens, one-time tokens, email identities,
        -- passwords, and second factors (lib/punch/docs/auth.md). The columns are Punch's; the
        -- references to #{users} are the app's.
        CREATE TABLE punch_sessions (
          id               INTEGER PRIMARY KEY,
          token_hash       BLOB    NOT NULL UNIQUE,
          user_id          INTEGER NOT NULL REFERENCES #{users} (id) ON DELETE CASCADE,
          method           TEXT    NOT NULL,
          authenticated_at TEXT    NOT NULL,
          created_at       TEXT    NOT NULL,
          last_seen_at     TEXT    NOT NULL,
          expires_at       TEXT    NOT NULL,
          ip               TEXT,
          user_agent       TEXT
        ) STRICT;

        CREATE INDEX punch_sessions_by_user ON punch_sessions (user_id);

        CREATE TABLE punch_api_tokens (
          id           INTEGER PRIMARY KEY,
          token_hash   BLOB    NOT NULL UNIQUE,
          user_id      INTEGER NOT NULL REFERENCES #{users} (id) ON DELETE CASCADE,
          name         TEXT    NOT NULL,
          created_at   TEXT    NOT NULL,
          expires_at   TEXT    NOT NULL,
          last_used_at TEXT
        ) STRICT;

        CREATE INDEX punch_api_tokens_by_user ON punch_api_tokens (user_id);

        CREATE TABLE punch_one_time_tokens (
          token_hash BLOB    PRIMARY KEY,
          purpose    TEXT    NOT NULL,
          user_id    INTEGER REFERENCES #{users} (id) ON DELETE CASCADE,
          subject    TEXT,
          created_at TEXT    NOT NULL,
          expires_at TEXT    NOT NULL
        ) STRICT, WITHOUT ROWID;

        CREATE INDEX punch_one_time_tokens_by_user ON punch_one_time_tokens (user_id, purpose);

        #{identities_sql(users)}
        #{second_factor_sql(users)}
        SQL
    end

    # Only the email identities and passwords, for apps that created the
    # other tables before.
    def self.identities_sql(users : String = "users") : String
      raise ArgumentError.new("not a table name: #{users.inspect}") unless users.matches?(/\A[a-z_][a-z0-9_]*\z/)
      <<-SQL
        CREATE TABLE punch_email_identities (
          id          INTEGER PRIMARY KEY,
          user_id     INTEGER NOT NULL REFERENCES #{users} (id) ON DELETE CASCADE,
          email       TEXT    NOT NULL UNIQUE,
          verified_at TEXT,
          created_at  TEXT    NOT NULL
        ) STRICT;

        CREATE INDEX punch_email_identities_by_user ON punch_email_identities (user_id);

        CREATE TABLE punch_passwords (
          user_id    INTEGER PRIMARY KEY REFERENCES #{users} (id) ON DELETE CASCADE,
          hash       TEXT    NOT NULL,
          created_at TEXT    NOT NULL,
          updated_at TEXT    NOT NULL
        ) STRICT;

        SQL
    end

    # Only the authenticator apps and recovery codes, for apps that created
    # the other tables before. The secret and the unseen recovery codes are
    # encrypted with the key ring; the codes in use are SHA-256 digests.
    def self.second_factor_sql(users : String = "users") : String
      raise ArgumentError.new("not a table name: #{users.inspect}") unless users.matches?(/\A[a-z_][a-z0-9_]*\z/)
      <<-SQL
        CREATE TABLE punch_totp_authenticators (
          user_id      INTEGER PRIMARY KEY REFERENCES #{users} (id) ON DELETE CASCADE,
          secret       BLOB    NOT NULL,
          confirmed_at TEXT,
          last_step    INTEGER NOT NULL,
          unseen_codes BLOB,
          created_at   TEXT    NOT NULL
        ) STRICT;

        CREATE TABLE punch_recovery_codes (
          code_hash  BLOB    PRIMARY KEY,
          user_id    INTEGER NOT NULL REFERENCES #{users} (id) ON DELETE CASCADE,
          created_at TEXT    NOT NULL
        ) STRICT, WITHOUT ROWID;

        CREATE INDEX punch_recovery_codes_by_user ON punch_recovery_codes (user_id);

        SQL
    end

    # What is missing or of another type, one line each; empty when every
    # table has every column.
    def self.problems(database : Database) : Array(String)
      problems = [] of String
      database.read do |db|
        TABLES.each do |table, columns|
          found = db.query_all("SELECT name, type FROM pragma_table_info(?)", table, name: "Punch::Auth::Schema.columns") do |row|
            {row.read(String), row.read(String).upcase}
          end.to_h
          if found.empty?
            problems << "table #{table} is missing; add it with a migration (lib/punch/docs/auth.md)"
            next
          end
          columns.each do |column, type|
            if actual = found[column]?
              problems << "#{table}.#{column} is #{actual}, Punch needs #{type}" unless actual == type
            else
              problems << "#{table}.#{column} is missing (lib/punch/docs/auth.md)"
            end
          end
        end
      end
      problems
    end
  end

  # Whether this binary has an actor type, so serving it needs the tables.
  def self.used? : Bool
    {{ Punch::Auth::Actor.includers.size > 0 }}
  end
end
