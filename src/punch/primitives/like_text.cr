module Punch
  # User text for a `LIKE` pattern built around it in SQL: `%` and `_` in it
  # match themselves. The generator types every parameter that feeds a
  # `LIKE … ESCAPE '\'`, and the `Filter` field of such a `-- when` clause,
  # as `LikeText`, so a `String` does not compile. `parse` (what a request's
  # input does) takes the text as typed; binding escapes it.
  #
  # ```sql
  # -- when q: AND name LIKE '%' || :q || '%' ESCAPE '\'
  # ```
  #
  # ```
  # Queries::Page::Filter.new(q: Punch::LikeText.new(text))
  # Punch::LikeText.pattern("ab%") # a screen that offers wildcards on purpose
  # ```
  #
  # `value` is the text as typed, so a link or a form that writes the
  # filter back shows what the person typed; `bound` is what the query
  # receives.
  struct LikeText
    include Primitive(String)

    # Whether `%` and `_` in the text act as wildcards: only `pattern`.
    getter? wildcards : Bool

    private def initialize(@value : String, @wildcards : Bool)
    end

    # The text as itself, whatever it holds: `LikeText.new(input.q)`. Any
    # text is valid, so unlike other primitives this cannot fail.
    def self.new(text : String) : self
      new(text, wildcards: false)
    end

    # The same, as a request's input reads it.
    def self.parse(raw : String) : self | Invalid
      new(raw)
    end

    # Text whose `%` and `_` are wildcards, for a screen that lets people
    # type patterns. Say so at the call site: this is the opt-out.
    def self.pattern(raw : String) : self
      new(raw, wildcards: true)
    end

    # What is bound to the query: the text with `\`, `%`, and `_` escaped,
    # or as it is for a `pattern`.
    def bound : String
      wildcards? ? value : Database.escape_like(value)
    end

    def ==(other : self) : Bool
      value == other.value && wildcards? == other.wildcards?
    end

    def hash(hasher)
      hasher = value.hash(hasher)
      wildcards?.hash(hasher)
    end
  end

  # User text for an FTS5 `MATCH`, as one phrase: `OR`, `NOT`, `*`, and
  # parentheses in it are words. Typed by the generator for the parameter
  # that feeds a `MATCH`, as `LikeText` is for `LIKE`.
  #
  # `FtsPhrase.syntax(raw)` is the opt-out for a screen that offers the
  # search syntax on purpose. `value` is the text as typed; `bound` is what
  # the query receives.
  struct FtsPhrase
    include Primitive(String)

    getter? syntax : Bool

    private def initialize(@value : String, @syntax : Bool)
    end

    # The text as one phrase, whatever it holds: `FtsPhrase.new(input.q)`.
    def self.new(text : String) : self
      new(text, syntax: false)
    end

    # The same, as a request's input reads it. Control characters are
    # refused: FTS5 fails every `MATCH` on a NUL.
    def self.parse(raw : String) : self | Invalid
      return Invalid.new("invalid_characters") if Text::FORBIDDEN.matches?(raw)

      new(raw)
    end

    # Text that is FTS5 query syntax, bound as it is.
    def self.syntax(raw : String) : self
      new(raw, syntax: true)
    end

    def bound : String
      syntax? ? value : Database.fts_phrase(value)
    end

    def ==(other : self) : Bool
      value == other.value && syntax? == other.syntax?
    end

    def hash(hasher)
      hasher = value.hash(hasher)
      syntax?.hash(hasher)
    end
  end

  module Stored
    # The text a `LikeText` or `FtsPhrase` binds.
    def self.dump(value : LikeText | FtsPhrase) : String
      value.bound
    end
  end
end
