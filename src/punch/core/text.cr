module Punch
  # Shared steps for parsing text into domain primitives.
  module Text
    # Characters that never belong in single-line or multi-line text input:
    # C0 controls other than tab, line feed, and carriage return, and DEL.
    FORBIDDEN = /[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/

    # Rejects invalid UTF-8 and control characters, strips surrounding
    # whitespace, and normalizes to NFC, so that the same text typed two
    # ways is one value.
    def self.normalize(raw : String) : String | Invalid
      return Invalid.new("invalid_encoding") unless raw.valid_encoding?
      return Invalid.new("invalid_characters") if FORBIDDEN.matches?(raw)

      raw.strip.unicode_normalize(:nfc)
    end

    # *url* as a problem may show it: without the user and password and
    # without the query, which may hold keys.
    def self.shown_url(url : String) : String
      url.sub(%r{//[^/?#]*@}, "//…@").sub(/\?[^#]*/, "?…").inspect
    end
  end
end
