module Punch
  # Markup that is written out as it is (escaping is a type). Every `String`
  # a view receives is escaped; only a `SafeHTML` is not.
  #
  # The views produce it when they render, and `HTTP::Response.html` takes
  # nothing else. The one way to make one by hand is `SafeHTML.trusted`,
  # named to stand out in review; `Punch/TrustedHTML` reports any call whose
  # argument is not a string literal.
  struct SafeHTML
    getter value : String

    private def initialize(@value : String)
    end

    # Markup written by the programmer, such as an inline SVG icon. Never
    # pass text that came from a request, the database, or a file.
    def self.trusted(html : String) : self
      new(html)
    end

    def to_s(io : IO) : Nil
      io << @value
    end

    def ==(other : self) : Bool
      @value == other.value
    end
  end
end
