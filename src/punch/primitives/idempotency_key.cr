require "digest/sha256"

module Punch
  # The client's name for one attempt of a request, from the
  # `Idempotency-Key` header or a form's hidden field, and the key an
  # inbound webhook is deduplicated by: 1 to 255 visible ASCII characters.
  # The IETF draft sends it as a quoted string, most clients send it bare;
  # both parse to the same key.
  struct IdempotencyKey
    include Primitive(String)

    MAX = 255

    def self.json_schema
      {minLength: 1, maxLength: MAX, pattern: "^[!-~]+$"}
    end

    def self.parse(raw : String) : self | Invalid
      text = raw.size >= 2 && raw.starts_with?('"') && raw.ends_with?('"') ? raw[1..-2] : raw
      return Invalid.new("blank") if text.empty?
      return Invalid.new("too_long", max: MAX) if text.bytesize > MAX
      return Invalid.new("invalid_characters") unless text.each_byte.all? { |byte| 0x21 <= byte <= 0x7e }

      new(text)
    end
  end

  # A SHA-256 over several parts, each prefixed with its length, so that
  # `("ab", "c")` and `("a", "bc")` differ. It decides whether two requests
  # under one idempotency key, or two webhook deliveries under one key, are
  # the same.
  module Crypto::Fingerprint
    def self.of(*parts : String | Bytes) : Bytes
      digest = Digest::SHA256.new
      parts.each do |part|
        bytes = part.to_slice
        digest << "#{bytes.size}:"
        digest << bytes
      end
      digest.final
    end
  end
end
