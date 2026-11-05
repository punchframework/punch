module Punch::QueryGen
  # A light SQL tokenizer and the few structural facts the generator needs:
  # table aliases, outer-joined tables, select-list items, and parameter
  # contexts. Not a parser: SQLite checks every query, and anything this
  # cannot classify is left to annotations.
  module SQL
    enum Kind
      Ident
      String
      Number
      Param
      Punct
    end

    # *offset* and *size* count characters of the query text. A parameter's
    # text is its name, without the `:`, `@`, or `$`.
    record Token, kind : Kind, text : String, offset : Int32, size : Int32 do
      def keyword?(*words : String) : Bool
        kind.ident? && words.any? { |word| text.compare(word, case_insensitive: true) == 0 }
      end

      def punct?(*chars : String) : Bool
        kind.punct? && chars.includes?(text)
      end
    end

    OPERATORS = %w[|| <= >= <> != == << >> ->>]

    def self.tokenize(sql : String) : Array(Token)
      Scanner.new(sql).tokens
    end

    # Splits SQL into tokens, skipping whitespace and comments.
    private class Scanner
      getter tokens = [] of Token

      def initialize(@sql : String)
        @chars = @sql.chars
        i = 0
        while i < @chars.size
          i = step(i)
        end
      end

      # Scans one token or gap starting at *i* and returns where the next
      # one starts.
      private def step(i : Int32) : Int32
        c = @chars[i]
        return i + 1 if c.whitespace?
        return skip_comment(i) if comment?(i)
        return quoted(i) if c.in?('\'', '"', '`', '[')
        return parameter(i) if c.in?(':', '@', '$', '?') && parameter?(i)
        return run(i, Kind::Number) { |char| char.ascii_number? || char == '.' } if c.ascii_number?
        return run(i, Kind::Ident) { |char| char.alphanumeric? || char == '_' } if c.letter? || c == '_'

        operator = OPERATORS.find { |candidate| @sql[i, candidate.size]? == candidate } || c.to_s
        add(Kind::Punct, operator, i, operator.size)
      end

      private def comment?(i : Int32) : Bool
        (@chars[i] == '-' && @chars[i + 1]? == '-') || (@chars[i] == '/' && @chars[i + 1]? == '*')
      end

      private def skip_comment(i : Int32) : Int32
        close = @chars[i] == '-' ? "\n" : "*/"
        stop = @sql.index(close, i + 2) || return @chars.size
        stop + close.size
      end

      # A string literal, or a quoted identifier: "name", `name`, [name].
      private def quoted(i : Int32) : Int32
        open = @chars[i]
        close = open == '[' ? ']' : open
        j = i + 1
        loop do
          j = scan(j, &.!=(close))
          break unless open == '\'' && @chars[j + 1]? == '\''
          j += 2 # '' inside a string
        end
        if open == '\''
          add(Kind::String, @sql[i..j], i, j - i + 1)
        else
          add(Kind::Ident, @sql[i + 1...j], i, j - i + 1)
        end
      end

      private def parameter?(i : Int32) : Bool
        @chars[i] == '?' || @chars[i + 1]?.try { |char| char.letter? || char == '_' } || false
      end

      # `:name`, `@name`, `$name` (text without the prefix), or `?`/`?N`.
      private def parameter(i : Int32) : Int32
        if @chars[i] == '?'
          stop = scan(i + 1, &.ascii_number?)
          return add(Kind::Param, @sql[i...stop], i, stop - i)
        end
        stop = scan(i + 1) { |char| char.alphanumeric? || char == '_' }
        add(Kind::Param, @sql[i + 1...stop], i, stop - i)
      end

      private def run(i : Int32, kind : Kind, & : Char -> Bool) : Int32
        stop = scan(i) { |char| yield char }
        add(kind, @sql[i...stop], i, stop - i)
      end

      private def scan(i : Int32, & : Char -> Bool) : Int32
        while i < @chars.size && yield @chars[i]
          i += 1
        end
        i
      end

      private def add(kind : Kind, text : String, offset : Int32, size : Int32) : Int32
        @tokens << Token.new(kind, text, offset, size)
        offset + size
      end
    end

    CLAUSE_WORDS = %w[WHERE JOIN ON LEFT RIGHT FULL INNER CROSS NATURAL OUTER GROUP ORDER LIMIT USING HAVING WINDOW UNION EXCEPT INTERSECT RETURNING SET VALUES DEFAULT]

    # alias (lowercase) => table name, for every FROM, JOIN, INTO, and
    # UPDATE source.
    def self.aliases(tokens : Array(Token)) : Hash(String, String)
      map = {} of String => String
      tokens.each_with_index do |token, i|
        next unless token.keyword?("FROM", "JOIN", "INTO", "UPDATE")
        table = tokens[i + 1]?
        next unless table && table.kind.ident?
        map[table.text.downcase] = table.text
        j = i + 2
        j += 1 if tokens[j]?.try &.keyword?("AS")
        if (name = tokens[j]?) && name.kind.ident? && CLAUSE_WORDS.none? { |word| name.keyword?(word) }
          map[name.text.downcase] = table.text
        end
      end
      map
    end

    # Whether the query has a RIGHT or FULL join, whose nullability the
    # generator does not derive.
    def self.right_or_full_join?(tokens : Array(Token)) : Bool
      tokens.each_with_index.any? do |token, i|
        token.keyword?("RIGHT", "FULL") && tokens[i + 1..i + 2].any?(&.keyword?("JOIN"))
      end
    end

    # Tables on the optional side of a LEFT join, as written (lowercase).
    def self.outer_tables(tokens : Array(Token)) : Set(String)
      set = Set(String).new
      tokens.each_with_index do |token, i|
        next unless token.keyword?("LEFT")
        j = i + 1
        j += 1 if tokens[j]?.try &.keyword?("OUTER")
        next unless tokens[j]?.try &.keyword?("JOIN")
        if (table = tokens[j + 1]?) && table.kind.ident?
          set << table.text.downcase
        end
      end
      set
    end

    record Item, tokens : Array(Token), name : String

    # The items of the outermost select list, or of RETURNING.
    def self.select_items(tokens : Array(Token), sql : String) : Array(Item)
      start = list_start(tokens) || return [] of Item
      items = [] of Item
      current = [] of Token
      depth = 0
      tokens[start..].each do |token|
        depth += 1 if token.punct?("(")
        depth -= 1 if token.punct?(")")
        break if depth == 0 && (token.keyword?("FROM") || token.punct?(";"))
        if depth == 0 && token.punct?(",")
          items << item(current, sql)
          current = [] of Token
        else
          current << token
        end
      end
      items << item(current, sql) unless current.empty?
      items
    end

    # Where the outermost select list starts. The last top-level SELECT or
    # RETURNING wins: WITH … SELECT, INSERT … RETURNING.
    private def self.list_start(tokens : Array(Token)) : Int32?
      start = nil
      depth = 0
      tokens.each_with_index do |token, i|
        depth += 1 if token.punct?("(")
        depth -= 1 if token.punct?(")")
        start = i + 1 if depth == 0 && token.keyword?("SELECT", "RETURNING")
      end
      start += 1 if start && tokens[start]?.try &.keyword?("DISTINCT", "ALL")
      start
    end

    private def self.item(tokens : Array(Token), sql : String) : Item
      if tokens.size >= 2 && tokens[-1].kind.ident? && (tokens[-2].keyword?("AS") || !tokens[-2].punct?("."))
        expr = tokens[-2].keyword?("AS") ? tokens[0...-2] : tokens[0...-1]
        return Item.new(expr, tokens[-1].text) unless expr.empty?
      end
      # Unaliased: SQLite names the column after the expression as written.
      first, last = tokens.first, tokens.last
      Item.new(tokens, sql[first.offset...last.offset + last.size])
    end

    # The index of the parenthesis that closes the one at *open*.
    def self.matching(tokens : Array(Token), open : Int32) : Int32
      depth = 0
      (open...tokens.size).each do |i|
        depth += 1 if tokens[i].punct?("(")
        depth -= 1 if tokens[i].punct?(")")
        return i if depth == 0
      end
      tokens.size - 1
    end

    # Where a WHERE, HAVING, or ON condition ends.
    CONDITION_ENDS = {"GROUP", "ORDER", "LIMIT", "HAVING", "WINDOW", "UNION", "EXCEPT", "INTERSECT", "RETURNING", "JOIN", "LEFT",
                      "INNER", "CROSS", "NATURAL", "RIGHT", "FULL", "WHERE", "ON"}

    # An opening parenthesis, or CASE, which nests like one.
    def self.opens?(token : Token) : Bool
      token.punct?("(") || token.keyword?("CASE")
    end

    def self.closes?(token : Token) : Bool
      token.punct?(")") || token.keyword?("END")
    end

    # The last token of the condition that holds the token at *index*.
    def self.condition_end(tokens : Array(Token), index : Int32) : Int32
      depth = 0
      (index + 1).upto(tokens.size - 1) do |i|
        token = tokens[i]
        if opens?(token)
          depth += 1
        elsif closes?(token)
          return i - 1 if depth == 0

          depth -= 1
        elsif depth == 0 && CONDITION_ENDS.any? { |word| token.keyword?(word) }
          return i - 1
        end
      end
      tokens.size - 1
    end

    # The indexes of *tokens* outside parentheses and CASE, the depth at
    # which a statement's own clauses are.
    def self.top_level(tokens : Array(Token)) : Array(Int32)
      depth = 0
      indexes = [] of Int32
      tokens.each_with_index do |token, i|
        if opens?(token)
          depth += 1
        elsif closes?(token)
          depth -= 1
        elsif depth == 0
          indexes << i
        end
      end
      indexes
    end

    # The terms of `ORDER BY a, b DESC`, each with its direction and NULLS
    # placement stripped: `{text, descending, nulls}` with *nulls* `FIRST`,
    # `LAST`, or `nil`.
    def self.order_terms(text : String) : Array({String, Bool, String?})
      tokens = tokenize(text)
      return [] of {String, Bool, String?} unless tokens[0]?.try(&.keyword?("ORDER")) && tokens[1]?.try(&.keyword?("BY"))

      split_top(tokens[2..], &.punct?(",")).compact_map do |term|
        nulls = nil
        if term.size > 2 && term[-2].keyword?("NULLS")
          nulls = term[-1].text.upcase
          term = term[0...-2]
        end
        descending = term.last?.try(&.keyword?("DESC")) || false
        term = term[0...-1] if term.last?.try(&.keyword?("ASC", "DESC"))
        next if term.empty?
        {text[term.first.offset...term.last.offset + term.last.size], descending, nulls}
      end
    end

    # `ORDER BY …` with every term in the other direction, NULLS FIRST and
    # LAST swapped: the same order read backwards.
    def self.reverse_order(text : String) : String
      terms = order_terms(text).map do |term, descending, nulls|
        flipped = nulls.try { |where| where == "FIRST" ? " NULLS LAST" : " NULLS FIRST" }
        "#{term}#{descending ? "" : " DESC"}#{flipped}"
      end
      "ORDER BY #{terms.join(", ")}"
    end

    # Splits *tokens* at separators outside parentheses and CASE.
    def self.split_top(tokens : Array(Token), & : Token -> Bool) : Array(Array(Token))
      parts = [[] of Token]
      depth = 0
      case_depth = 0
      tokens.each do |token|
        depth += 1 if token.punct?("(")
        depth -= 1 if token.punct?(")")
        case_depth += 1 if token.keyword?("CASE")
        case_depth -= 1 if token.keyword?("END")
        if depth == 0 && case_depth == 0 && yield token
          parts << [] of Token
        else
          parts.last << token
        end
      end
      parts
    end
  end
end
