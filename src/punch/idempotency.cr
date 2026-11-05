module Punch
  # How a Command takes idempotency keys. Every Command whose caller is
  # known accepts the `Idempotency-Key` header; this annotation makes it
  # required, or gives Commands without a signed-in caller a scope for their
  # keys:
  #
  # ```
  # @[Punch::Idempotency(:required)]                 # 400 without a key
  # @[Punch::Idempotency(scope: :ip)]                # anonymous callers, keys per address
  # @[Punch::Idempotency(:required, scope: :anyone)] # one scope for every anonymous caller
  # ```
  #
  # `:anyone` shares keys between all anonymous callers, so only keys no
  # one can guess protect them, such as the form's generated one
  # (`v.form(..., idempotent: true)`).
  annotation Idempotency
  end

  # Idempotency keys for Commands: a retry under the same key gets the first
  # answer back instead of running the Command again.
  #
  # The answer is stored with the key in the Command's own transaction, so
  # the key exists if and only if the Command's writes and outbox entries
  # do. A second request under the key waits for the writer like any
  # other and then finds the stored answer; there is no "in progress"
  # state. A failure result rolls the Command's writes back, and its
  # answer is stored right after, in the same turn of the writer
  # (`Lease#after_rollback`).
  module IdempotencyKeys
    HEADER          = "Idempotency-Key"
    REPLAYED_HEADER = "Idempotent-Replayed"
    # The hidden field of a form that carries a key (`View#form`).
    FIELD = "_idempotency_key"

    # Kept at least this long, also with a shorter setting: the OpenAPI
    # document promises it.
    MINIMUM_RETENTION = 24.hours

    # How long a stored answer is replayed (`PUNCH_IDEMPOTENCY_RETENTION_HOURS`).
    class_property retention : Time::Span = MINIMUM_RETENTION

    # The table lives in the app's migrations, like the outbox; its columns
    # are Punch's, checked when the server starts.
    COLUMNS = {
      "scope" => "TEXT", "operation" => "TEXT", "key" => "TEXT", "fingerprint" => "BLOB", "status" => "INTEGER",
      "content_type" => "TEXT", "location" => "TEXT", "body" => "BLOB", "created_at" => "INTEGER", "expires_at" => "INTEGER",
    }

    # The table as a migration. `punch db:migration --punch` writes it as a migration.
    def self.sql : String
      <<-SQL
        -- Idempotency keys: the stored answer of a Command per caller,
        -- operation, and key (lib/punch/docs/operations.md). The columns are Punch's.
        CREATE TABLE punch_idempotency_keys (
          scope        TEXT    NOT NULL,
          operation    TEXT    NOT NULL,
          key          TEXT    NOT NULL,
          fingerprint  BLOB    NOT NULL,
          status       INTEGER NOT NULL,
          content_type TEXT,
          location     TEXT,
          body         BLOB    NOT NULL,
          created_at   INTEGER NOT NULL,
          expires_at   INTEGER NOT NULL,
          PRIMARY KEY (scope, operation, key)
        ) STRICT, WITHOUT ROWID;

        CREATE INDEX punch_idempotency_keys_expiry ON punch_idempotency_keys (expires_at);

        SQL
    end

    # Whether some Command in this binary accepts keys.
    def self.used? : Bool
      {% begin %}
        {% found = false %}
        {% for op in ::Punch::Command.all_subclasses.reject(&.abstract?) %}
          {% extras = op.has_constant?("PunchCallExtras") ? parse_type("::#{op}::PunchCallExtras").resolve.type_vars : [] of TypeNode %}
          {% signs_in = extras.any? { |type| type == ::Punch::Auth::Authentication || type == ::Punch::Auth::PasswordCheck } %}
          {% actor = extras.any? { |type| (type.union? ? type.union_types : [type]).any? { |member| member < ::Punch::Auth::Actor } } %}
          {% declared = op.annotation(::Punch::Idempotency) %}
          {% found = true if !signs_in && (actor || (declared && declared[:scope])) %}
        {% end %}
        {{ found }}
      {% end %}
    end

    # What is missing or of another type, one line each; empty when the
    # table is as Punch needs it.
    def self.problems(database : Database) : Array(String)
      found = database.read do |db|
        db.query_all("SELECT name, type FROM pragma_table_info('punch_idempotency_keys')", name: "Punch::IdempotencyKeys.columns") do |row|
          {row.read(String), row.read(String).upcase}
        end.to_h
      end
      return ["table punch_idempotency_keys is missing; add it with a migration (lib/punch/docs/operations.md)"] if found.empty?

      COLUMNS.compact_map do |column, type|
        if actual = found[column]?
          "punch_idempotency_keys.#{column} is #{actual}, Punch needs #{type}" unless actual == type
        else
          "punch_idempotency_keys.#{column} is missing (lib/punch/docs/operations.md)"
        end
      end
    end

    # One request under a key, before its transaction: the key, what makes
    # it the same request, and where the scope comes from when nobody is
    # signed in.
    # :nodoc:
    class Attempt
      getter key : IdempotencyKey
      getter operation : String
      getter fingerprint : Bytes
      getter anonymous_scope : String?
      property scope : String = ""
      # The answer, once it has been rendered and stored.
      property response : HTTP::Response?

      def initialize(@key : IdempotencyKey, @operation : String, @fingerprint : Bytes, @anonymous_scope : String?)
      end
    end

    # The stored answer, or the refusal, that replaces running the Command.
    # :nodoc:
    struct Replay
      getter response : HTTP::Response

      def initialize(@response : HTTP::Response)
      end
    end

    # The attempt of a request to a Command that accepts keys (*mode*
    # `:optional` or `:required`), `nil` without a key, or a 400 for a
    # missing required key or one that does not parse. The key comes from
    # the header, else from a form's hidden field.
    #
    # "The same request" is the operation, method, path with query, and
    # body as received.
    def self.attempt(context : HTTP::Context, operation : String, mode : Symbol, scope : Symbol?,
                     body : String, form : URI::Params?) : (Attempt | HTTP::Response)?
      raw = context.request.headers[HEADER]? || form.try(&.[FIELD]?)
      unless raw
        return mode == :required ? refuse(context, :bad_request, "idempotency_key_required") : nil
      end

      key = IdempotencyKey.parse(raw)
      return refuse(context, :bad_request, "invalid_idempotency_key") if key.is_a?(Invalid)

      anonymous = case scope
                  when :ip     then "ip:#{RateLimits.ip_key(context.client_ip)}"
                  when :anyone then "anyone"
                  end
      request = context.request
      Attempt.new(key, operation, Crypto::Fingerprint.of(operation, request.method, request.resource, body), anonymous)
    end

    # 400 for a key sent to a Command that takes none.
    def self.refuse_unaccepted(context : HTTP::Context) : HTTP::Response?
      refuse(context, :bad_request, "idempotency_key_not_accepted") if context.request.headers.has_key?(HEADER)
    end

    # Inside the Command's transaction, after authentication and the
    # policy: the stored answer under the key, a 422 when the key was used
    # for another request, a 400 when there is no scope for it, or `nil`
    # to run the Command.
    def self.claim(attempt : Attempt, db : Writer, context : HTTP::Context) : Replay?
      scope = context.principal.try { |principal| "user:#{principal.user_id}" } || attempt.anonymous_scope
      return Replay.new(refuse(context, :bad_request, "idempotency_key_not_accepted")) unless scope

      attempt.scope = scope
      stored = db.query_one?(<<-SQL, scope, attempt.operation, attempt.key.value, Time.utc.to_unix_ms, name: "Punch::IdempotencyKeys.find") do |row|
        SELECT fingerprint, status, content_type, location, body FROM punch_idempotency_keys
        WHERE scope = ? AND operation = ? AND key = ? AND expires_at > ?
        SQL
        {row.read(Bytes), row.read(Int64), row.read(String?), row.read(String?), row.read(Bytes)}
      end
      return unless stored

      fingerprint, status, content_type, location, body = stored
      unless fingerprint == attempt.fingerprint
        return Replay.new(refuse(context, :unprocessable_entity, "idempotency_key_reused"))
      end

      context.span.set("punch.idempotency", "replayed")
      headers = ::HTTP::Headers{REPLAYED_HEADER => "true"}
      headers["Content-Type"] = content_type if content_type
      headers["Location"] = location if location
      Replay.new(HTTP::Response.new(::HTTP::Status.new(status.to_i32), String.new(body), headers))
    end

    # Stores *response* as the answer under the attempt's key: in the
    # Command's transaction, or after its rollback when *failed*.
    def self.keep(attempt : Attempt, db : Writer, response : HTTP::Response, failed : Bool) : Nil
      attempt.response = response
      if failed
        db.lease.after_rollback = ->(writer : Writer) { store(attempt, writer, response) }
      else
        store(attempt, db, response)
      end
    end

    private def self.store(attempt : Attempt, db : Writer, response : HTTP::Response) : Nil
      created = Time.utc
      # An expired row under the key is replaced; a live one cannot be
      # there, `claim` found none in this transaction.
      db.exec(<<-SQL, attempt.scope, attempt.operation, attempt.key.value, attempt.fingerprint, response.status.code.to_i64,
        INSERT INTO punch_idempotency_keys (scope, operation, key, fingerprint, status, content_type, location, body, created_at, expires_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT (scope, operation, key) DO UPDATE SET fingerprint = excluded.fingerprint, status = excluded.status,
          content_type = excluded.content_type, location = excluded.location, body = excluded.body,
          created_at = excluded.created_at, expires_at = excluded.expires_at
        WHERE punch_idempotency_keys.expires_at <= excluded.created_at
        SQL
        response.headers["Content-Type"]?, response.headers["Location"]?, response.body.to_slice,
        created.to_unix_ms, (created + retention).to_unix_ms, name: "Punch::IdempotencyKeys.store")
      wide = Trace.event
      wide.set("punch.idempotency", "stored") if wide.recording?
    end

    private def self.refuse(context : HTTP::Context, status : ::HTTP::Status, code : String) : HTTP::Response
      context.span.set("punch.outcome", code)
      HTTP::Response.problem(status, context, code)
    end

    # Removes answers past their retention.
    def self.purge(db : Writer, now : Time = Time.utc) : Int64
      db.exec("DELETE FROM punch_idempotency_keys WHERE expires_at <= ?", now.to_unix_ms, name: "Punch::IdempotencyKeys.purge").changes
    end

    # Removes expired idempotency keys, every hour. Does nothing in an app
    # whose Commands take none.
    @[Punch::Job::Recurring(every: 1.hour)]
    struct Purge
      include Punch::Job

      def initialize
      end

      def perform(job : Punch::Job::Context) : Punch::Job::Result
        return unless IdempotencyKeys.used?

        removed = job.write { |db| IdempotencyKeys.purge(db, Time.utc) }
        Trace.event.set("punch.idempotency.purged", removed) if Trace.event.recording?
        nil
      end
    end
  end
end
