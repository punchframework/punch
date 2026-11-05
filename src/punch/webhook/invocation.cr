module Punch::Webhook
  # A stored delivery and where it is in its life (a tier-2 model): one type
  # per state, transitions as methods.
  #
  # ```text
  # Received ──verify──> Verified ──> Processed | Ignored | Discarded | Failed | Unprocessable
  #     └──────────────> Rejected
  # ```
  #
  # Only a `Verified` invocation reaches the provider's `parse` and
  # `process`, so unverified data can never be processed. Edge-verified
  # deliveries are stored as `Verified`.
  module Invocation
    # What every state knows. Modules rather than a parent struct: Crystal
    # merges a union of structs with a common parent into the parent, and
    # the states must stay apart in unions.
    module State
      getter id : Int64
      getter provider : String
      getter key : String
      getter received_at : Time
      # Processing attempts so far.
      getter attempts : Int32
      # Why the last attempt did not process it, or why it ended.
      getter error : String?

      # The state's name as stored: `received`, `verified`, ….
      abstract def state : String
    end

    # An end state.
    module Finished
      include State

      getter finished_at : Time
    end

    # Stored, its signature not checked yet (`verify: :deferred`).
    struct Received
      include State

      getter request : RawRequest

      def initialize(@id, @provider, @key, @received_at, @attempts, @error, @request)
      end

      def state : String
        "received"
      end

      # Checks the signature as of when the request arrived, so the
      # timestamp tolerance does not count the time spent waiting.
      def verify(verifier : Verifier, now : Time) : Verified | Rejected
        if verifier.verify(@request, received_at)
          Verified.new(id, provider, key, received_at, attempts, nil, @request, now)
        else
          rejected("invalid_signature", now)
        end
      end

      def rejected(reason : String, now : Time) : Rejected
        Rejected.new(id, provider, key, received_at, attempts, reason, now)
      end
    end

    # Authentic, to be processed.
    struct Verified
      include State

      getter request : RawRequest
      getter verified_at : Time

      def initialize(@id, @provider, @key, @received_at, @attempts, @error, @request, @verified_at)
      end

      def state : String
        "verified"
      end

      def processed(at : Time) : Processed
        Processed.new(id, provider, key, received_at, attempts + 1, nil, at)
      end

      def ignored(reason : String, at : Time) : Ignored
        Ignored.new(id, provider, key, received_at, attempts + 1, reason, at)
      end

      def discarded(reason : String, at : Time) : Discarded
        Discarded.new(id, provider, key, received_at, attempts + 1, reason, at)
      end

      def failed(reason : String, at : Time) : Failed
        Failed.new(id, provider, key, received_at, attempts + 1, reason, at)
      end

      def unprocessable(reason : String, at : Time) : Unprocessable
        Unprocessable.new(id, provider, key, received_at, attempts + 1, reason, at)
      end

      # Another attempt will follow.
      def retrying(reason : String) : Verified
        Verified.new(id, provider, key, received_at, attempts + 1, reason, @request, @verified_at)
      end
    end

    {% for name, doc in {Processed: "", Ignored: "An event the app does not handle; `error` says which.",
                         Discarded: "Nothing left to do, said `process`; `error` says why.", Failed: "",
                         Unprocessable: "", Rejected: "Its signature did not hold when checked later (`verify: :deferred`)."} %}
      {% unless doc.empty? %}
        # {{ doc.id }}
      {% end %}
      struct {{ name.id }}
        include Finished

        def initialize(@id, @provider, @key, @received_at, @attempts, @error, @finished_at)
        end

        def state : String
          {{ name.stringify.underscore }}
        end
      end
    {% end %}

    alias Any = Received | Verified | Processed | Ignored | Discarded | Failed | Unprocessable | Rejected
  end

  # Stored invocations in `punch_webhooks` (the store of the tier-2 model).
  # Punch's own table in the app's migrations, like the outbox.
  module Invocations
    STATES = %w[received verified processed ignored discarded failed unprocessable rejected]

    COLUMNS = {
      "id" => "INTEGER", "provider" => "TEXT", "key" => "TEXT", "fingerprint" => "BLOB", "state" => "TEXT",
      "body" => "BLOB", "headers" => "TEXT", "attempts" => "INTEGER", "error" => "TEXT",
      "received_at" => "INTEGER", "verified_at" => "INTEGER", "finished_at" => "INTEGER",
    }

    # The table as a migration. `punch db:migration --punch` writes it as a migration.
    def self.sql : String
      <<-SQL
        -- Inbound webhooks: each delivery as received, and where its
        -- processing is (lib/punch/docs/webhooks.md). The columns are Punch's.
        CREATE TABLE punch_webhooks (
          id          INTEGER PRIMARY KEY,
          provider    TEXT    NOT NULL,
          key         TEXT    NOT NULL,
          fingerprint BLOB    NOT NULL,
          state       TEXT    NOT NULL,
          body        BLOB    NOT NULL,
          headers     TEXT    NOT NULL,
          attempts    INTEGER NOT NULL,
          error       TEXT,
          received_at INTEGER NOT NULL,
          verified_at INTEGER,
          finished_at INTEGER,
          UNIQUE (provider, key)
        ) STRICT;

        CREATE INDEX punch_webhooks_by_state ON punch_webhooks (provider, state);
        CREATE INDEX punch_webhooks_finished ON punch_webhooks (finished_at) WHERE finished_at IS NOT NULL;

        SQL
    end

    # What is missing or of another type, one line each.
    def self.problems(database : Database) : Array(String)
      found = database.read do |db|
        db.query_all("SELECT name, type FROM pragma_table_info('punch_webhooks')", name: "Punch::Webhook::Invocations.columns") do |row|
          {row.read(String), row.read(String).upcase}
        end.to_h
      end
      return ["table punch_webhooks is missing; add it with a migration (lib/punch/docs/webhooks.md)"] if found.empty?

      COLUMNS.compact_map do |column, type|
        if actual = found[column]?
          "punch_webhooks.#{column} is #{actual}, Punch needs #{type}" unless actual == type
        else
          "punch_webhooks.#{column} is missing (lib/punch/docs/webhooks.md)"
        end
      end
    end

    # A delivery stored before under the key, with the same payload.
    struct Duplicate
      getter id : Int64

      def initialize(@id)
      end
    end

    # A delivery stored before under the key, with another payload.
    struct Conflict
      getter id : Int64

      def initialize(@id)
      end
    end

    # Stores a delivery: its ID, or what was stored under the key before.
    # The unique index on provider and key decides; the payload's hash
    # tells a repeat from a conflict.
    def self.receive(db : Writer, provider : String, key : String, fingerprint : Bytes, request : RawRequest,
                     kept : Array(String), now : Time, verified : Bool) : Int64 | Duplicate | Conflict
      headers = JSON.build do |json|
        json.object do
          kept.uniq.sort!.each { |name| request.header(name).try { |value| json.field name.downcase, value } }
        end
      end
      id = db.query_one?(<<-SQL, provider, key, fingerprint, verified ? "verified" : "received", request.body.to_slice, headers,
        INSERT INTO punch_webhooks (provider, key, fingerprint, state, body, headers, attempts, received_at, verified_at)
        VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?)
        ON CONFLICT (provider, key) DO NOTHING
        RETURNING id
        SQL
        now.to_unix_ms, verified ? now.to_unix_ms : nil, name: "Punch::Webhook::Invocations.receive", &.read(Int64))
      return id if id

      stored = db.query_one?("SELECT id, fingerprint FROM punch_webhooks WHERE provider = ? AND key = ?", provider, key,
        name: "Punch::Webhook::Invocations.stored") { |row| {row.read(Int64), row.read(Bytes)} }
      raise Database::Error.new("punch_webhooks: no row under #{provider}/#{key} after a conflict", code: 1) unless stored
      stored[1] == fingerprint ? Duplicate.new(stored[0]) : Conflict.new(stored[0])
    end

    # The invocation *id* in its state, or `nil` when it is gone.
    def self.load(db : Reader | Writer, id : Int64) : Invocation::Any?
      db.query_one?(<<-SQL, id, name: "Punch::Webhook::Invocations.load") do |row|
        SELECT id, provider, key, state, body, headers, attempts, error, received_at, verified_at, finished_at
        FROM punch_webhooks WHERE id = ?
        SQL
        id, provider, key, state = row.read(Int64), row.read(String), row.read(String), row.read(String)
        body, headers, attempts, error = row.read(Bytes), row.read(String), row.read(Int64).to_i32, row.read(String?)
        received_at, verified_at, finished_at = Time.unix_ms(row.read(Int64)), row.read(Int64?), row.read(Int64?)
        finished = Time.unix_ms(finished_at || 0_i64)

        case state
        when "received"      then Invocation::Received.new(id, provider, key, received_at, attempts, error, request(body, headers))
        when "verified"      then Invocation::Verified.new(id, provider, key, received_at, attempts, error, request(body, headers), Time.unix_ms(verified_at || 0_i64))
        when "processed"     then Invocation::Processed.new(id, provider, key, received_at, attempts, error, finished)
        when "ignored"       then Invocation::Ignored.new(id, provider, key, received_at, attempts, error, finished)
        when "discarded"     then Invocation::Discarded.new(id, provider, key, received_at, attempts, error, finished)
        when "failed"        then Invocation::Failed.new(id, provider, key, received_at, attempts, error, finished)
        when "unprocessable" then Invocation::Unprocessable.new(id, provider, key, received_at, attempts, error, finished)
        when "rejected"      then Invocation::Rejected.new(id, provider, key, received_at, attempts, error, finished)
        else                      raise Database::Error.new("punch_webhooks #{id}: unknown state #{state.inspect}", code: 1)
        end
      end
    end

    # Writes *invocation*'s state back.
    # Whether the invocation *id* still waits to be processed (`received`
    # while a deferred check runs, or `verified`), in *db*'s transaction.
    def self.waiting?(db : Writer, id : Int64) : Bool
      db.query_one?("SELECT state FROM punch_webhooks WHERE id = ?", id, name: "Punch::Webhook::Invocations.waiting?", &.read(String)).in?("received", "verified")
    end

    def self.save(db : Writer, invocation : Invocation::Any) : Nil
      verified_at = invocation.is_a?(Invocation::Verified) ? invocation.verified_at.to_unix_ms : nil
      finished_at = invocation.is_a?(Invocation::Finished) ? invocation.finished_at.to_unix_ms : nil
      db.exec(<<-SQL, invocation.state, invocation.attempts.to_i64, invocation.error, verified_at, finished_at, invocation.id,
        UPDATE punch_webhooks SET state = ?, attempts = ?, error = ?, verified_at = coalesce(?, verified_at), finished_at = ?
        WHERE id = ?
        SQL
        name: "Punch::Webhook::Invocations.save")
    end

    # Removes processed, ignored, discarded, and rejected invocations finished before
    # *before*. Failed and unprocessable ones stay until someone has looked
    # (the console).
    def self.purge(db : Writer, before : Time) : Int64
      db.exec("DELETE FROM punch_webhooks WHERE finished_at < ? AND state IN ('processed', 'ignored', 'discarded', 'rejected')",
        before.to_unix_ms, name: "Punch::Webhook::Invocations.purge").changes
    end

    # An invocation as the ops console lists it, without its body.
    record Listed, id : Int64, provider : String, key : String, state : String, attempts : Int32, error : String?,
      received_at : Time, finished_at : Time? do
      include JSON::Serializable
    end

    # An invocation with the request as stored: the body and the headers
    # the provider keeps.
    record Stored, listed : Listed, body : Bytes, headers : Hash(String, String), verified_at : Time?

    # The latest invocations, newest first, of one provider or all, in one
    # state or all.
    def self.list(db : Reader | Writer, *, provider : String? = nil, state : String? = nil, limit : Int32 = 50) : Array(Listed)
      db.query_all(<<-SQL, provider, state, limit.to_i64, name: "Punch::Webhook::Invocations.list") { |row| listed(row) }
        SELECT id, provider, key, state, attempts, error, received_at, finished_at FROM punch_webhooks
        WHERE (?1 IS NULL OR provider = ?1) AND (?2 IS NULL OR state = ?2)
        ORDER BY id DESC LIMIT ?3
        SQL
    end

    # One invocation with its stored request, or `nil`.
    def self.stored(db : Reader | Writer, id : Int64) : Stored?
      db.query_one?(<<-SQL, id, name: "Punch::Webhook::Invocations.find") do |row|
        SELECT id, provider, key, state, attempts, error, received_at, finished_at, body, headers, verified_at
        FROM punch_webhooks WHERE id = ?
        SQL
        listed = listed(row)
        body = row.read(Bytes)
        headers = JSON.parse(row.read(String)).as_h.transform_values(&.as_s)
        Stored.new(listed, body, headers, row.read(Int64?).try { |millis| Time.unix_ms(millis) })
      end
    end

    private def self.listed(row : Database::Row) : Listed
      Listed.new(row.read(Int64), row.read(String), row.read(String), row.read(String), row.read(Int64).to_i32, row.read(String?),
        Time.unix_ms(row.read(Int64)), row.read(Int64?).try { |millis| Time.unix_ms(millis) })
    end

    # States from which an invocation can be processed again (`again`):
    # an end that a fix may change (retry), or one that processed or
    # ignored it (replay).
    RETRY  = %w[failed unprocessable rejected]
    REPLAY = %w[processed ignored discarded]

    # Moves the invocation *id* back to be processed, when it is in one of
    # *from*: a rejected one to `received` (its signature is checked
    # again, as of its receipt), others to `verified`. Returns the
    # provider, or `nil` when no such invocation is in those states. The
    # caller enqueues `Process` in the same transaction.
    def self.again(db : Writer, id : Int64, from : Array(String)) : String?
      db.query_one?(<<-SQL, id, Database::Values.new(from), name: "Punch::Webhook::Invocations.again", &.read(String))
        UPDATE punch_webhooks
        SET state = CASE state WHEN 'rejected' THEN 'received' ELSE 'verified' END, error = NULL, finished_at = NULL
        WHERE id = ?1 AND state IN carray(?2)
        RETURNING provider
        SQL
    end

    # Invocations per provider and state, for `punch webhooks`.
    def self.counts(db : Reader) : Array({String, String, Int64})
      db.query_all("SELECT provider, state, count(*) FROM punch_webhooks GROUP BY provider, state ORDER BY provider, state",
        name: "Punch::Webhook::Invocations.counts") { |row| {row.read(String), row.read(String), row.read(Int64)} }
    end

    private def self.request(body : Bytes, headers : String) : RawRequest
      parsed = ::HTTP::Headers.new
      JSON.parse(headers).as_h.each { |name, value| parsed[name] = value.as_s }
      RawRequest.new(String.new(body), parsed)
    end
  end
end
