module Punch
  # A signed-in browser session: a row in `punch_sessions` whose ID travels
  # in the `__Host-session` cookie. The row holds only the digest of that
  # ID, so sessions can be listed and revoked one by one, and signing
  # everyone out is a delete. Nothing here depends on the key ring: rotating
  # keys signs nobody out.
  struct Auth::Session
    # The row ID, safe to show and to name in `revoke`; never the cookie.
    getter id : Int64
    getter user_id : Int64
    # How the user signed in, such as `password` or `magic_link`.
    getter method : String
    # When the user last proved who they are, for policies that require a
    # recent sign-in. A renewal keeps it.
    getter authenticated_at : Time
    getter created_at : Time
    getter last_seen_at : Time
    # The end of the session's lifetime, whatever happens before.
    getter expires_at : Time
    getter ip : String?
    getter user_agent : String?

    def initialize(@id, @user_id, @method, @authenticated_at, @created_at, @last_seen_at, @expires_at, @ip, @user_agent)
    end

    # The user's ID as the app's typed ID: `session.user_id(Users::ID)`.
    def user_id(type : T.class) : T forall T
      type.parse(@user_id).as(T)
    end

    # Whether the user's last proof included a second factor
    # (`password+totp`).
    def second_factor? : Bool
      Auth::SecondFactors.factor?(method)
    end

    # The time after which the session ends unless it is used again.
    def idle_until(config : Auth::Config = Auth.config) : Time
      {last_seen_at + config.session_idle_timeout, expires_at}.min
    end

    def touch_due?(now : Time, config : Auth::Config = Auth.config) : Bool
      now - last_seen_at >= config.touch_interval
    end

    def to_json(json : JSON::Builder) : Nil
      json.object do
        json.field "id", id
        json.field "user_id", user_id
        json.field "method", method
        json.field "authenticated_at", authenticated_at
        json.field "created_at", created_at
        json.field "last_seen_at", last_seen_at
        json.field "expires_at", expires_at
        json.field "ip", ip
        json.field "user_agent", user_agent
      end
    end
  end

  # The session store over `punch_sessions` (docs/auth.md). Every function
  # takes the handle of the transaction it belongs to, so a sign-in commits
  # with the Command that made it.
  module Auth::Sessions
    TABLE      = "punch_sessions"
    COLUMNS    = "id, user_id, method, authenticated_at, created_at, last_seen_at, expires_at, ip, user_agent"
    METHOD     = /\A[a-z][a-z0-9_+]{0,31}\z/
    USER_AGENT = 256

    # Starts a session for *user_id*. Returns it with the value for the
    # cookie, which exists only here.
    def self.create(db : Writer, user_id : Int64, method : String, *, now : Time = Time.utc, ip : String? = nil,
                    user_agent : String? = nil, config : Auth::Config = Auth.config) : {Auth::Session, Secret(String)}
      raise ArgumentError.new("sign-in method must be lowercase letters, digits, _ and +, got #{method.inspect}") unless METHOD.matches?(method)
      token = Auth::Token.generate
      time = Stored.dump(now)
      agent = user_agent.try { |text| text.size > USER_AGENT ? text[0, USER_AGENT] : text }
      session = db.query_one?(<<-SQL, Auth::Token.digest(token), user_id, method, time, time, time, Stored.dump(now + config.session_lifetime), ip, agent, name: "Punch::Auth::Sessions.create") { |row| read(row) }
        INSERT INTO punch_sessions (token_hash, user_id, method, authenticated_at, created_at, last_seen_at, expires_at, ip, user_agent)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        RETURNING #{COLUMNS}
        SQL
      {session || raise("INSERT … RETURNING gave no row"), Secret.new(token)}
    end

    # The live session behind the cookie value *token*: neither idle for
    # longer than the idle timeout nor past its lifetime.
    def self.find(db : Reader | Writer, token : String, *, now : Time = Time.utc, config : Auth::Config = Auth.config) : Auth::Session?
      return unless Auth::Token.well_formed?(token)
      db.query_one?(<<-SQL, Auth::Token.digest(token), Stored.dump(now), Stored.dump(now - config.session_idle_timeout), name: "Punch::Auth::Sessions.find") { |row| read(row) }
        SELECT #{COLUMNS} FROM punch_sessions
        WHERE token_hash = ? AND expires_at > ? AND last_seen_at > ?
        SQL
    end

    # Records that *session* was used at *now*; returns it as stored.
    def self.touch(db : Writer, session : Auth::Session, *, now : Time = Time.utc) : Auth::Session
      db.exec("UPDATE punch_sessions SET last_seen_at = ? WHERE id = ?", Stored.dump(now), session.id, name: "Punch::Auth::Sessions.touch")
      Auth::Session.new(session.id, session.user_id, session.method, session.authenticated_at, session.created_at, now,
        session.expires_at, session.ip, session.user_agent)
    end

    # Gives *session* a new cookie value, for a change of privilege; the old
    # value stops working at once. With *method*, the user has just proved
    # who they are again: the method and `authenticated_at` change too.
    def self.renew(db : Writer, session : Auth::Session, *, method : String? = nil, now : Time = Time.utc) : {Auth::Session, Secret(String)}?
      token = Auth::Token.generate
      renewed = db.query_one?(<<-SQL, Auth::Token.digest(token), method, method, Stored.dump(now), Stored.dump(now), session.id, name: "Punch::Auth::Sessions.renew") { |row| read(row) }
        UPDATE punch_sessions
        SET token_hash = ?, method = coalesce(?, method),
            authenticated_at = CASE WHEN ? IS NULL THEN authenticated_at ELSE ? END, last_seen_at = ?
        WHERE id = ?
        RETURNING #{COLUMNS}
        SQL
      renewed ? {renewed, Secret.new(token)} : nil
    end

    # Ends one session; whether it existed. With *user_id*, only if it is
    # theirs, for a Command where users end their own.
    def self.revoke(db : Writer, id : Int64, *, user_id : Int64? = nil) : Bool
      db.exec("DELETE FROM punch_sessions WHERE id = ? AND (? IS NULL OR user_id = ?)", id, user_id, user_id,
        name: "Punch::Auth::Sessions.revoke").changes > 0
    end

    # Ends every session of *user_id* except *except*, as after a password
    # change. Returns how many ended.
    def self.revoke_all(db : Writer, user_id : Int64, *, except : Int64? = nil) : Int64
      db.exec("DELETE FROM punch_sessions WHERE user_id = ? AND id IS NOT ?", user_id, except, name: "Punch::Auth::Sessions.revoke_all").changes
    end

    # The live sessions of *user_id*, or of everyone, most recently used
    # first.
    def self.list(db : Reader | Writer, user_id : Int64? = nil, *, now : Time = Time.utc, config : Auth::Config = Auth.config) : Array(Auth::Session)
      db.query_all(<<-SQL, user_id, user_id, Stored.dump(now), Stored.dump(now - config.session_idle_timeout), name: "Punch::Auth::Sessions.list") { |row| read(row) }
        SELECT #{COLUMNS} FROM punch_sessions
        WHERE (? IS NULL OR user_id = ?) AND expires_at > ? AND last_seen_at > ?
        ORDER BY last_seen_at DESC, id DESC
        SQL
    end

    # Deletes sessions that can no longer be used. Returns how many.
    def self.purge(db : Writer, *, now : Time = Time.utc, config : Auth::Config = Auth.config) : Int64
      db.exec("DELETE FROM punch_sessions WHERE expires_at <= ? OR last_seen_at <= ?", Stored.dump(now),
        Stored.dump(now - config.session_idle_timeout), name: "Punch::Auth::Sessions.purge").changes
    end

    private def self.read(row : Database::Row) : Auth::Session
      id = row.read(Int64)
      Auth::Session.new(id, row.read(Int64), row.read(String), time(row, "authenticated_at", id), time(row, "created_at", id),
        time(row, "last_seen_at", id), time(row, "expires_at", id), row.read(String?), row.read(String?))
    end

    private def self.time(row : Database::Row, column : String, id : Int64) : Time
      Stored.load(Time, row.read(String), TABLE, column, id)
    end
  end
end
