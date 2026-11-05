module Punch
  # Text functions beyond ASCII. Punch registers them on every connection in
  # place of SQLite's own `lower`, `upper`, and `like`, which only fold
  # ASCII letters.
  module Text
    # Lowercase by Unicode's full case mapping: `lower('ÄRGER')` is
    # `ärger`.
    def self.lower(text : String) : String
      text.downcase
    end

    def self.upper(text : String) : String
      text.upcase
    end

    # SQL `LIKE`: `%` matches any run of characters, `_` one character,
    # and *escape* makes the next character literal. Case-insensitive for
    # every script (`'ärger' LIKE 'Ä%'`); accents still count. Characters
    # are compared one by one after simple lowercasing, so `_` always stands
    # for one character.
    def self.like?(pattern : String, text : String, escape : Char? = nil) : Bool
      tokens = like_tokens(pattern, escape) || return false
      like?(tokens, text)
    end

    # *text* against a pattern `like_tokens` made: SQL's `like` reads its
    # pattern once per statement, not once per row.
    def self.like?(tokens : Indexable(Char), text : String) : Bool
      match?(tokens, text.chars.map!(&.downcase))
    end

    # The pattern as `like?` matches it, or `nil` for one that matches
    # nothing.
    def self.like_tokens(pattern : String, escape : Char? = nil) : Array(Char)?
      tokenize(pattern, escape.try(&.downcase))
    end

    # A pattern token: `ANY` for `%`, `ONE` for `_`, else a character to
    # match. The two markers are noncharacters, which text never holds.
    ANY = '\u{FDD0}'
    ONE = '\u{FDD1}'

    # `nil` when the pattern ends in a lone escape character, which SQLite
    # matches against nothing.
    private def self.tokenize(pattern : String, escape : Char?) : Array(Char)?
      tokens = [] of Char
      reader = pattern.chars.map!(&.downcase).each
      while (char = reader.next) != Iterator::Stop::INSTANCE
        char = char.as(Char)
        if escape && char == escape
          following = reader.next
          return if following == Iterator::Stop::INSTANCE

          tokens << following.as(Char)
        elsif char == '%'
          tokens << ANY unless tokens.last? == ANY
        elsif char == '_'
          tokens << ONE
        else
          tokens << char
        end
      end
      tokens
    end

    # Wildcard matching without recursion: after a mismatch, the last `%`
    # takes one more character and matching resumes behind it.
    private def self.match?(tokens : Indexable(Char), text : Array(Char)) : Bool
      t = p = 0
      star = -1
      resume = 0
      while t < text.size
        if p < tokens.size && tokens[p] == ANY
          star, resume = p, t
          p += 1
        elsif p < tokens.size && (tokens[p] == ONE || tokens[p] == text[t])
          p += 1
          t += 1
        elsif star >= 0
          resume += 1
          t, p = resume, star + 1
        else
          return false
        end
      end
      while p < tokens.size && tokens[p] == ANY
        p += 1
      end
      p == tokens.size
    end
  end
end
