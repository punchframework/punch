module Punch
  # A URL segment such as `annual-report-2026`: lowercase ASCII letters and
  # digits in groups joined by single hyphens, at most `MAX` characters.
  # Input is checked, not converted: `Annual Report` is rejected, not slugified.
  struct Slug
    include Primitive(String)

    MAX    = 100
    FORMAT = /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/

    def self.json_schema
      {minLength: 1, maxLength: MAX, pattern: "^[a-z0-9]+(-[a-z0-9]+)*$"}
    end

    def self.parse(raw : String) : self | Invalid
      return Invalid.new("blank") if raw.empty?
      return Invalid.new("too_long", max: MAX) if raw.size > MAX

      FORMAT.matches?(raw) ? new(raw) : Invalid.new("invalid_slug")
    end
  end
end
