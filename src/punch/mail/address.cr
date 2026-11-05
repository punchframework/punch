module Punch
  # Who a mail goes to (or comes from): an address and an optional name,
  # `"Ada Lovelace" <ada@example.org>`. Control characters in the name
  # become spaces, so a name from user data cannot add a header, and a
  # name with characters that mean something in an address (`,`, `<`,
  # `"`, …) or beyond ASCII is sent as an RFC 2047 word, so it cannot add
  # a recipient.
  struct Mail::Address
    getter email : Email
    getter name : String?

    def initialize(@email : Email, name : String? = nil)
      @name = name.try(&.gsub(/[[:cntrl:]]+/, " ").strip.presence)
    end

    SPECIALS = /[()<>\[\]:;@\\,."]/

    # The name as an address header carries it. An adapter that writes
    # headers takes this; one that hands the name to an API takes `name`.
    def header_name : String?
      name = @name || return
      return name if name.ascii_only? && !SPECIALS.matches?(name)

      "=?UTF-8?B?#{Base64.strict_encode(name)}?="
    end

    def to_s(io : IO) : Nil
      if name = header_name
        io << '"' << name << "\" <" << @email.value << '>'
      else
        io << @email.value
      end
    end
  end
end
