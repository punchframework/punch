require "openssl/hmac"
require "crypto/subtle"
require "digest/sha256"

module Punch
  # Time-based one-time passwords (RFC 6238) as authenticator apps make
  # them: HMAC-SHA1, six digits, a new code every 30 seconds. The secret is
  # 160 bits, the length RFC 4226 recommends and every app accepts.
  module Auth::TOTP
    DIGITS       =  6
    PERIOD       = 30
    SECRET_BYTES = 20
    # Codes one step before and after the current one are accepted too, for
    # clocks that drift and codes typed as they change.
    WINDOW = 1

    # The time step of *time*: what the code is computed from.
    def self.step(time : Time) : Int64
      time.to_unix // PERIOD
    end

    # The code for *step* (RFC 4226, HOTP with the step as counter).
    def self.code(secret : Bytes, step : Int64) : String
      counter = Bytes.new(8)
      IO::ByteFormat::BigEndian.encode(step, counter)
      mac = OpenSSL::HMAC.digest(:sha1, secret, counter)
      offset = mac[-1] & 0x0f
      binary = (mac[offset].to_u32 & 0x7f) << 24 | mac[offset + 1].to_u32 << 16 | mac[offset + 2].to_u32 << 8 | mac[offset + 3].to_u32
      (binary % 10_u32 ** DIGITS).to_s.rjust(DIGITS, '0')
    end

    # The code at *time*, for specs and the authenticator side.
    def self.code(secret : Bytes, time : Time) : String
      code(secret, step(time))
    end

    # The step within `WINDOW` of *now* whose code is *code*, if it is
    # later than *after*: a code works once (RFC 6238, section 5.2).
    def self.match(secret : Bytes, code : String, now : Time, after : Int64) : Int64?
      current = step(now)
      matched = nil
      (current - WINDOW..current + WINDOW).each do |candidate|
        next if candidate <= after
        # Every candidate is compared, so the time taken does not tell which matched.
        matched ||= candidate if ::Crypto::Subtle.constant_time_compare(code(secret, candidate).to_slice, code.to_slice)
      end
      matched
    end

    # The `otpauth://` URI that authenticator apps read from a QR code
    # (Google's Key Uri Format): *issuer* is the app's name, *account*
    # what the user knows the account by, such as the email address.
    def self.uri(secret : Bytes, *, issuer : String, account : String) : String
      label = "#{URI.encode_path_segment(issuer)}:#{URI.encode_path_segment(account)}"
      query = URI::Params.build do |params|
        params.add "secret", Auth::TOTP::Base32.encode(secret)
        params.add "issuer", issuer
        params.add "algorithm", "SHA1"
        params.add "digits", DIGITS.to_s
        params.add "period", PERIOD.to_s
      end
      "otpauth://totp/#{label}?#{query}"
    end
  end

  # Base32 as in RFC 4648, without padding: the alphabet of TOTP secrets.
  module Auth::TOTP::Base32
    ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"

    def self.encode(bytes : Bytes) : String
      String.build((bytes.size * 8 + 4) // 5) do |io|
        buffer = 0_u32
        bits = 0
        bytes.each do |byte|
          buffer = (buffer << 8) | byte
          bits += 8
          while bits >= 5
            bits -= 5
            io << ALPHABET[(buffer >> bits) & 0x1f]
          end
        end
        io << ALPHABET[(buffer << (5 - bits)) & 0x1f] if bits > 0
      end
    end

    # The bytes of *text* (either case, no padding), or `nil` if it is not
    # Base32.
    def self.decode(text : String) : Bytes?
      io = IO::Memory.new(text.size * 5 // 8)
      buffer = 0_u32
      bits = 0
      text.each_char do |char|
        value = ALPHABET.index(char.upcase) || return
        buffer = (buffer << 5) | value
        bits += 5
        if bits >= 8
          bits -= 8
          io.write_byte(((buffer >> bits) & 0xff).to_u8)
        end
      end
      io.to_slice
    end
  end

  # A code typed to prove the second factor: six digits from an
  # authenticator app, or a recovery code. Spaces and hyphens are ignored,
  # so codes can be typed as they are shown. Like a password, it never
  # prints and never serializes.
  struct Auth::OneTimeCode
    include Primitive(String)

    # A recovery code: 80 random bits as 16 lowercase Base32 characters,
    # shown as `abcd-efgh-ijkl-mnop`.
    RECOVERY_LENGTH = 16
    RECOVERY        = /\A[a-z2-7]{16}\z/
    TOTP_CODE       = /\A[0-9]{6}\z/
    MAX             = 32

    def self.json_schema
      {maxLength: MAX}
    end

    def self.parse(raw : String) : self | Invalid
      return Invalid.new("too_long", max: MAX) if raw.size > MAX

      text = raw.delete { |char| char.whitespace? || char == '-' }.downcase
      return Invalid.new("blank") if text.empty?

      TOTP_CODE.matches?(text) || RECOVERY.matches?(text) ? new(text) : Invalid.new("invalid_code")
    end

    # Six digits from an authenticator app.
    def totp? : Bool
      @value.size == Auth::TOTP::DIGITS
    end

    # A recovery code.
    def recovery? : Bool
      @value.size == RECOVERY_LENGTH
    end

    # The code, for the check. Call it at the point of use.
    def unwrap : String
      @value
    end

    private def value : String
      @value
    end

    def ==(other : self) : Bool
      Secret.new(@value) == Secret.new(other.unwrap)
    end

    def hash(hasher)
      {% raise "Punch::Auth::OneTimeCode cannot be hashed or used as a Hash key." %}
    end

    def to_s(io : IO) : Nil
      io << Secret::REDACTED
    end

    def inspect(io : IO) : Nil
      io << "Punch::Auth::OneTimeCode(" << Secret::REDACTED << ')'
    end

    def to_json(json : JSON::Builder) : Nil
      {% raise "Punch::Auth::OneTimeCode cannot be serialized to JSON: it would leave the process (lib/punch/docs/auth.md)." %}
    end
  end

  # The password was right and the user has a second factor: no session yet.
  # The browser holds a short-lived challenge in the `__Host-second-factor`
  # cookie, and a Command taking `Punch::Auth::SecondFactorCheck` completes
  # the sign-in with a code.
  struct Auth::SecondFactorRequired
    include JSON::Serializable

    # What to ask for: `totp` (an app's code, or a recovery code).
    getter second_factor = "totp"

    def initialize
    end
  end

  # 422 `invalid_code`: the code is not the user's current one, was used
  # already, or is not one of their recovery codes.
  @[Punch::Status(422)]
  struct Auth::InvalidCode
    include JSON::Serializable

    def initialize
    end
  end

  # 422 `second_factor_expired`: no sign-in waits for a second factor in
  # this browser (none began, or it is older than
  # `Auth::Config#second_factor_timeout`); sign in again.
  @[Punch::Status(422)]
  struct Auth::SecondFactorExpired
    include JSON::Serializable

    def initialize
    end
  end

  # 409 `second_factor_enabled`: the user has a confirmed authenticator
  # already; remove it before setting up another.
  @[Punch::Status(409)]
  struct Auth::SecondFactorEnabled
    include JSON::Serializable

    def initialize
    end
  end

  # The second step of a sign-in (docs/auth.md): the code typed after the
  # password, for the user whose challenge the browser holds. A Command
  # takes it with `Punch::Auth::Authentication`; its input has
  # `getter code : Punch::Auth::OneTimeCode`, and it has a rate limit
  # `by: :challenge`, counted per user:
  #
  # ```
  # def call(input : Input, db : Punch::Writer, auth : Punch::Auth::Authentication, second_factor : Punch::Auth::SecondFactorCheck) : SignedIn | Punch::Auth::InvalidCode | Punch::Auth::SecondFactorExpired
  #   case session = second_factor.sign_in(db, auth)
  #   in Punch::Auth::Session                                       then SignedIn.new(session.user_id(Users::ID))
  #   in Punch::Auth::InvalidCode, Punch::Auth::SecondFactorExpired then session
  #   end
  # end
  # ```
  class Auth::SecondFactorCheck
    # Whose challenge the browser holds, as found before the transaction:
    # the key of the `by: :challenge` limits.
    # :nodoc:
    getter user_id : Int64?

    # :nodoc:
    def initialize(@token : String?, @user_id : Int64?, @code : Auth::OneTimeCode)
    end

    # Uses up the challenge and checks the code, in *db*'s transaction;
    # on success, signs in through *auth* with the method of the first
    # step and the factor, such as `password+totp`. A failure writes
    # nothing (the Command rolls back), so the challenge stays for another
    # try within its limit.
    def sign_in(db : Writer, auth : Auth::Authentication, now : Time = Time.utc) : Auth::Session | Auth::InvalidCode | Auth::SecondFactorExpired
      token = @token || return Auth::SecondFactorExpired.new
      challenge = Auth::OneTimeTokens.consume(db, Auth::SecondFactors::CHALLENGE, token, now: now) || return Auth::SecondFactorExpired.new
      user_id = challenge.user_id || return Auth::SecondFactorExpired.new
      factor = Auth::SecondFactors.verify(db, user_id, @code, now) || return Auth::InvalidCode.new
      auth.complete_second_factor(user_id, "#{challenge.subject}+#{factor}")
    end
  end

  # The signed-in user's second factor, checked again (docs/auth.md): a
  # re-authentication, and changes to the factor itself. A Command takes
  # it with a required actor; its input has
  # `getter code : Punch::Auth::OneTimeCode`, and it has a rate limit
  # `by: :actor`:
  #
  # ```
  # factor = second_factor.confirm(db) || return Punch::Auth::InvalidCode.new
  # auth.renew(method: factor) # `totp` or `recovery_code`: a recent authentication
  # ```
  class Auth::OwnSecondFactorCheck
    # :nodoc:
    def initialize(@user_id : Int64?, @code : Auth::OneTimeCode)
    end

    # The factor that matched, `totp` or `recovery_code`, in *db*'s
    # transaction; `nil` when the code is wrong or the user has no
    # confirmed authenticator. A recovery code is used up.
    def confirm(db : Writer, now : Time = Time.utc) : String?
      user_id = @user_id || return
      Auth::SecondFactors.verify(db, user_id, @code, now)
    end
  end

  # A user's authenticator app, without its secret.
  struct Auth::TOTPAuthenticator
    getter user_id : Int64
    # `nil` until a code from the app confirmed it: until then it does not
    # count.
    getter confirmed_at : Time?
    getter created_at : Time
    # Recovery codes not used yet.
    getter recovery_codes : Int32
    # Whether new recovery codes wait to be shown (`Auth::SecondFactors.new_recovery_codes`).
    getter? unseen_codes : Bool

    def initialize(@user_id, @confirmed_at, @created_at, @recovery_codes, @unseen_codes)
    end

    def confirmed? : Bool
      !@confirmed_at.nil?
    end

    def to_json(json : JSON::Builder) : Nil
      json.object do
        json.field "user_id", user_id
        json.field "confirmed_at", confirmed_at
        json.field "created_at", created_at
        json.field "recovery_codes", recovery_codes
      end
    end
  end

  # What a user needs to add an authenticator app: the secret, as text and
  # in the URI of the QR code, and the recovery codes, shown while the
  # setup waits for its first code.
  struct Auth::TOTPSetup
    getter secret : Secret(Bytes)
    getter recovery_codes : Secret(Array(String))

    def initialize(@secret, @recovery_codes)
    end

    # The secret as typed into an app: Base32 in groups of four.
    def secret_text : Secret(String)
      @secret.map { |bytes| Auth::TOTP::Base32.encode(bytes).scan(/.{1,4}/).join(' ', &.[0]) }
    end

    # The `otpauth://` URI for the QR code.
    def uri(*, issuer : String, account : String) : Secret(String)
      @secret.map { |bytes| Auth::TOTP.uri(bytes, issuer: issuer, account: account) }
    end

    # The same as a link, which opens the authenticator app on the device
    # that shows the page: `v.a "Add to your app", href: setup.href(...)`.
    # It holds the secret, like the page.
    def href(*, issuer : String, account : String) : Href
      Href.new(uri(issuer: issuer, account: account).unwrap, nil)
    end
  end

  # The second factor (docs/auth.md): an authenticator app (TOTP) with
  # recovery codes, over `punch_totp_authenticators` and
  # `punch_recovery_codes`.
  #
  # The secret is stored encrypted with the key ring, in the format and
  # under the per-column key of column encryption (`Punch::Encrypted`;
  # Punch's own tables are not mapped), so a leaked database or replica
  # holds no usable secret. Recovery codes are stored as SHA-256 digests; a
  # new set is also kept encrypted until the user has seen it. Retiring the
  # key that encrypted them makes them unreadable: `punch db:encrypt` and
  # the nightly re-encryption job (`Database::Encryption`) move them to the
  # signing key first.
  module Auth::SecondFactors
    TABLE     = "punch_totp_authenticators"
    CODES     = "punch_recovery_codes"
    CHALLENGE = "second_factor"
    # Recovery codes per set.
    RECOVERY_CODES = 10
    # The factors a session's method can end with.
    FACTORS = {"totp", "recovery_code"}

    # The `column:` purposes of the key ring: one derived key each, so a
    # value moved to another column does not decrypt.
    SECRET_PURPOSE = "column:#{TABLE}.secret"
    CODES_PURPOSE  = "column:#{TABLE}.unseen_codes"

    # The secret of *user_id*'s authenticator does not decrypt: the key
    # that encrypted it was retired, or the row was changed. Raised, not
    # answered as a wrong code, so it is seen.
    class Undecryptable < Exception
    end

    # Begins setting up an authenticator app for *user_id*: a new secret
    # and recovery codes, replacing a setup that was not confirmed. Shown
    # by `setup` until `confirm`.
    def self.start(db : Writer, user_id : TypedID | Int64, *, now : Time = Time.utc) : Auth::TOTPSetup | Auth::SecondFactorEnabled
      raw = raw(user_id)
      return Auth::SecondFactorEnabled.new if enabled?(db, raw)

      secret = Random::Secure.random_bytes(Auth::TOTP::SECRET_BYTES)
      codes = Array.new(RECOVERY_CODES) { recovery_code }
      db.exec(<<-SQL, raw, encryptor(SECRET_PURPOSE).encrypt(secret), encryptor(CODES_PURPOSE).encrypt(codes.join('\n').to_slice), Stored.dump(now), name: "Punch::Auth::SecondFactors.start")
        INSERT INTO punch_totp_authenticators (user_id, secret, confirmed_at, last_step, unseen_codes, created_at)
        VALUES (?, ?, NULL, 0, ?, ?)
        ON CONFLICT (user_id) DO UPDATE SET secret = excluded.secret, last_step = 0, unseen_codes = excluded.unseen_codes,
          created_at = excluded.created_at
        SQL
      Auth::TOTPSetup.new(Secret.new(secret), Secret.new(codes))
    end

    # How long a setup waits for its first code.
    SETUP_LIFETIME = 1.hour

    # The setup of *user_id* that waits for its first code, as `start`
    # made it; `nil` when there is none, or it began more than
    # `SETUP_LIFETIME` ago and `start` must begin another.
    def self.setup(db : Reader | Writer, user_id : TypedID | Int64, *, now : Time = Time.utc) : Auth::TOTPSetup?
      found = db.query_one?("SELECT secret, unseen_codes FROM punch_totp_authenticators WHERE user_id = ? AND confirmed_at IS NULL AND created_at > ?",
        raw(user_id), Stored.dump(now - SETUP_LIFETIME), name: "Punch::Auth::SecondFactors.setup") { |row| {row.read(Bytes), row.read(Bytes?)} }
      return unless found

      secret = decrypt(SECRET_PURPOSE, found[0])
      codes = found[1].try { |sealed| String.new(decrypt(CODES_PURPOSE, sealed)).split('\n') } || [] of String
      Auth::TOTPSetup.new(Secret.new(secret), Secret.new(codes))
    end

    # Confirms the setup of *user_id* with a code from the app: from now
    # on the authenticator counts, and the recovery codes shown with the
    # setup work. Whether the code matched.
    def self.confirm(db : Writer, user_id : TypedID | Int64, code : Auth::OneTimeCode, *, now : Time = Time.utc) : Bool
      raw = raw(user_id)
      return false unless code.totp?

      pending = setup(db, raw, now: now) || return false
      step = Auth::TOTP.match(pending.secret.unwrap, code.unwrap, now, 0_i64) || return false
      db.exec("UPDATE punch_totp_authenticators SET confirmed_at = ?, last_step = ?, unseen_codes = NULL WHERE user_id = ?",
        Stored.dump(now), step, raw, name: "Punch::Auth::SecondFactors.confirm")
      store_codes(db, raw, pending.recovery_codes.unwrap, now)
      true
    end

    # Whether *user_id* has a confirmed authenticator, so that signing in
    # takes a second step.
    def self.enabled?(db : Reader | Writer, user_id : TypedID | Int64) : Bool
      db.query_one?("SELECT 1 FROM punch_totp_authenticators WHERE user_id = ? AND confirmed_at IS NOT NULL", raw(user_id),
        name: "Punch::Auth::SecondFactors.enabled?", &.read(Int64)) == 1
    end

    # *user_id*'s authenticator, confirmed or not, without its secret.
    def self.find(db : Reader | Writer, user_id : TypedID | Int64) : Auth::TOTPAuthenticator?
      db.query_one?(<<-SQL, raw(user_id), name: "Punch::Auth::SecondFactors.find") do |row|
        SELECT a.user_id, a.confirmed_at, a.created_at, a.unseen_codes IS NOT NULL,
               (SELECT count(*) FROM punch_recovery_codes AS c WHERE c.user_id = a.user_id)
        FROM punch_totp_authenticators AS a WHERE a.user_id = ?
        SQL
        user_id = row.read(Int64)
        confirmed_at = row.read(String?).try { |raw| Stored.load(Time, raw, TABLE, "confirmed_at", user_id) }
        created_at = Stored.load(Time, row.read(String), TABLE, "created_at", user_id)
        unseen = row.read(Int64) == 1
        Auth::TOTPAuthenticator.new(user_id, confirmed_at, created_at, row.read(Int64).to_i32, unseen)
      end
    end

    # Replaces the recovery codes of *user_id*'s confirmed authenticator
    # with a new set: the old ones stop working, and the new ones wait to be
    # shown (`new_recovery_codes`) until `seen`. Whether there was one.
    def self.regenerate(db : Writer, user_id : TypedID | Int64, *, now : Time = Time.utc) : Bool
      raw = raw(user_id)
      codes = Array.new(RECOVERY_CODES) { recovery_code }
      updated = db.exec("UPDATE punch_totp_authenticators SET unseen_codes = ? WHERE user_id = ? AND confirmed_at IS NOT NULL",
        encryptor(CODES_PURPOSE).encrypt(codes.join('\n').to_slice), raw, name: "Punch::Auth::SecondFactors.regenerate").changes > 0
      return false unless updated

      db.exec("DELETE FROM punch_recovery_codes WHERE user_id = ?", raw, name: "Punch::Auth::SecondFactors.regenerate")
      store_codes(db, raw, codes, now)
      true
    end

    # Recovery codes made by `regenerate` that the user has not confirmed
    # seeing; `nil` when none wait.
    def self.new_recovery_codes(db : Reader | Writer, user_id : TypedID | Int64) : Secret(Array(String))?
      sealed = db.query_one?("SELECT unseen_codes FROM punch_totp_authenticators WHERE user_id = ? AND confirmed_at IS NOT NULL",
        raw(user_id), name: "Punch::Auth::SecondFactors.new_recovery_codes", &.read(Bytes?)) || return
      Secret.new(String.new(decrypt(CODES_PURPOSE, sealed)).split('\n'))
    end

    # The user has seen the new recovery codes: only their digests remain.
    def self.seen(db : Writer, user_id : TypedID | Int64) : Nil
      db.exec("UPDATE punch_totp_authenticators SET unseen_codes = NULL WHERE user_id = ?", raw(user_id), name: "Punch::Auth::SecondFactors.seen")
    end

    # Removes *user_id*'s authenticator and recovery codes; whether there
    # was one. Signing in takes one step again.
    def self.remove(db : Writer, user_id : TypedID | Int64) : Bool
      raw = raw(user_id)
      db.exec("DELETE FROM punch_recovery_codes WHERE user_id = ?", raw, name: "Punch::Auth::SecondFactors.remove")
      db.exec("DELETE FROM punch_totp_authenticators WHERE user_id = ?", raw, name: "Punch::Auth::SecondFactors.remove").changes > 0
    end

    # Checks *code* against *user_id*'s confirmed authenticator: the
    # factor that matched, `totp` or `recovery_code`, or `nil`. A matched
    # app code moves the last step used, so it does not work twice; a
    # recovery code is deleted. Only through `Auth::SecondFactorCheck` and
    # `Auth::OwnSecondFactorCheck`, whose Commands are rate limited.
    # :nodoc:
    def self.verify(db : Writer, user_id : Int64, code : Auth::OneTimeCode, now : Time) : String?
      if code.recovery?
        return unless enabled?(db, user_id)

        # Under every key of the ring: codes stored before a rotation work.
        deleted = codes_index.digests(code.unwrap.to_slice).sum do |hash|
          db.exec("DELETE FROM punch_recovery_codes WHERE code_hash = ? AND user_id = ?", hash, user_id,
            name: "Punch::Auth::SecondFactors.verify").changes
        end
        return deleted > 0 ? "recovery_code" : nil
      end
      found = db.query_one?("SELECT secret, last_step FROM punch_totp_authenticators WHERE user_id = ? AND confirmed_at IS NOT NULL",
        user_id, name: "Punch::Auth::SecondFactors.verify") { |row| {row.read(Bytes), row.read(Int64)} } || return
      step = Auth::TOTP.match(decrypt(SECRET_PURPOSE, found[0]), code.unwrap, now, found[1]) || return
      db.exec("UPDATE punch_totp_authenticators SET last_step = ? WHERE user_id = ?", step, user_id, name: "Punch::Auth::SecondFactors.verify")
      "totp"
    end

    # The check for a request completing a sign-in: the challenge in its
    # cookie, and whose it is, looked up before the Command's transaction
    # for the `by: :challenge` limits.
    # :nodoc:
    def self.challenge(database : Database, context : HTTP::Context, code : Auth::OneTimeCode) : Auth::SecondFactorCheck
      token = context.request.cookies[Auth::CHALLENGE_COOKIE]?.try(&.value)
      user_id = token ? database.read { |db| Auth::OneTimeTokens.find(db, CHALLENGE, token).try(&.user_id) } : nil
      Auth::SecondFactorCheck.new(token, user_id, code)
    end

    # Whether a session's *method* (`password+totp`) included a second
    # factor.
    def self.factor?(method : String) : Bool
      method.split('+').any? { |part| FACTORS.includes?(part) }
    end

    # A recovery code as shown: `abcd-efgh-ijkl-mnop`.
    def self.format(code : String) : String
      code.scan(/.{1,4}/).join('-', &.[0])
    end

    private def self.store_codes(db : Writer, user_id : Int64, codes : Array(String), now : Time) : Nil
      time = Stored.dump(now)
      codes.each do |code|
        db.exec("INSERT INTO punch_recovery_codes (code_hash, user_id, created_at) VALUES (?, ?, ?)", digest(code), user_id, time,
          name: "Punch::Auth::SecondFactors.store_codes")
      end
    end

    private def self.recovery_code : String
      Auth::TOTP::Base32.encode(Random::Secure.random_bytes(10)).downcase
    end

    # A recovery code as stored: an HMAC under the key ring (purpose
    # `punch.recovery_code`), so a copy of the database alone cannot test
    # guesses against every user's codes at once.
    private def self.digest(code : String) : Bytes
      codes_index.digest(code.to_slice)
    end

    private def self.codes_index : KeyRing::BlindIndex
      KeyRing.current.blind_index("punch.recovery_code")
    end

    private def self.encryptor(purpose : String) : KeyRing::Encryptor
      KeyRing.current.encryptor(purpose)
    end

    private def self.decrypt(purpose : String, sealed : Bytes) : Bytes
      encryptor(purpose).decrypt(sealed) || raise Undecryptable.new("#{purpose} does not decrypt with the key ring")
    end

    private def self.raw(user_id : TypedID | Int64) : Int64
      user_id.is_a?(TypedID) ? user_id.value : user_id
    end

    # Brings the secrets and unseen codes of up to *limit* authenticators
    # after rowid *after* to the signing key (`Database::Encryption`);
    # `nil` when none is left.
    def self.reencrypt(db : Writer, after : Int64, limit : Int32, run : Database::Encryption) : Int64?
      rows = db.query_all("SELECT rowid, secret, unseen_codes FROM punch_totp_authenticators WHERE rowid > ? ORDER BY rowid LIMIT ?", after, limit.to_i64,
        name: "Punch::Auth::SecondFactors.reencrypt") { |row| {row.read(Int64), row.read(Bytes), row.read(Bytes?)} }
      rows.each do |(rowid, secret, codes)|
        run.row(TABLE)
        new_secret = run.encrypted(secret, TABLE, "secret", rowid) || secret
        new_codes = run.encrypted(codes, TABLE, "unseen_codes", rowid)
        next if {new_secret, new_codes} == {secret, codes}

        run.write(TABLE, rowid) do
          db.exec("UPDATE punch_totp_authenticators SET secret = ?, unseen_codes = ? WHERE rowid = ?", new_secret, new_codes, rowid, name: "Punch::Auth::SecondFactors.reencrypt")
        end
      end
      rows.last?.try(&.[0])
    end
  end

  Database::Encryption.table(Auth::SecondFactors::TABLE) { |db, after, limit, run| Auth::SecondFactors.reencrypt(db, after, limit, run) }
end
