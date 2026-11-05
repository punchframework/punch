module Punch
  # An email address in the common `local@domain` form, lowercased.
  #
  # Accepted: dot-atom local parts including non-ASCII letters (RFC 6531), and
  # domains of at least two labels, international ones included. Not
  # accepted: quoted local parts, IP-literal domains, comments, and
  # single-label domains such as `localhost`. The whole address is
  # lowercased, so `Ann@Example.org` and `ann@example.org` are one address.
  #
  # Parsing says the address is well-formed, not that it exists or that its
  # owner controls it; that takes a confirmation mail.
  struct Email
    include Primitive(String)

    MAX       = 254
    LOCAL_MAX =  64
    LABEL_MAX =  63

    LOCAL_ATOM = /\A[^\s"(),:;<>@\[\\\]]+\z/
    LABEL      = /\A[\p{L}\p{N}](?:[\p{L}\p{N}\p{M}-]*[\p{L}\p{N}\p{M}])?\z/

    # International addresses are accepted, hence `idn-email`.
    def self.json_schema
      {format: "idn-email", maxLength: MAX}
    end

    def self.parse(raw : String) : self | Invalid
      text = Text.normalize(raw)
      return text if text.is_a?(Invalid)
      return Invalid.new("blank") if text.empty?
      return Invalid.new("too_long", max: MAX) if text.size > MAX

      local, at, domain = text.downcase.unicode_normalize(:nfc).rpartition('@')
      return Invalid.new("invalid_email") if at.empty?

      valid_local?(local) && valid_domain?(domain) ? new("#{local}@#{domain}") : Invalid.new("invalid_email")
    end

    private def self.valid_local?(local : String) : Bool
      return false if local.empty? || local.size > LOCAL_MAX

      local.split('.').all? { |atom| LOCAL_ATOM.matches?(atom) }
    end

    private def self.valid_domain?(domain : String) : Bool
      labels = domain.split('.')
      return false if labels.size < 2
      return false if labels.last.each_char.all?(&.ascii_number?)

      labels.all? { |label| label.size <= LABEL_MAX && LABEL.matches?(label) }
    end

    # The part after the `@`.
    def domain : String
      value.rpartition('@').last
    end
  end
end
