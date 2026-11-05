module Punch
  # What a one-time token was issued for, returned when it is found or
  # used.
  struct Auth::OneTimeToken
    getter purpose : String
    # The user it was issued to, if there is one yet.
    getter user_id : Int64?
    # What it vouches for beyond the user, such as the email address a
    # verification link was sent to; checked against the current value
    # when the token is used.
    getter subject : String?
    getter created_at : Time
    getter expires_at : Time

    def initialize(@purpose, @user_id, @subject, @created_at, @expires_at)
    end
  end

  # Single-use tokens for password reset, email verification, and magic
  # links, over `punch_one_time_tokens`: random, stored as a digest, bound
  # to a purpose, and gone once used or expired.
  #
  # Links in mail are fetched by scanners before a person clicks them, so
  # the page behind a link only `find`s its token and shows a button; the
  # Command behind the button `consume`s it.
  module Auth::OneTimeTokens
    TABLE   = "punch_one_time_tokens"
    PURPOSE = /\A[a-z][a-z0-9_]{0,31}\z/

    # Issues a token for *purpose*, valid for *valid*. Returns the token,
    # which exists only here: put it into the link and nowhere else.
    def self.issue(db : Writer, purpose : String, valid : Time::Span, *, user_id : Int64? = nil, subject : String? = nil,
                   now : Time = Time.utc) : Secret(String)
      check_purpose(purpose)
      raise ArgumentError.new("a one-time token must be valid for a positive span") unless valid.positive?
      token = Auth::Token.generate
      db.exec(<<-SQL, Auth::Token.digest(token), purpose, user_id, subject, Stored.dump(now), Stored.dump(now + valid), name: "Punch::Auth::OneTimeTokens.issue")
        INSERT INTO punch_one_time_tokens (token_hash, purpose, user_id, subject, created_at, expires_at)
        VALUES (?, ?, ?, ?, ?, ?)
        SQL
      Secret.new(token)
    end

    # The live token *token* for *purpose*, without using it up.
    def self.find(db : Reader | Writer, purpose : String, token : String, *, now : Time = Time.utc) : Auth::OneTimeToken?
      check_purpose(purpose)
      return unless Auth::Token.well_formed?(token)
      db.query_one?(<<-SQL, Auth::Token.digest(token), purpose, Stored.dump(now), name: "Punch::Auth::OneTimeTokens.find") { |row| read(row) }
        SELECT purpose, user_id, subject, created_at, expires_at FROM punch_one_time_tokens
        WHERE token_hash = ? AND purpose = ? AND expires_at > ?
        SQL
    end

    # Uses up *token* for *purpose*: returns what it was issued for and
    # deletes it, in the Command's transaction, so it works once. `nil`
    # for an unknown, used, expired, or other-purpose token. An expired
    # token is deleted too.
    def self.consume(db : Writer, purpose : String, token : String, *, now : Time = Time.utc) : Auth::OneTimeToken?
      check_purpose(purpose)
      return unless Auth::Token.well_formed?(token)
      found = db.query_one?(<<-SQL, Auth::Token.digest(token), purpose, name: "Punch::Auth::OneTimeTokens.consume") { |row| read(row) }
        DELETE FROM punch_one_time_tokens WHERE token_hash = ? AND purpose = ?
        RETURNING purpose, user_id, subject, created_at, expires_at
        SQL
      found if found && found.expires_at > now
    end

    # Withdraws every token of *user_id* for *purpose*, such as older reset
    # links when a new one is sent. Returns how many.
    def self.revoke_all(db : Writer, purpose : String, user_id : Int64) : Int64
      check_purpose(purpose)
      db.exec("DELETE FROM punch_one_time_tokens WHERE purpose = ? AND user_id = ?", purpose, user_id,
        name: "Punch::Auth::OneTimeTokens.revoke_all").changes
    end

    # Deletes expired tokens. Returns how many.
    def self.purge(db : Writer, *, now : Time = Time.utc) : Int64
      db.exec("DELETE FROM punch_one_time_tokens WHERE expires_at <= ?", Stored.dump(now), name: "Punch::Auth::OneTimeTokens.purge").changes
    end

    private def self.check_purpose(purpose : String) : Nil
      raise ArgumentError.new("purpose must be lowercase letters, digits, and _, got #{purpose.inspect}") unless PURPOSE.matches?(purpose)
    end

    private def self.read(row : Database::Row) : Auth::OneTimeToken
      purpose = row.read(String)
      user_id = row.read(Int64?)
      subject = row.read(String?)
      created_at = Stored.load(Time, row.read(String), TABLE, "created_at", nil)
      expires_at = Stored.load(Time, row.read(String), TABLE, "expires_at", nil)
      Auth::OneTimeToken.new(purpose, user_id, subject, created_at, expires_at)
    end
  end
end
