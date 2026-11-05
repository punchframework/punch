module Punch
  # A named, versioned order of text for SQL. Declared in the schema
  # (`name TEXT NOT NULL COLLATE de`), it decides `ORDER BY`, comparisons,
  # and the indexes on that column. Punch registers its collations on every
  # connection, in the query generator, in spec databases, and in
  # `punch db:shell`.
  #
  # The name is the interface: a later provider (ICU) may implement `de`
  # differently, which changes the version, never the name. A database
  # records the version its indexes were built with; opening it with
  # another version fails until a migration rebuilds them (`REINDEX de;`).
  struct Text::Collation
    # Compares two UTF-8 strings like `<=>`. Runs on whatever thread runs
    # the query and must not raise.
    alias Compare = Proc(Bytes, Bytes, Int32)

    getter name : String
    getter version : String
    getter compare : Compare

    def initialize(@name : String, @version : String, @compare : Compare)
      raise ArgumentError.new("collation names are lowercase identifiers, not #{name.inspect}") unless name.matches?(/\A[a-z][a-z0-9_]*\z/)
    end

    # The languages whose order the Latin provider gets right (German,
    # English, French, Italian, Dutch, Portuguese) or close (Spanish, where
    # ñ is a letter of its own). Each is its own name, so each can move to
    # a better provider alone.
    LATIN_LANGUAGES = %w[de en es fr it nl pt]

    # The collations every Punch database has.
    BUILTIN = LATIN_LANGUAGES.map { |language| new(language, Latin::VERSION, ->Latin.compare(Bytes, Bytes)) }

    # The first provider, written in Crystal with the standard library's
    # Unicode data. It compares in four levels, each deciding only when the
    # ones before it are equal:
    #
    # 1. Letters, with case and accents folded away (`Ärger` sorts with
    #    `arger`, `ß` as `ss`); then classes: spaces before punctuation and
    #    symbols, before digits, before letters. Letters of other scripts
    #    sort after Latin ones by code point.
    # 2. Accents: unaccented first.
    # 3. Case: lowercase first.
    # 4. Bytes, so only identical strings are equal and a unique index on a
    #    collated column stays as strict as without it.
    #
    # Wrong where accented letters are letters of their own (Swedish,
    # Danish, Norwegian, Polish, Czech).
    module Latin
      # Raised whenever the rules change; with the Unicode version, which
      # changes how new characters fold.
      RULES   = 1
      VERSION = "punch-latin-#{RULES}/unicode-#{Unicode::VERSION}"

      # How one character compares: up to three primary weights (`ß` has
      # two), its accents, and its case. A primary weight of 0 is "none";
      # weights fill `p1` first.
      record Entry, p1 : Int32, p2 : Int32, p3 : Int32, secondary : Int32, tertiary : Int32

      # Letters that do not decompose into a base letter and accents.
      EXPANSIONS = {
        'ß' => "ss", 'ẞ' => "ss", 'æ' => "ae", 'Æ' => "ae", 'œ' => "oe", 'Œ' => "oe",
        'ø' => "o", 'Ø' => "o", 'đ' => "d", 'Đ' => "d", 'ð' => "d", 'Ð' => "d",
        'ł' => "l", 'Ł' => "l", 'þ' => "th", 'Þ' => "th", 'ı' => "i", 'ĳ' => "ij", 'Ĳ' => "ij",
      }

      # Accent weights for the expansions that stand for an accented letter.
      EXPANSION_ACCENTS = {'ø' => 0x338, 'Ø' => 0x338, 'đ' => 0x335, 'Đ' => 0x335, 'ł' => 0x337, 'Ł' => 0x337, 'ß' => 1, 'ẞ' => 1}

      # Entries for Latin-1 and Latin Extended-A and -B, computed once;
      # other characters are computed when met.
      TABLE = Array(Entry).new(0x250) { |code| compute(code.unsafe_chr) }

      def self.entry(char : Char) : Entry
        code = char.ord
        code < 0x250 ? TABLE.unsafe_fetch(code) : compute(char)
      end

      def self.compare(a : Bytes, b : Bytes) : Int32
        return 0 if a == b

        order = level(a, b, 0)
        order = level(a, b, 1) if order == 0
        order = level(a, b, 2) if order == 0
        order == 0 ? a <=> b : order
      end

      # Compares one level through both strings' collation elements in
      # step. Level 0 skips elements without a letter (lone marks); levels
      # 1 and 2 see every element, so an expansion (`Æ` is `a` and `e`)
      # lines up with what it expands to. A string that runs out first
      # sorts first.
      private def self.level(left : Bytes, right : Bytes, level : Int32) : Int32
        a, b = Elements.new(left), Elements.new(right)
        loop do
          x, y = a.next(level), b.next(level)
          return x <=> y if x != y
          return 0 if x == -1
        end
      end

      # A string's collation elements: one per primary weight of each
      # character, each with that character's accent and case; a lone mark
      # is one element without a primary weight.
      private struct Elements
        @entry = Entry.new(0, 0, 0, 0, 0)
        @remaining = 0
        @slot = 0

        def initialize(bytes : Bytes)
          @chars = Chars.new(bytes)
        end

        # The next element's weight at *level*, or -1 at the end.
        def next(level : Int32) : Int32
          loop do
            if @remaining == 0
              char = @chars.next || return -1
              @entry = Latin.entry(char)
              @slot = 0
              @remaining = {@entry.p1, @entry.p2, @entry.p3}.count(&.!=(0))
              @remaining = 1 if @remaining == 0
            end
            primary = @slot == 0 ? @entry.p1 : (@slot == 1 ? @entry.p2 : @entry.p3)
            @slot += 1
            @remaining -= 1

            case level
            when 0 then return primary unless primary == 0
            when 1 then return @entry.secondary
            else        return @entry.tertiary
            end
          end
        end
      end

      # The characters of UTF-8 bytes, decoded in place: SQLite hands the
      # collation bytes, and copying them into a `String` per comparison
      # doubled its cost. Invalid sequences read as U+FFFD, one byte each.
      private struct Chars
        @index = 0

        def initialize(@bytes : Bytes)
        end

        def next : Char?
          return if @index >= @bytes.size

          first = @bytes.unsafe_fetch(@index).to_u32
          if first < 0x80
            @index += 1
            return first.unsafe_chr
          end
          size, code = if first & 0xE0 == 0xC0
                         {2, first & 0x1F}
                       elsif first & 0xF0 == 0xE0
                         {3, first & 0x0F}
                       elsif first & 0xF8 == 0xF0
                         {4, first & 0x07}
                       else
                         {0, 0_u32}
                       end
          if size == 0 || @index + size > @bytes.size
            @index += 1
            return Char::REPLACEMENT
          end
          (1...size).each do |offset|
            byte = @bytes.unsafe_fetch(@index + offset).to_u32
            if byte & 0xC0 != 0x80
              @index += 1
              return Char::REPLACEMENT
            end
            code = (code << 6) | (byte & 0x3F)
          end
          @index += size
          code <= 0x10FFFF && !(0xD800..0xDFFF).includes?(code) ? code.unsafe_chr : Char::REPLACEMENT
        end
      end

      protected def self.compute(char : Char) : Entry
        tertiary = char.uppercase? || char.titlecase? ? 1 : 0
        if expansion = EXPANSIONS[char]?
          weights = expansion.chars.map { |letter| weight(letter) }
          return Entry.new(weights[0], weights[1]? || 0, weights[2]? || 0, EXPANSION_ACCENTS[char]? || 0, tertiary)
        end
        return Entry.new(weight(char.downcase), 0, 0, 0, tertiary) if char.ascii?

        # A lone combining mark has no letter: only its accent counts.
        return Entry.new(0, 0, 0, char.ord, 0) if char.mark?

        decomposed = char.to_s.unicode_normalize(:nfd)
        base = decomposed.chars.reject(&.mark?)
        accents = decomposed.chars.select(&.mark?)
        weights = base.flat_map { |letter| letter.to_s.downcase(Unicode::CaseOptions::Fold).chars }.first(3).map { |letter| weight(letter) }
        secondary = accents.first(2).reduce(0) { |sum, accent| sum * 0x1000 + (accent.ord & 0xFFF) }
        Entry.new(weights[0]? || 0, weights[1]? || 0, weights[2]? || 0, secondary, tertiary)
      end

      # A class in the high bits, the code point below: control characters,
      # spaces, punctuation and symbols, digits, then letters. Never 0,
      # which ends a string.
      private def self.weight(char : Char) : Int32
        kind = if char.whitespace?
                 2
               elsif char.letter?
                 5
               elsif char.number?
                 4
               elsif char.control?
                 1
               else
                 3
               end
        (kind << 21) | char.ord
      end
    end
  end
end
