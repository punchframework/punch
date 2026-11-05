require "yaml"

module Punch
  module DocsCheck
    # The messages a source file can give, as patterns a guide's quote of
    # one must match: the string literals of a Crystal file, or the values
    # of a YAML file, with each interpolation, macro expression, or format
    # placeholder standing for any text. A guide marks such a quote
    # `text message=PATH` (or `console message=PATH`), and `docs:check`
    # keeps it current like a quoted definition.
    module Messages
      # Literal text a pattern needs before it is taken as a message:
      # shorter strings, such as `", "`, would match any block.
      MINIMUM = 15
      # `%s` and `%{name}` in format strings and translations.
      PLACEHOLDER = /%[-+ 0#]*\d*(?:\.\d+)?[sdif]|%\{\w+\}|%<\w+>[sdif]?/
      # Messages of other programs, which no file of Punch's holds: the
      # Crystal compiler, SQLite, and Turbo. Not checked.
      EXTERNAL = %w[crystal sqlite turbo]

      # Whether a quote may hold a message of *path* anywhere: a YAML
      # file's values appear inside answers, such as a JSON body, and the
      # compile-error spec holds the start of each message only.
      def self.anywhere?(path : String) : Bool
        path.ends_with?(".yml") || path.ends_with?(".yaml") || path == COMPILE_ERRORS
      end

      # The patterns of the file at *path*. A message of a Crystal file runs
      # to the end of a line. It starts a line, or follows `: ` or `; ` (as
      # after `Error: ` or a file's location), unless its first text starts
      # with a space or a punctuation mark: then it continues a message
      # built in pieces.
      def self.of(path : String) : Array(Regex)
        text = File.read(path)
        pieces = anywhere?(path) && path != COMPILE_ERRORS ? yaml(YAML.parse(text)) : Literals.new(text).all
        return pieces.compact_map { |parts| pattern(parts) } if anywhere?(path)

        pieces.compact_map do |parts|
          pattern(parts).try do |found|
            first = parts.first?
            start = first && !first[0].alphanumeric? && !first[0].in?('`', '<', '@', '"', '\'') ? "" : "(?:^|(?<=: )|(?<=; ))"
            Regex.new("(?m)#{start}#{found.source}(?=$)")
          end
        end
      end

      # Whether *patterns* account for every line of *text* except commands
      # (`$ …`): each line ends inside a match.
      def self.covers?(patterns : Array(Regex), text : String) : Bool
        matches = [] of Range(Int32, Int32)
        patterns.each { |pattern| text.scan(pattern) { |match| matches << (match.begin(0)..match.end(0)) } }
        offset = 0
        text.each_line(chomp: false) do |line|
          finish = offset + line.chomp.size
          offset += line.size
          next if line.blank? || line.lstrip.starts_with?("$ ")
          return false unless matches.any? { |range| range.begin < finish && finish <= range.end }
        end
        true
      end

      # Every string value of a YAML document, each placeholder a gap.
      private def self.yaml(node : YAML::Any) : Array(Array(String?))
        case raw = node.raw
        when Hash  then raw.values.flat_map { |value| yaml(value) }
        when Array then raw.flat_map { |value| yaml(value) }
        when String
          [placeholders([raw] of String?)]
        else
          [] of Array(String?)
        end
      end

      # *parts* with each placeholder in their text split out as a gap.
      def self.placeholders(parts : Array(String?)) : Array(String?)
        parts.flat_map do |part|
          next [part] unless part

          pieces = [] of String?
          part.split(PLACEHOLDER).each_with_index do |piece, index|
            pieces << nil unless index == 0
            pieces << piece unless piece.empty?
          end
          pieces
        end
      end

      # A pattern for *parts* (text, and `nil` for a gap), or nil when it
      # holds too little text to be told apart from other strings.
      private def self.pattern(parts : Array(String?)) : Regex?
        return if parts.sum { |part| part.try(&.size) || 0 } < MINIMUM

        # A gap spans lines only in a message that does.
        gap = parts.any? { |part| part.try(&.includes?('\n')) } ? "[\\s\\S]*?" : "[^\\n]*?"
        Regex.new(parts.map { |part| part ? Regex.escape(part) : gap }.join)
      end

      # The string literals of a Crystal file, read without parsing it, so
      # that strings inside macro bodies count too. Each is its parts:
      # text, and `nil` for an interpolation. Literals continued with `\`
      # at the end of a line are one string.
      class Literals
        OPENERS = {'(' => ')', '[' => ']', '{' => '}', '<' => '>', '|' => '|'}

        @chars : Array(Char)
        @index = 0

        def initialize(text : String)
          @chars = text.chars
        end

        def all : Array(Array(String?))
          found = [] of Array(String?)
          while char = @chars[@index]?
            case char
            when '#'  then skip_line
            when '\'' then skip_char
            when '"'  then found << joined('"', '"')
            when '%'
              if opened = percent
                found << joined(@chars[@index], *opened)
              else
                @index += 1
              end
            else
              @index += 1
            end
          end
          found
        end

        private def skip_line : Nil
          while (char = @chars[@index]?) && char != '\n'
            @index += 1
          end
        end

        # A character literal: `'a'`, `'\n'`, `'\u{41}'`.
        private def skip_char : Nil
          if @chars[@index + 1]? == '\\'
            close = (@index + 2...@chars.size).find { |i| @chars[i] == '\'' }
            @index = close ? close + 1 : @chars.size
          elsif @chars[@index + 2]? == '\''
            @index += 3
          else
            @index += 1
          end
        end

        # At `%(`, `%Q[`, `%q(`, and the like, moves to the opening
        # delimiter and returns the closing one, and whether the literal is
        # raw (`%q`: no escapes, no interpolation); nil for a modulo or a
        # `%w` list.
        private def percent : {Char, Bool}?
          before = (0...@index).reverse_each.map { |i| @chars[i] }.find { |char| char != ' ' }
          return if before && (before.alphanumeric? || before.in?(')', ']', '}', '_'))

          letter = @chars[@index + 1]?
          start = letter.in?('Q', 'q') ? @index + 2 : @index + 1
          close = @chars[start]?.try { |char| OPENERS[char]? }
          return unless close

          @index = start
          {close, letter == 'q'}
        end

        # A literal from the opening delimiter at the current position,
        # with the `"…" \` literals that continue it.
        private def joined(open : Char, close : Char, raw : Bool = false) : Array(String?)
          parts = Messages.placeholders(literal(open, close, raw))
          while open == '"' && (next_start = continuation)
            @index = next_start
            parts.concat(Messages.placeholders(literal('"', '"')))
          end
          merged(parts)
        end

        # *parts* with neighbouring texts joined, and neighbouring gaps one.
        private def merged(parts : Array(String?)) : Array(String?)
          parts.each_with_object([] of String?) do |part, joined|
            if part.nil?
              joined << nil if joined.empty? || !joined.last.nil?
            elsif last = joined.last?
              joined[-1] = last + part
            else
              joined << part
            end
          end
        end

        # Where the next literal starts, when only spaces and a `\` at the
        # end of the line, or a `+`, come before it.
        private def continuation : Int32?
          index = @index
          while @chars[index]?.try(&.in?(' ', '\t'))
            index += 1
          end
          if @chars[index]? == '\\' && @chars[index + 1]? == '\n'
            index += 2
          elsif @chars[index]? == '+'
            index += 1
          else
            return
          end
          while @chars[index]?.try(&.whitespace?)
            index += 1
          end
          index if @chars[index]? == '"'
        end

        # One literal's parts, from its opening delimiter past its closing one.
        private def literal(open : Char, close : Char, raw : Bool = false) : Array(String?)
          parts = [] of String?
          text = IO::Memory.new
          depth = 0
          @index += 1
          while char = @chars[@index]?
            next if inserted?(char, raw, parts, text)
            if char == close && depth == 0
              @index += 1
              break
            end
            depth += nesting(char, open, close)
            text << char
            @index += 1
          end
          rest = text.to_s
          parts << rest unless rest.empty?
          parts
        end

        # Reads an escape, an interpolation, or a macro expression, when one
        # starts at the current position.
        private def inserted?(char : Char, raw : Bool, parts : Array(String?), text : IO::Memory) : Bool
          following = @chars[@index + 1]?
          if char == '\\' && !raw
            @index = escape(text, following)
          elsif char == '#' && following == '{' && !raw
            gap(parts, text)
            skip_interpolation
          elsif char == '{' && following == '{'
            gap(parts, text)
            skip_macro
          else
            return false
          end
          true
        end

        # How *char* changes the nesting of a `%(…)` literal's delimiters.
        private def nesting(char : Char, open : Char, close : Char) : Int32
          return 0 if open == close

          char == open ? 1 : (char == close ? -1 : 0)
        end

        # Writes the escaped character to *text*; returns where reading goes on.
        private def escape(text : IO, char : Char?) : Int32
          case char
          when 'n'  then text << '\n'
          when 't'  then text << '\t'
          when 'e'  then text << '\e'
          when '0'  then text << '\0'
          when '\n' then return (@index + 2...@chars.size).find { |i| !@chars[i].whitespace? } || @chars.size
          when nil  then return @chars.size
          else           text << char
          end
          @index + 2
        end

        private def gap(parts : Array(String?), text : IO::Memory) : Nil
          piece = text.to_s
          parts << piece unless piece.empty?
          parts << nil
          text.clear
        end

        # Past `#{…}`, strings and nested braces inside it included.
        private def skip_interpolation : Nil
          @index += 2
          depth = 1
          while char = @chars[@index]?
            case char
            when '"' then literal('"', '"')
            when '{'
              depth += 1
              @index += 1
            when '}'
              depth -= 1
              @index += 1
              return if depth == 0
            else
              @index += 1
            end
          end
        end

        # Past `{{…}}`.
        private def skip_macro : Nil
          close = (@index + 2...@chars.size - 1).find { |i| @chars[i] == '}' && @chars[i + 1] == '}' }
          @index = close ? close + 2 : @chars.size
        end
      end
    end
  end
end
