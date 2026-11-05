module Punch
  # A bearer token for API clients and agents: a row in `punch_api_tokens`.
  # It acts as its user, always expires, and records
  # when it was last used. The token itself is shown once, at creation;
  # the row holds its digest.
  struct Auth::APIToken
    getter id : Int64
    getter user_id : Int64
    # What the user called it, to tell their tokens apart.
    getter name : String
    getter created_at : Time
    getter expires_at : Time
    getter last_used_at : Time?

    def initialize(@id, @user_id, @name, @created_at, @expires_at, @last_used_at)
    end

    def touch_due?(now : Time, config : Auth::Config = Auth.config) : Bool
      used = last_used_at || return true
      now - used >= config.touch_interval
    end

    def to_json(json : JSON::Builder) : Nil
      json.object do
        json.field "id", id
        json.field "user_id", user_id
        json.field "name", name
        json.field "created_at", created_at
        json.field "expires_at", expires_at
        json.field "last_used_at", last_used_at
      end
    end
  end

  # The token store over `punch_api_tokens` (docs/auth.md).
  #
  # A token reads `<prefix>_<43 characters><6 characters>`: the app's
  # prefix (`Auth::Config#token_prefix`), 256 random bits in base62, and a
  # CRC-32 of everything before it, also in base62. The checksum lets
  # Punch refuse a mistyped or made-up token without a lookup, and lets a
  # secret scanner recognize a real one, as GitHub's tokens do.
  module Auth::APITokens
    TABLE    = "punch_api_tokens"
    COLUMNS  = "id, user_id, name, created_at, expires_at, last_used_at"
    CHECKSUM = 6
    NAME     = 1..100

    # Creates a token for *user_id* that expires at *expires_at*, at most
    # `token_max_lifetime` from *now*. Returns the row and the token, which
    # exists only here; `Invalid` for an empty or long name (`blank`,
    # `too_long`) or an expiry out of range (`out_of_range`).
    def self.create(db : Writer, user_id : Int64, name : String, expires_at : Time, *, now : Time = Time.utc,
                    config : Auth::Config = Auth.config) : {Auth::APIToken, Secret(String)} | Invalid
      name = name.strip
      return Invalid.new("blank") if name.empty?
      return Invalid.new("too_long", max: NAME.end) if name.size > NAME.end
      unless expires_at > now && expires_at <= now + config.token_max_lifetime
        return Invalid.new("out_of_range", max_days: config.token_max_lifetime.total_days.to_i)
      end

      token = generate(config.token_prefix)
      row = db.query_one?(<<-SQL, Auth::Token.digest(token), user_id, name, Stored.dump(now), Stored.dump(expires_at), name: "Punch::Auth::APITokens.create") { |row| read(row) }
        INSERT INTO punch_api_tokens (token_hash, user_id, name, created_at, expires_at)
        VALUES (?, ?, ?, ?, ?)
        RETURNING #{COLUMNS}
        SQL
      {row || raise("INSERT … RETURNING gave no row"), Secret.new(token)}
    end

    # The live token *token*, or `nil` for a malformed, unknown, revoked, or
    # expired one.
    def self.find(db : Reader | Writer, token : String, *, now : Time = Time.utc, config : Auth::Config = Auth.config) : Auth::APIToken?
      return unless well_formed?(token, config.token_prefix)
      db.query_one?(<<-SQL, Auth::Token.digest(token), Stored.dump(now), name: "Punch::Auth::APITokens.find") { |row| read(row) }
        SELECT #{COLUMNS} FROM punch_api_tokens WHERE token_hash = ? AND expires_at > ?
        SQL
    end

    # Records that *token* was used at *now*.
    def self.touch(db : Writer, token : Auth::APIToken, *, now : Time = Time.utc) : Auth::APIToken
      db.exec("UPDATE punch_api_tokens SET last_used_at = ? WHERE id = ?", Stored.dump(now), token.id, name: "Punch::Auth::APITokens.touch")
      Auth::APIToken.new(token.id, token.user_id, token.name, token.created_at, token.expires_at, now)
    end

    # Revokes one token; whether it existed. With *user_id*, only if it is
    # theirs, for a Command where users revoke their own.
    def self.revoke(db : Writer, id : Int64, *, user_id : Int64? = nil) : Bool
      db.exec("DELETE FROM punch_api_tokens WHERE id = ? AND (? IS NULL OR user_id = ?)", id, user_id, user_id,
        name: "Punch::Auth::APITokens.revoke").changes > 0
    end

    # Revokes every token of *user_id*. Returns how many.
    def self.revoke_all(db : Writer, user_id : Int64) : Int64
      db.exec("DELETE FROM punch_api_tokens WHERE user_id = ?", user_id, name: "Punch::Auth::APITokens.revoke_all").changes
    end

    # The live tokens of *user_id*, or of everyone, newest first.
    def self.list(db : Reader | Writer, user_id : Int64? = nil, *, now : Time = Time.utc) : Array(Auth::APIToken)
      db.query_all(<<-SQL, user_id, user_id, Stored.dump(now), name: "Punch::Auth::APITokens.list") { |row| read(row) }
        SELECT #{COLUMNS} FROM punch_api_tokens
        WHERE (? IS NULL OR user_id = ?) AND expires_at > ?
        ORDER BY id DESC
        SQL
    end

    # Deletes expired tokens. Returns how many.
    def self.purge(db : Writer, *, now : Time = Time.utc) : Int64
      db.exec("DELETE FROM punch_api_tokens WHERE expires_at <= ?", Stored.dump(now), name: "Punch::Auth::APITokens.purge").changes
    end

    # A fresh token with *prefix* and its checksum.
    def self.generate(prefix : String) : String
      body = "#{prefix}_#{Auth::Token.generate}"
      body + checksum(body)
    end

    # Whether *token* has the prefix, length, alphabet, and checksum of a
    # token from `generate`.
    def self.well_formed?(token : String, prefix : String) : Bool
      return false unless token.bytesize == prefix.bytesize + 1 + Auth::Token::LENGTH + CHECKSUM
      return false unless token.starts_with?(prefix) && token.byte_at(prefix.bytesize) == '_'.ord

      body = token.byte_slice(0, token.bytesize - CHECKSUM)
      tail = token.byte_slice(token.bytesize - CHECKSUM)
      Auth::Token.base62?(body.byte_slice(prefix.bytesize + 1)) && tail == checksum(body)
    end

    private def self.checksum(body : String) : String
      Auth::Token.base62(Digest::CRC32.checksum(body), CHECKSUM)
    end

    private def self.read(row : Database::Row) : Auth::APIToken
      id = row.read(Int64)
      user_id = row.read(Int64)
      name = row.read(String)
      created_at = Stored.load(Time, row.read(String), TABLE, "created_at", id)
      expires_at = Stored.load(Time, row.read(String), TABLE, "expires_at", id)
      last_used_at = row.read(String?).try { |raw| Stored.load(Time, raw, TABLE, "last_used_at", id) }
      Auth::APIToken.new(id, user_id, name, created_at, expires_at, last_used_at)
    end
  end
end
