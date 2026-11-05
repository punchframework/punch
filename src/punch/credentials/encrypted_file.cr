require "base64"

module Punch::Credentials
  # The format of `config/credentials/<environment>.yml.enc`: one line of
  # Base64 over
  #
  #   version (1 byte = 1) | key id (4, big endian) | nonce (12) | ciphertext | tag (16)
  #
  # AES-256-GCM under a key derived from the master key for this purpose
  # only. The key id is a fingerprint of the master key (`MasterKey#id`);
  # it is bound through the derivation like the header of every Punch
  # format, and lets a wrong key be reported as such.
  module EncryptedFile
    VERSION  = 1_u8
    HEADER   = 1 + 4
    OVERHEAD = HEADER + Crypto::AESGCM::NONCE_SIZE + Crypto::AESGCM::TAG_SIZE

    enum Error
      # Not Base64, too short, or another format version.
      Malformed
      # Encrypted under another master key.
      WrongKey
      # The right key, but the content was changed.
      Tampered

      def message(path : String, key : MasterKey) : String
        case self
        in .malformed? then "#{path} is not a Punch credentials file (format version #{VERSION})"
        in .wrong_key? then "#{path} was encrypted with another key than #{key.origin}"
        in .tampered?  then "#{path} does not authenticate with #{key.origin}: the file was changed or damaged"
        end
      end
    end

    def self.encrypt(plaintext : String, key : MasterKey) : String
      sealed = Crypto::AESGCM.seal(key.encryption_key, plaintext.to_slice)
      message = IO::Memory.new(OVERHEAD + sealed.ciphertext.size)
      message.write_byte(VERSION)
      message.write_bytes(key.id, IO::ByteFormat::BigEndian)
      message.write(sealed.nonce)
      message.write(sealed.ciphertext)
      message.write(sealed.tag)
      Base64.strict_encode(message.to_slice) + "\n"
    end

    def self.decrypt(text : String, key : MasterKey) : String | Error
      message = begin
        Base64.decode(text.strip)
      rescue Base64::Error
        return Error::Malformed
      end
      return Error::Malformed if message.size < OVERHEAD || message[0] != VERSION
      return Error::WrongKey unless IO::ByteFormat::BigEndian.decode(UInt32, message[1, 4]) == key.id

      nonce = message[HEADER, Crypto::AESGCM::NONCE_SIZE]
      body = message[HEADER + nonce.size, message.size - OVERHEAD]
      tag = message[message.size - Crypto::AESGCM::TAG_SIZE, Crypto::AESGCM::TAG_SIZE]
      plain = Crypto::AESGCM.open(key.encryption_key, nonce, body, tag) || return Error::Tampered
      text = String.new(plain)
      text.valid_encoding? ? text : Error::Tampered
    end
  end
end
