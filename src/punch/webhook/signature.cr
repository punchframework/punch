require "base64"
require "crypto/subtle"
require "openssl/hmac"

module Punch::Webhook
  # HMAC-SHA256 signatures by the Standard Webhooks scheme
  # (https://www.standardwebhooks.com), the default of Punch's HMAC
  # verifier and what `Punch::Spec::Client#deliver_webhook` sends. Three
  # headers carry it:
  #
  # | Header | Value |
  # |---|---|
  # | `webhook-id` | The delivery's unique ID, also the idempotency key |
  # | `webhook-timestamp` | Unix seconds when it was signed |
  # | `webhook-signature` | `v1,<base64 HMAC-SHA256 of "id.timestamp.body">`, several separated by spaces during a secret rotation |
  #
  # Secrets are `whsec_` followed by base64, as providers that use the
  # scheme hand them out; anything else is used as raw bytes.
  module Signature
    ID_HEADER        = "webhook-id"
    TIMESTAMP_HEADER = "webhook-timestamp"
    HEADER           = "webhook-signature"

    # The fewest bytes a secret may have: Standard Webhooks' generators
    # give 24, and an empty key would let anyone sign.
    MIN_KEY_BYTES = 16

    # The bytes of a secret.
    def self.key(secret : String) : Bytes
      if secret.starts_with?("whsec_")
        Base64.decode(secret[6..])
      else
        secret.to_slice
      end
    end

    # The `webhook-signature` value for *body*.
    def self.sign(secret : String, id : String, timestamp : Time, body : String | Bytes) : String
      "v1,#{Base64.strict_encode(digest(key(secret), id, timestamp.to_unix, body))}"
    end

    # The three headers of a signed delivery.
    def self.headers(secret : String, id : String, timestamp : Time, body : String | Bytes) : ::HTTP::Headers
      ::HTTP::Headers{ID_HEADER => id, TIMESTAMP_HEADER => timestamp.to_unix.to_s, HEADER => sign(secret, id, timestamp, body)}
    end

    # Whether *signature* (the header, possibly several `v1,…` values)
    # holds a valid signature of *body* by one of *secrets*, made within
    # *tolerance* of *now*. Comparison is constant-time; a timestamp that
    # is not plain digits, as the scheme sends it, fails.
    def self.valid?(secrets : Enumerable(String), id : String, timestamp : String, signature : String, body : String | Bytes,
                    *, now : Time = Time.utc, tolerance : Time::Span = 5.minutes) : Bool
      return false unless timestamp.valid_encoding? && timestamp.matches?(/\A[0-9]{1,12}\z/)

      seconds = timestamp.to_i64
      return false unless now.to_unix - tolerance.total_seconds <= seconds <= now.to_unix + tolerance.total_seconds

      given = signature.split(' ').compact_map do |part|
        version, _, value = part.partition(',')
        version == "v1" ? (Base64.decode(value) rescue nil) : nil
      end
      return false if given.empty?

      secrets.any? do |secret|
        expected = digest(key(secret), id, seconds, body)
        given.any? { |candidate| candidate.size == expected.size && ::Crypto::Subtle.constant_time_compare(candidate, expected) }
      end
    end

    private def self.digest(key : Bytes, id : String, seconds : Int64, body : String | Bytes) : Bytes
      message = IO::Memory.new
      message << id << '.' << seconds << '.'
      message.write(body.to_slice)
      OpenSSL::HMAC.digest(:sha256, key, message.to_slice)
    end
  end
end
