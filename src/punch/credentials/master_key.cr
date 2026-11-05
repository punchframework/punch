module Punch::Credentials
  # The key of one environment's credentials file: 32 random bytes, written
  # as 64 hexadecimal characters to `config/credentials/<environment>.key`
  # (never committed) or given as `PUNCH_MASTER_KEY`, which wins.
  struct MasterKey
    VARIABLE = "PUNCH_MASTER_KEY"

    # Where the key came from: the variable's name or the file's path.
    getter origin : String

    def initialize(key : Bytes, @origin : String)
      raise ArgumentError.new("a master key has #{Crypto::KEY_SIZE} bytes") unless key.size == Crypto::KEY_SIZE
      @key = Secret(Bytes).new(key)
    end

    def self.generate(origin : String) : MasterKey
      new(Crypto.random_key, origin)
    end

    # The key in *text*, or a problem naming *origin* but never the text.
    def self.parse(text : String, origin : String) : MasterKey | String
      hex = text.strip
      unless hex.size == 2 * Crypto::KEY_SIZE && hex.each_char.all?(&.hex?)
        return "#{origin} must hold #{2 * Crypto::KEY_SIZE} hexadecimal characters (a key from 'punch creds:init')"
      end

      new(hex.hexbytes, origin)
    end

    # The key for *environment*: `PUNCH_MASTER_KEY`, else the key file;
    # `nil` when there is neither, a problem when the one found is
    # malformed.
    def self.resolve(environment : String, env = ENV, directory : String = DIRECTORY) : MasterKey | String?
      if text = env[VARIABLE]?.presence
        return parse(text, VARIABLE)
      end

      path = Credentials.key_file(environment, directory)
      return unless File.exists?(path)

      if File.info(path).permissions.value & 0o077 != 0
        ::Log.for("punch.credentials").warn { "#{path} can be read by other users: chmod 600 it" }
      end
      parse(File.read(path), path)
    end

    # The text form for the key file.
    def to_text : String
      @key.unwrap.hexstring
    end

    # A public 32-bit fingerprint, stored in the file's header so a wrong
    # key is told apart from a damaged file.
    def id : UInt32
      IO::ByteFormat::BigEndian.decode(UInt32, Crypto::HKDF.derive(@key.unwrap, "key-id:v1:credentials", 4))
    end

    # The key that encrypts the file, derived for that purpose only.
    def encryption_key : Bytes
      Crypto::HKDF.derive(@key.unwrap, "aes-256-gcm:v1:credentials")
    end

    def to_s(io : IO) : Nil
      io << "Punch::Credentials::MasterKey(" << Secret::REDACTED << ", " << origin << ')'
    end

    def inspect(io : IO) : Nil
      to_s(io)
    end
  end
end
