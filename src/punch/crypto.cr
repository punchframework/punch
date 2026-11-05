require "openssl"
require "openssl/hmac"
require "crypto/subtle"
require "base64"
require "./crypto/hkdf"
require "./crypto/aes_gcm"
require "./crypto/key_ring"
require "./crypto/sip_hash"
require "./crypto/public_ids"
require "./crypto/public_id_key"

module Punch
  # The cryptographic building blocks shared by credentials, the key ring,
  # and column encryption, on the standard library's OpenSSL binding alone.
  # Checked against published test vectors: HKDF against RFC 5869's,
  # AES-256-GCM against the standard ones.
  module Crypto
    KEY_SIZE = 32

    # A fresh random key of 32 bytes.
    def self.random_key : Bytes
      Random::Secure.random_bytes(KEY_SIZE)
    end
  end
end
