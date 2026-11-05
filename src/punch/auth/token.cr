require "digest/sha256"
require "digest/crc32"

module Punch::Auth
  # The random values behind sessions, API tokens, and one-time tokens. Each
  # is 43 characters of base62, 256 bits from the system's secure generator,
  # so it fits a cookie, a URL, and a header without escaping. The database
  # keeps only its SHA-256 digest: a leaked database or replica holds
  # nothing that signs anyone in. A slow hash is not needed, since the value
  # is not guessable to begin with.
  module Token
    ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
    # 62^43 > 2^256.
    LENGTH = 43

    # A fresh random value.
    def self.generate : String
      String.build(LENGTH) do |io|
        LENGTH.times { io << ALPHABET[Random::Secure.rand(ALPHABET.size)] }
      end
    end

    # What the database stores in place of *token*.
    def self.digest(token : String) : Bytes
      Digest::SHA256.digest(token)
    end

    # Whether *text* has the shape of a value from `generate`, so that
    # anything else is refused before a lookup.
    def self.well_formed?(text : String) : Bool
      text.bytesize == LENGTH && base62?(text)
    end

    # :nodoc:
    def self.base62?(text : String) : Bool
      text.each_byte.all?(&.unsafe_chr.ascii_alphanumeric?)
    end

    # *value* in base62, left-padded with `0` to *width* characters; for
    # checksums.
    def self.base62(value : UInt32, width : Int32) : String
      chars = Array(Char).new(width, '0')
      index = width - 1
      while value > 0 && index >= 0
        chars[index] = ALPHABET[(value % 62).to_i]
        value //= 62
        index -= 1
      end
      chars.join
    end
  end
end
