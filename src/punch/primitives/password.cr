module Punch
  # A password as typed, for a sign-in. It never prints, never serializes,
  # and is not echoed back into a form; `unwrap` is the one way to the text,
  # for the hasher.
  #
  # Parsing normalizes to NFKC (NIST SP 800-63B), so a password typed with
  # composed or decomposed accents is one password, and keeps surrounding
  # spaces, which belong to it. A sign-in accepts any length within the cap,
  # so a password set under older rules still works; `Auth::NewPassword` holds
  # the rules for new ones.
  struct Auth::Password
    include Primitive(String)

    # At most this many characters and `MAX_BYTES` bytes after
    # normalization: enough for any passphrase, and a bound on the work
    # before hashing. PBKDF2's cost does not grow with the length.
    MAX       =  256
    MAX_BYTES = 1024

    def self.json_schema
      {format: "password", maxLength: MAX}
    end

    def self.parse(raw : String) : self | Invalid
      text = normalize(raw)
      text.is_a?(Invalid) ? text : new(text)
    end

    # :nodoc:
    def self.normalize(raw : String) : String | Invalid
      return Invalid.new("invalid_encoding") unless raw.valid_encoding?
      return Invalid.new("invalid_characters") if Text::FORBIDDEN.matches?(raw)

      text = raw.unicode_normalize(:nfkc)
      return Invalid.new("blank") if text.blank?
      return Invalid.new("too_long", max: MAX) if text.size > MAX || text.bytesize > MAX_BYTES

      text
    end

    # The text, for hashing. Call it at the point of use, never earlier.
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
      {% raise "Punch::Auth::Password cannot be hashed or used as a Hash key." %}
    end

    def to_s(io : IO) : Nil
      io << Secret::REDACTED
    end

    def inspect(io : IO) : Nil
      io << "Punch::Auth::Password(" << Secret::REDACTED << ')'
    end

    def to_json(json : JSON::Builder) : Nil
      {% raise "Punch::Auth::Password cannot be serialized to JSON: it would leave the process (lib/punch/docs/auth.md)." %}
    end
  end

  # A password being set: at sign-up, a change, or a reset. Like
  # `Auth::Password`, plus a minimum length. The router hashes it on the
  # password hasher before the Command's transaction opens, so `hashed`
  # costs nothing inside it:
  #
  # ```
  # Punch::Auth::Passwords.set(db, user.id, input.password.hashed)
  # ```
  #
  # Called outside a request (a spec, a script), `hashed` hashes on the
  # calling fiber.
  class Auth::NewPassword
    include Primitive(String)

    # NIST SP 800-63B asks for at least 8 characters, 15 when the password
    # is the only factor; 12 is Punch's default between the two.
    MIN = 12

    def self.json_schema
      {format: "password", minLength: MIN, maxLength: Auth::Password::MAX}
    end

    def self.parse(raw : String) : self | Invalid
      text = Auth::Password.normalize(raw)
      return text if text.is_a?(Invalid)
      return Invalid.new("too_short", min: MIN) if text.size < MIN

      new(text)
    end

    @hashed : Auth::PasswordHash?
    @lock = Mutex.new

    # The stored form, hashed once.
    def hashed : Auth::PasswordHash
      @lock.synchronize { @hashed ||= Auth::Passwords.hash_now(@value) }
    end

    # :nodoc:
    def hashed? : Bool
      !@hashed.nil?
    end

    # :nodoc:
    def hashed=(hash : Auth::PasswordHash) : Nil
      @lock.synchronize { @hashed = hash }
    end

    # The text, for the hasher. Call it at the point of use, never earlier.
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
      {% raise "Punch::Auth::NewPassword cannot be hashed or used as a Hash key." %}
    end

    def to_s(io : IO) : Nil
      io << Secret::REDACTED
    end

    def inspect(io : IO) : Nil
      io << "Punch::Auth::NewPassword(" << Secret::REDACTED << ')'
    end

    def to_json(json : JSON::Builder) : Nil
      {% raise "Punch::Auth::NewPassword cannot be serialized to JSON: it would leave the process (lib/punch/docs/auth.md)." %}
    end
  end
end
