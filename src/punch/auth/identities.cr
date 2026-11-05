module Punch
  # An email address a user is known by: a row in `punch_email_identities`.
  # A user can have several; an address belongs to one user. It counts as
  # proof of control only once verified.
  struct Auth::EmailIdentity
    getter id : Int64
    getter user_id : Int64
    getter email : Email
    getter verified_at : Time?
    getter created_at : Time

    def initialize(@id, @user_id, @email, @verified_at, @created_at)
    end

    def verified? : Bool
      !@verified_at.nil?
    end

    def to_json(json : JSON::Builder) : Nil
      json.object do
        json.field "id", id
        json.field "user_id", user_id
        json.field "email", email
        json.field "verified_at", verified_at
        json.field "created_at", created_at
      end
    end
  end

  # 409 `last_sign_in_method`: removing this would leave the user no way
  # to sign in. The Command's writes roll back.
  @[Punch::Status(409)]
  struct Auth::LastSignInMethod
    include JSON::Serializable

    def initialize
    end
  end

  # The email identities over `punch_email_identities` (docs/auth.md).
  module Auth::EmailIdentities
    TABLE   = "punch_email_identities"
    COLUMNS = "id, user_id, email, verified_at, created_at"

    # The address is another user's, or already this one's: 422 with
    # `taken` at `email`, like a unique violation of the app's own tables.
    # Sign-up says so openly; hiding which addresses have accounts takes a
    # confirmation mail first.
    struct EmailTaken
      include Database::Violation

      CONSTRAINT = "punch_email_identities.email"
      FIELD      = "email"
    end

    # Adds *email* to *user_id*, unverified unless *verified_at* is given.
    def self.add(db : Writer, user_id : TypedID | Int64, email : Email, *, verified_at : Time? = nil,
                 now : Time = Time.utc) : Auth::EmailIdentity | EmailTaken
      raw = user_id.is_a?(TypedID) ? user_id.value : user_id
      # `ON CONFLICT DO NOTHING` returns no row, so a taken address is told
      # apart without raising and rescuing.
      found = db.query_one?(<<-SQL, raw, email.value, verified_at.try { |time| Stored.dump(time) }, Stored.dump(now), name: "Punch::Auth::EmailIdentities.add") { |row| read(row) }
        INSERT INTO punch_email_identities (user_id, email, verified_at, created_at) VALUES (?, ?, ?, ?)
        ON CONFLICT (email) DO NOTHING
        RETURNING #{COLUMNS}
        SQL
      found || EmailTaken.new
    end

    # The identity of *email*, whoever's it is.
    def self.find(db : Reader | Writer, email : Email) : Auth::EmailIdentity?
      db.query_one?("SELECT #{COLUMNS} FROM punch_email_identities WHERE email = ?", email.value,
        name: "Punch::Auth::EmailIdentities.find") { |row| read(row) }
    end

    # The identities of *user_id*, oldest first.
    def self.list(db : Reader | Writer, user_id : TypedID | Int64) : Array(Auth::EmailIdentity)
      raw = user_id.is_a?(TypedID) ? user_id.value : user_id
      db.query_all("SELECT #{COLUMNS} FROM punch_email_identities WHERE user_id = ? ORDER BY id", raw,
        name: "Punch::Auth::EmailIdentities.list") { |row| read(row) }
    end

    # Removes the identity *id* of *user_id*, unless it is the user's last
    # way to sign in (checked here, in the Command's transaction): the user
    # keeps at least one address, and once one is verified, at least one
    # verified address, since an unverified one may be mistyped. `nil` when
    # the user has no such identity.
    def self.remove(db : Writer, user_id : TypedID | Int64, id : Int64) : Auth::EmailIdentity | Auth::LastSignInMethod?
      identities = list(db, user_id)
      target = identities.find(&.id.==(id)) || return
      rest = identities.reject(&.id.==(id))
      return Auth::LastSignInMethod.new if rest.empty? || (target.verified? && rest.none?(&.verified?))

      db.exec("DELETE FROM punch_email_identities WHERE id = ?", id, name: "Punch::Auth::EmailIdentities.remove")
      target
    end

    # Marks *email* verified, as a verification link does; whether it
    # exists. The account's first verified address also ends what came
    # before it (`claimed`).
    def self.verify(db : Writer, email : Email, *, now : Time = Time.utc) : Bool
      identity = find(db, email) || return false
      first = !verified?(db, identity.user_id)
      db.exec("UPDATE punch_email_identities SET verified_at = coalesce(verified_at, ?) WHERE id = ?",
        Stored.dump(now), identity.id, name: "Punch::Auth::EmailIdentities.verify")
      claimed(db, identity) if first
      true
    end

    # Whether *user_id* has a verified address. Until then, nobody has
    # shown that the account belongs to the owner of any of its addresses,
    # so a password does not sign in to it (docs/auth.md).
    def self.verified?(db : Reader | Writer, user_id : TypedID | Int64) : Bool
      raw = user_id.is_a?(TypedID) ? user_id.value : user_id
      db.query_one?("SELECT 1 FROM punch_email_identities WHERE user_id = ? AND verified_at IS NOT NULL LIMIT 1", raw,
        name: "Punch::Auth::EmailIdentities.verified?", &.read(Int64)) == 1
    end

    # The account's first verified address: whoever claimed the address
    # before its owner may have set things up, so the user's other
    # unverified addresses, every session, and every API token end.
    private def self.claimed(db : Writer, identity : Auth::EmailIdentity) : Nil
      db.exec("DELETE FROM punch_email_identities WHERE user_id = ? AND id <> ? AND verified_at IS NULL", identity.user_id, identity.id,
        name: "Punch::Auth::EmailIdentities.claimed")
      Auth::Sessions.revoke_all(db, identity.user_id)
      Auth::APITokens.revoke_all(db, identity.user_id)
    end

    private def self.read(row : Database::Row) : Auth::EmailIdentity
      id = row.read(Int64)
      user_id = row.read(Int64)
      email = Stored.load(Email, row.read(String), TABLE, "email", id)
      verified_at = row.read(String?).try { |raw| Stored.load(Time, raw, TABLE, "verified_at", id) }
      created_at = Stored.load(Time, row.read(String), TABLE, "created_at", id)
      Auth::EmailIdentity.new(id, user_id, email, verified_at, created_at)
    end
  end
end
