module Punch
  # The key of an app's public IDs (`Punch::TypedID.public_id`),
  # `public_id_key` in its credentials: 64 hexadecimal characters, made by
  # `punch keys:public-id`. It sits outside the key ring and is never
  # rotated, because every public ID handed out, in links, bookmarks and
  # other systems, depends on it: a new key gives every record a new public
  # ID and the old ones stop working. The secret never prints.
  struct PublicIDKey
    TEXT = /\A[0-9a-fA-F]{64}\z/

    def self.parse(text : String) : PublicIDKey | Invalid
      TEXT.matches?(text) ? new(text.hexbytes) : Invalid.new("invalid_public_id_key")
    end

    def self.generate : PublicIDKey
      new(Crypto.random_key)
    end

    protected def initialize(@secret : Bytes)
    end

    # Makes this the key of every public ID in the process.
    def install : Nil
      Crypto::PublicIDs.root = @secret
    end

    # The text form, secret included: for the command that writes the
    # credentials file.
    def to_text : String
      @secret.hexstring
    end

    def to_s(io : IO) : Nil
      io << "Punch::PublicIDKey"
    end

    def inspect(io : IO) : Nil
      to_s(io)
    end
  end
end
