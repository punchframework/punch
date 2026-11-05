module Punch
  # The root keys of an app, `secret_key_base` in its credentials: an
  # ordered list in which the first key that is not pending signs and
  # encrypts, and every key verifies and decrypts. Each purpose gets its own
  # key, derived with HKDF, so nothing is shared between a signed link, an
  # encrypted column, and a blind index. Sessions and one-time tokens do not
  # depend on it.
  #
  # Text form, one key per line (or separated by commas, for an
  # environment variable):
  #
  # ```text
  # <id>:<created, YYYY-MM-DD>:<64 hexadecimal characters>[:pending]
  # ```
  #
  # A pending key is accepted but does not sign yet: during a handover the
  # old process must accept what the new one signs, so a new key is first
  # deployed as pending and then promoted (`punch keys:rotate`,
  # `keys:promote`, `keys:retire`).
  class KeyRing
    ID_RANGE = 1_u32..UInt32::MAX
    ENTRY    = /\A(\d+):(\d{4}-\d{2}-\d{2}):([0-9a-fA-F]{64})(:pending)?\z/

    # One root key. The secret never prints.
    struct Key
      getter id : UInt32
      getter created : Time
      getter? pending : Bool

      def initialize(@id : UInt32, secret : Bytes, @created : Time, @pending : Bool = false)
        raise ArgumentError.new("a root key has #{Crypto::KEY_SIZE} bytes") unless secret.size == Crypto::KEY_SIZE
        @secret = Secret(Bytes).new(secret)
      end

      # Whether *other* has the same root secret, whatever its ID.
      # :nodoc:
      def same_secret?(other : Key) : Bool
        ::Crypto::Subtle.constant_time_compare(@secret.unwrap, other.@secret.unwrap)
      end

      # A fresh random key, created today.
      def self.generate(id : UInt32, pending : Bool = false, created : Time = Time.utc) : Key
        new(id, Crypto.random_key, created.at_beginning_of_day, pending)
      end

      # The key for *info*, derived from this root key.
      protected def derive(info : String) : Bytes
        Crypto::HKDF.derive(@secret.unwrap, info)
      end

      def with_pending(pending : Bool) : Key
        Key.new(id, @secret.unwrap, created, pending)
      end

      # The key's line in the text form, secret included: for the commands
      # that write the credentials file.
      def to_text : String
        "#{id}:#{created.to_s("%F")}:#{@secret.unwrap.hexstring}#{pending? ? ":pending" : ""}"
      end

      def to_s(io : IO) : Nil
        io << "key " << id << (pending? ? " (pending)" : "")
      end

      def inspect(io : IO) : Nil
        io << "Punch::KeyRing::Key(" << id << ", " << Secret::REDACTED << ')'
      end
    end

    @@current : KeyRing?

    # The ring loaded at boot from the app's credentials (`secret_key_base`).
    def self.current : KeyRing
      @@current || raise Credentials::NotLoaded.new("No key ring has been loaded. Declare `getter secret_key_base : Punch::KeyRing` in the app's credentials; specs call Punch::Spec.credentials.")
    end

    def self.current? : KeyRing?
      @@current
    end

    def self.current=(ring : KeyRing) : KeyRing
      @@current = ring
    end

    getter keys : Array(Key)
    # The key that signs and encrypts.
    getter signing : Key
    @uses : Hash(UInt32, Counter)
    @encryptors = {} of String => Encryptor
    @blind_indexes = {} of String => BlindIndex
    @encryptors_lock = Mutex.new

    # A counter shared by reference: `Atomic` is a struct, and one stored
    # in a Hash would be copied out and incremented as a copy.
    private class Counter
      @count = Atomic(Int64).new(0)

      def add : Nil
        @count.add(1)
      end

      def get : Int64
        @count.get
      end
    end

    def initialize(@keys : Array(Key))
      raise ArgumentError.new("a key ring needs a key") if @keys.empty?
      ids = @keys.map(&.id)
      raise ArgumentError.new("key ids must be unique") unless ids.uniq.size == ids.size
      raise ArgumentError.new("key ids start at 1") if ids.includes?(0)
      # One secret under two IDs would make a key ID mean nothing.
      @keys.each_with_index do |key, index|
        raise ArgumentError.new("two keys have the same secret") if @keys[...index].any?(&.same_secret?(key))
      end
      raise ArgumentError.new("at most one key may be pending") if @keys.count(&.pending?) > 1
      @signing = @keys.find(&.pending?.!) || raise ArgumentError.new("a key ring needs a key that is not pending")
      @uses = @keys.to_h { |key| {key.id, Counter.new} }
    end

    # The ring in *text*, or `invalid_key_ring` with the position of the
    # first bad entry; never a part of a key.
    def self.parse(text : String) : KeyRing | Invalid
      entries = text.split(/[\s,]+/).reject(&.empty?)
      return Invalid.new("invalid_key_ring", reason: "empty") if entries.empty?

      keys = [] of Key
      entries.each_with_index(1) do |entry, position|
        match = ENTRY.match(entry) || return Invalid.new("invalid_key_ring", reason: "malformed", entry: position)
        id = match[1].to_u32? || return Invalid.new("invalid_key_ring", reason: "id", entry: position)
        created = Time.parse_utc(match[2], "%F") rescue return Invalid.new("invalid_key_ring", reason: "date", entry: position)
        keys << Key.new(id, match[3].hexbytes, created, !match[4]?.nil?)
      end
      new(keys)
    rescue ex : ArgumentError
      Invalid.new("invalid_key_ring", reason: ex.message.to_s.gsub(' ', '_'))
    end

    def find(id : UInt32) : Key?
      @keys.find(&.id.==(id))
    end

    # Signs and verifies messages for *purpose*, such as `invoice_link`.
    def signer(purpose : String) : Signer
      Signer.new(self, purpose)
    end

    # Encrypts and decrypts for *purpose*, such as `column:customers.email`.
    # One per purpose and ring, kept: an encrypted column asks for its
    # encryptor on every value, and each derives a key per root key.
    def encryptor(purpose : String) : Encryptor
      @encryptors_lock.synchronize do
        @encryptors[purpose] ||= Encryptor.new(self, purpose)
      end
    end

    # Hashes values for the blind index *purpose*, such as
    # `blind_index:customers.email_index`; one per purpose and ring, kept,
    # like encryptors.
    def blind_index(purpose : String) : BlindIndex
      @encryptors_lock.synchronize do
        @blind_indexes[purpose] ||= BlindIndex.new(self, purpose)
      end
    end

    # How often each key verified or decrypted something while it was not
    # the signing key, since the process started: an old key that is still
    # in use is not safe to retire.
    def uses : Hash(UInt32, Int64)
      @uses.transform_values(&.get)
    end

    # Records that *key* opened a message; counted when it is not the
    # signing key, and named on the request's wide event.
    protected def note(key : Key) : Nil
      return if key.id == @signing.id

      @uses[key.id].add
      Trace.event["punch.key_ring.old_key_id"] = key.id.to_i64
    end

    # The text form, secrets included: for the commands that write the
    # credentials file.
    def to_text : String
      @keys.join('\n', &.to_text)
    end

    def to_s(io : IO) : Nil
      io << "Punch::KeyRing(" << @keys.join(", ") << ", signing: " << @signing.id << ')'
    end

    def inspect(io : IO) : Nil
      to_s(io)
    end

    # Signed messages, for the few values that must be stateless, such as a
    # signed ID in a link. Version 1:
    #
    #   version (1 byte = 1) | key id (4, big endian) | expires (8, Unix seconds, 0 = never) | payload | HMAC-SHA256 (32)
    #
    # The tag covers everything before it, under a key derived for this
    # purpose, so a message moved to another purpose does not verify. The
    # payload is readable by anyone who has the message: sign, do not hide.
    class Signer
      VERSION  = 1_u8
      TAG      =   32
      HEADER   = 1 + 4 + 8
      OVERHEAD = HEADER + TAG
      PURPOSE  = /\A[a-z0-9_.:-]+\z/

      getter purpose : String
      @keys : Hash(UInt32, Bytes)

      def initialize(@ring : KeyRing, @purpose : String)
        raise ArgumentError.new("purposes are lowercase names, such as invoice_link") unless PURPOSE.matches?(purpose)
        info = "hmac-sha256:v#{VERSION}:#{purpose}"
        @keys = @ring.keys.to_h { |key| {key.id, key.derive(info)} }
      end

      def sign(payload : Bytes, expires_at : Time? = nil) : Bytes
        key = @ring.signing
        message = IO::Memory.new(payload.size + OVERHEAD)
        message.write_byte(VERSION)
        message.write_bytes(key.id, IO::ByteFormat::BigEndian)
        message.write_bytes(expires_at.try(&.to_unix) || 0_i64, IO::ByteFormat::BigEndian)
        message.write(payload)
        message.write(OpenSSL::HMAC.digest(:sha256, @keys[key.id], message.to_slice))
        message.to_slice
      end

      # The payload, or `nil` when the message does not verify or has
      # expired. No reason is given.
      def verify(message : Bytes, now : Time = Time.utc) : Bytes?
        return if message.size < OVERHEAD || message[0] != VERSION

        id = IO::ByteFormat::BigEndian.decode(UInt32, message[1, 4])
        key = @ring.find(id) || return
        signed = message[0, message.size - TAG]
        expected = OpenSSL::HMAC.digest(:sha256, @keys[id], signed)
        return unless ::Crypto::Subtle.constant_time_compare(expected, message[message.size - TAG, TAG])

        expires = IO::ByteFormat::BigEndian.decode(Int64, message[5, 8])
        return if expires != 0 && now.to_unix >= expires

        @ring.note(key)
        message[HEADER, message.size - OVERHEAD]
      end

      # URL-safe Base64 without padding, for links.
      def sign_text(payload : String, expires_at : Time? = nil) : String
        Base64.urlsafe_encode(sign(payload.to_slice, expires_at), padding: false)
      end

      def verify_text(text : String, now : Time = Time.utc) : String?
        return unless text.each_char.all? { |char| char.ascii_alphanumeric? || char == '-' || char == '_' }

        bytes = begin
          Base64.decode(text)
        rescue Base64::Error
          return
        end
        # One spelling only: the decoder ignores the last character's
        # unused bits, so several texts would give the same bytes.
        return unless Base64.urlsafe_encode(bytes, padding: false) == text

        payload = verify(bytes, now) || return
        string = String.new(payload)
        string.valid_encoding? ? string : nil
      end
    end

    # Encrypted messages. Version 1:
    #
    #   version (1 byte = 1) | key id (4, big endian) | nonce (12) | ciphertext | tag (16)
    #
    # AES-256-GCM under a key derived for this purpose; the header is bound
    # through that derivation (the standard library has no AAD).
    class Encryptor
      VERSION  = 1_u8
      HEADER   = 1 + 4
      OVERHEAD = HEADER + Crypto::AESGCM::NONCE_SIZE + Crypto::AESGCM::TAG_SIZE

      getter purpose : String
      @keys : Hash(UInt32, Bytes)

      def initialize(@ring : KeyRing, @purpose : String)
        raise ArgumentError.new("purposes are lowercase names, such as column:customers.email") unless Signer::PURPOSE.matches?(purpose)
        info = "aes-256-gcm:v#{VERSION}:#{purpose}"
        @keys = @ring.keys.to_h { |key| {key.id, key.derive(info)} }
      end

      def encrypt(plaintext : Bytes) : Bytes
        key = @ring.signing
        sealed = Crypto::AESGCM.seal(@keys[key.id], plaintext)
        message = IO::Memory.new(plaintext.size + OVERHEAD)
        message.write_byte(VERSION)
        message.write_bytes(key.id, IO::ByteFormat::BigEndian)
        message.write(sealed.nonce)
        message.write(sealed.ciphertext)
        message.write(sealed.tag)
        message.to_slice
      end

      # The plaintext, or `nil` for anything that does not authenticate.
      def decrypt(message : Bytes) : Bytes?
        return if message.size < OVERHEAD || message[0] != VERSION

        id = IO::ByteFormat::BigEndian.decode(UInt32, message[1, 4])
        key = @ring.find(id) || return
        nonce = message[HEADER, Crypto::AESGCM::NONCE_SIZE]
        body = message[HEADER + nonce.size, message.size - OVERHEAD]
        tag = message[message.size - Crypto::AESGCM::TAG_SIZE, Crypto::AESGCM::TAG_SIZE]
        plain = Crypto::AESGCM.open(@keys[id], nonce, body, tag) || return
        @ring.note(key)
        plain
      end
    end

    # Blind indexes: a keyed hash of a value, the same every time under one
    # key, so an index finds equal values without holding them. Version 1:
    #
    #   version (1 byte = 1) | key id (4, big endian) | HMAC-SHA256 (32)
    #
    # A value is hashed under the signing key when written. Lookups hash
    # under every key of the ring, so rows written before a rotation are
    # still found; the key ID says which key wrote a value, for `db:audit`.
    class BlindIndex
      VERSION = 1_u8
      HEADER  = 1 + 4
      SIZE    = HEADER + 32

      getter purpose : String
      @keys : Hash(UInt32, Bytes)

      def initialize(@ring : KeyRing, @purpose : String)
        raise ArgumentError.new("purposes are lowercase names, such as blind_index:customers.email_index") unless Signer::PURPOSE.matches?(purpose)
        info = "blind-index:hmac-sha256:v#{VERSION}:#{purpose}"
        @keys = @ring.keys.to_h { |key| {key.id, key.derive(info)} }
      end

      # The index value of *plaintext* under the signing key.
      def digest(plaintext : Bytes) : Bytes
        digest(@ring.signing.id, plaintext)
      end

      # The index values of *plaintext* under every key of the ring, the
      # signing key first: what a lookup compares with.
      def digests(plaintext : Bytes) : Array(Bytes)
        ids = [@ring.signing.id] + @ring.keys.map(&.id).reject(@ring.signing.id)
        ids.map { |id| digest(id, plaintext) }
      end

      # Whether *value* is the index value of *plaintext* under the key it
      # names; `false` for a key not in the ring or a malformed value.
      def matches?(value : Bytes, plaintext : Bytes) : Bool
        id = BlindIndex.key_id(value) || return false
        return false unless @keys.has_key?(id)

        ::Crypto::Subtle.constant_time_compare(value, digest(id, plaintext))
      end

      # The ID of the key that wrote *value*, `nil` when it is not an index
      # value of this version.
      def self.key_id(value : Bytes) : UInt32?
        IO::ByteFormat::BigEndian.decode(UInt32, value[1, 4]) if value.size == SIZE && value[0] == VERSION
      end

      private def digest(id : UInt32, plaintext : Bytes) : Bytes
        value = Bytes.new(SIZE)
        value[0] = VERSION
        IO::ByteFormat::BigEndian.encode(id, value[1, 4])
        OpenSSL::HMAC.digest(:sha256, @keys[id], plaintext).copy_to(value[HEADER, 32])
        value
      end
    end
  end
end
