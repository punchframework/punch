module Punch::Crypto
  # HKDF with SHA-256 (RFC 5869) over the standard library's HMAC. Every
  # key Punch uses is derived with an *info* that names its algorithm,
  # format version, and purpose, such as `aes-256-gcm:v1:credentials`, so
  # no key is shared between two uses.
  module HKDF
    HASH_SIZE = 32
    SALT      = "punch-v1".to_slice

    def self.extract(salt : Bytes, ikm : Bytes) : Bytes
      salt = Bytes.new(HASH_SIZE) if salt.empty?
      OpenSSL::HMAC.digest(:sha256, salt, ikm)
    end

    def self.expand(prk : Bytes, info : Bytes, length : Int32) : Bytes
      raise ArgumentError.new("HKDF output of #{length} bytes is longer than #{255 * HASH_SIZE}") if length > 255 * HASH_SIZE
      okm = IO::Memory.new(length)
      previous = Bytes.empty
      counter = 1_u8
      while okm.pos < length
        block = IO::Memory.new(previous.size + info.size + 1)
        block.write(previous)
        block.write(info)
        block.write_byte(counter)
        previous = OpenSSL::HMAC.digest(:sha256, prk, block.to_slice)
        okm.write(previous[0, Math.min(previous.size, length - okm.pos)])
        counter += 1
      end
      okm.to_slice
    end

    # A key of *length* bytes for the purpose named by *info*.
    def self.derive(ikm : Bytes, info : String, length : Int32 = KEY_SIZE, salt : Bytes = SALT) : Bytes
      expand(extract(salt, ikm), info.to_slice, length)
    end
  end
end
