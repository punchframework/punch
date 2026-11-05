# Fixture for Punch/CipherUse: OpenSSL::Cipher outside Punch::Crypto.
require "openssl"

cipher = OpenSSL::Cipher.new("aes-256-gcm") # expect
error = OpenSSL::Cipher::Error              # expect
digest = OpenSSL::Digest.new("SHA256")
key = Punch::Crypto.random_key
