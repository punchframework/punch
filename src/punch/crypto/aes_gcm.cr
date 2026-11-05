module Punch::Crypto
  # AES-256-GCM with a random 96-bit nonce and a 16-byte tag.
  #
  # The tag length is fixed here, never taken from a message:
  # `OpenSSL::Cipher#gcm_tag=` hands a truncated tag to OpenSSL, which then
  # checks only that many bytes. The
  # standard library offers no additional authenticated data, so formats
  # bind their header through the key derivation instead.
  module AESGCM
    NONCE_SIZE = 12
    TAG_SIZE   = 16

    record Sealed, nonce : Bytes, ciphertext : Bytes, tag : Bytes

    def self.seal(key : Bytes, plaintext : Bytes) : Sealed
      check_key(key)
      nonce = Random::Secure.random_bytes(NONCE_SIZE)
      cipher = OpenSSL::Cipher.new("aes-256-gcm")
      cipher.encrypt
      cipher.key = key
      cipher.iv = nonce
      body = IO::Memory.new(plaintext.size)
      body.write(cipher.update(plaintext))
      body.write(cipher.final)
      tag = cipher.gcm_tag
      raise "AES-GCM produced a tag of #{tag.size} bytes, expected #{TAG_SIZE}" unless tag.size == TAG_SIZE
      Sealed.new(nonce, body.to_slice, tag)
    end

    # The plaintext, or `nil` when the message does not authenticate. No
    # reason is given, so callers cannot become an oracle.
    def self.open(key : Bytes, nonce : Bytes, ciphertext : Bytes, tag : Bytes) : Bytes?
      check_key(key)
      return unless nonce.size == NONCE_SIZE && tag.size == TAG_SIZE

      cipher = OpenSSL::Cipher.new("aes-256-gcm")
      cipher.decrypt
      cipher.key = key
      cipher.iv = nonce
      cipher.gcm_tag = tag
      plain = IO::Memory.new(ciphertext.size)
      plain.write(cipher.update(ciphertext))
      plain.write(cipher.final)
      plain.to_slice
    rescue OpenSSL::Cipher::Error
      nil
    end

    private def self.check_key(key : Bytes) : Nil
      raise ArgumentError.new("AES-256 needs a key of #{KEY_SIZE} bytes, got #{key.size}") unless key.size == KEY_SIZE
    end
  end
end
