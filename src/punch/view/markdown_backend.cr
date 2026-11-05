module Punch
  class View
    # Writes GitHub Flavored Markdown: the pages agents read. Headings,
    # paragraphs, emphasis, code, links, lists, quotes, and tables map to
    # their markdown; containers (`div`, `main`, `section`, frames) are
    # transparent; chrome is left out. A definition list becomes a list of
    # `term: description`, an image its alt text. Forms become action blocks
    # under `## Actions` at the end (`Actions`).
    #
    # Text is escaped so that no link, emphasis, HTML, or block structure
    # can come from it, only text. A bare URL in text may still become a
    # link in a GFM renderer, whose text is its address; escaping it would
    # put backslashes into values agents copy.
    #
    # Elements arrive as a tree; the markdown is laid out once it is
    # complete, by `to_s`.
    class MarkdownBackend < TreeBackend
      # Escaped wherever they appear: they open links, emphasis, code, HTML,
      # entities, strikethrough, table cells, or headings.
      ESCAPED = "\\`*_[]<>&!~|#"
      # Escaped at the start of a line, where they open a list, a quote, or
      # a setext heading's underline.
      LINE_START = "-+=>"

      # The language of the action blocks' phrases.
      property locale : Locale = I18n.default
      # The errors of a refused form the page no longer shows, such as a
      # Command that failed because the state changed: they open the
      # actions.
      property refused = [] of FormTarget::Problem

      def describes_forms? : Bool
        true
      end

      # A link to an agent-readable page goes to its `.md` URL, so an agent
      # that sends no `Accept` stays on markdown.
      protected def link(value : Href) : String
        Routing.markdown_url(value)
      end

      # The markdown laid out, ending in one line break.
      def to_s(io : IO) : Nil
        text = MarkdownBackend.flow(@root.children)
        actions = Actions.section(@root, @locale, @refused)
        text = text.empty? ? actions : "#{text}\n\n#{actions}" unless actions.empty?
        io << text << '\n' unless text.empty?
      end

      # Escapes *text* as one line of markdown, as the backend writes text:
      # whitespace collapsed, and escaped as at the start of a line.
      def self.escape(text : String) : String
        line = Inline.new
        line.text(text)
        line.to_s
      end

      # :nodoc:
      def self.flow(children : Array(Node | String)) : String
        blocks = [] of String
        inline = [] of Node | String
        # Two lists in a row with the same marker are one list in markdown,
        # so the second one takes the other marker (`*`, `1)`).
        previous = nil.as(Char?)
        children.each do |child|
          if child.is_a?(String) || child.tag.phrasing?
            inline << child
          else
            unless inline.empty?
              text = inline(inline)
              previous = nil unless text.empty?
              blocks << text
              inline.clear
            end
            text = block(child, previous)
            next if text.empty?
            blocks << text
            previous = list_marker(text)
          end
        end
        blocks << inline(inline) unless inline.empty?
        blocks.reject(&.empty?).join("\n\n")
      end

      # The marker of a list's first item: `-`, `*`, `.`, or `)`.
      private def self.list_marker(text : String) : Char?
        return text[0] if text.starts_with?("- ") || text.starts_with?("* ")

        text.match(/\A\d+([.)]) /).try(&.[1][0])
      end

      private def self.block(node : Node, previous : Char? = nil) : String
        case node.tag
        when .h1?, .h2?, .h3?, .h4?, .h5?, .h6?
          title = inline(node.children, single_line: true)
          title.empty? ? "" : "#{"#" * node.tag.name[1].to_i} #{title}"
        when .p?, .caption?, .summary?, .legend?, .dt?
          inline(node.children)
        when .pre?
          fence(verbatim(node.children).strip('\n'))
        when .hr?
          "---"
        when .ul?, .ol?
          list(node, previous)
        when .dl?
          terms(node, previous)
        when .blockquote?
          indent(flow(node.children), "> ")
        when .table?
          table(node)
        when .form?
          # An action block at the end (`Actions`).
          ""
        else
          flow(node.children)
        end
      end

      private def self.list(node : Node, previous : Char?) : String
        items = node.children.select(Node).select(&.tag.li?)
        items.map_with_index do |item, index|
          hang(flow(item.children), node.tag.ol? ? "#{index + 1}#{previous == '.' ? ')' : '.'} " : bullet(previous))
        end.join('\n')
      end

      private def self.bullet(previous : Char?) : String
        previous == '-' ? "* " : "- "
      end

      # Each term as a list item, `term: description` when its
      # descriptions are one line, else the term with them below.
      private def self.terms(node : Node, previous : Char?) : String
        entries = [] of {String, Array(String)}
        node.children.select(Node).each do |part|
          if part.tag.dt?
            entries << {inline(part.children, single_line: true), [] of String}
          else
            description = flow(part.children)
            if entries.empty?
              entries << {"", [description]}
            else
              entries.last[1] << description
            end
          end
        end
        entries.map do |term, descriptions|
          descriptions = descriptions.reject(&.empty?)
          if descriptions.size == 1 && !descriptions[0].includes?('\n') && !term.empty?
            "#{bullet(previous)}#{term}#{term.ends_with?(':') ? "" : ":"} #{descriptions[0]}"
          else
            hang(([term] + descriptions).reject(&.empty?).join("\n\n"), bullet(previous))
          end
        end.join('\n')
      end

      # Rows as a GFM table: the head's first row as the header, or the
      # first row when there is no head; ragged rows padded.
      private def self.table(node : Node) : String
        caption = nil
        head = [] of Array(String)
        body = [] of Array(String)
        node.children.select(Node).each do |section|
          if section.tag.caption?
            caption = inline(section.children)
            next
          end
          section.children.select(Node).each do |row|
            cells = row.children.select(Node).map { |cell| inline(cell.children, single_line: true, table: true) }
            (section.tag.thead? && head.empty? ? head : body) << cells
          end
        end
        rows = head + body
        return caption || "" if rows.empty?

        columns = rows.max_of(&.size)
        return caption || "" if columns.zero?

        lines = [] of String
        rows.each_with_index do |cells, index|
          lines << "|#{(0...columns).join('|') { |column| cells[column]?.presence.try { |cell| " #{cell} " } || " " }}|"
          lines << "|#{(["---"] * columns).join('|')}|" if index.zero?
        end
        table = lines.join('\n')
        caption && !caption.empty? ? "#{caption}\n\n#{table}" : table
      end

      # A fenced code block, its fence longer than any run of backticks in
      # *text*, so the text cannot close it.
      private def self.fence(text : String) : String
        longest = text.scan(/`+/).max_of?(&.[0].size) || 0
        marker = "`" * Math.max(3, longest + 1)
        "#{marker}\n#{text}\n#{marker}"
      end

      # The text of a `<pre>`, whitespace as written.
      private def self.verbatim(children : Array(Node | String)) : String
        String.build do |io|
          children.each do |child|
            case child
            in String then io << child
            in Node   then io << (child.tag.br? ? "\n" : verbatim(child.children))
            end
          end
        end
      end

      # Phrasing content as one paragraph. *single_line* for a heading, a
      # term, or a table cell, where a line break becomes a space; in a
      # *table*, a pipe in a code span is escaped too.
      private def self.inline(children : Array(Node | String), *, single_line : Bool = false, table : Bool = false) : String
        line = Inline.new(single_line, table)
        write(children, line)
        line.to_s
      end

      private def self.write(children : Array(Node | String), line : Inline) : Nil
        children.each do |child|
          case child
          in String then line.text(child)
          in Node   then write(child, line)
          end
        end
      end

      private def self.write(node : Node, line : Inline) : Nil
        if delimiter = emphasis(node.tag)
          return line.wrap(delimiter) { |inner| write(node.children, inner) }
        end

        case node.tag
        when .br?
          line.break
        when .img?
          node.alt.try { |alt| line.text(alt) }
        when .code?, .kbd?, .samp?
          line.code(plain(node.children))
        when .q?
          line.text("“")
          write(node.children, line)
          line.text("”")
        when .a?
          if href = node.href
            line.link(href) { |inner| write(node.children, inner) }
          else
            write(node.children, line)
          end
        when .form?
          # An action block at the end (`Actions`).
        else
          # Other phrasing elements are transparent; a block inside a
          # table cell or a heading is separated by spaces.
          line.space unless node.tag.phrasing?
          write(node.children, line)
          line.space unless node.tag.phrasing?
        end
      end

      private def self.emphasis(tag : Tag) : String?
        case tag
        when .strong?, .b? then "**"
        when .em?, .i?     then "*"
        when .s?, .del?    then "~~"
        end
      end

      # The text inside *children*, without markup, for a code span.
      private def self.plain(children : Array(Node | String)) : String
        String.build do |io|
          children.each do |child|
            case child
            in String then io << child
            in Node   then io << (child.tag.img? ? child.alt : plain(child.children))
            end
          end
        end
      end

      # One paragraph being written: collapses whitespace as HTML does and
      # escapes text, knowing where a line starts.
      # :nodoc:
      class Inline
        @io = IO::Memory.new
        # Nothing but markup that opens nothing written on this line yet.
        @line_start = true
        # Only digits on this line so far, which a `.` or `)` would turn
        # into an ordered list's marker.
        @digits = false
        @space = false
        @break = false
        # Whether the content began or ended with whitespace, for `wrap`.
        getter? leading_space = false
        getter? trailing_space = false

        def initialize(@single_line : Bool = false, @table : Bool = false)
        end

        def text(text : String) : Nil
          text.each_char do |char|
            if char.whitespace?
              @leading_space = true if @io.empty?
              space
              next
            end
            @trailing_space = false
            flush
            if ESCAPED.includes?(char) || (@line_start && LINE_START.includes?(char)) || (@digits && char.in?('.', ')'))
              @io << '\\'
            end
            @io << char
            @digits = char.ascii_number? && (@line_start || @digits)
            @line_start = false
          end
        end

        # A line break: a hard break, or a space on a single line.
        def break : Nil
          if @single_line
            space
          elsif !@line_start
            # Written with what follows: a break at the end of a paragraph
            # would be a backslash.
            @break = true
            @space = false
            @line_start = true
            @digits = false
          end
        end

        # A space, unless at the start of a line.
        def space : Nil
          @space = true unless @line_start || @io.empty?
          @trailing_space = true
        end

        # Content between *delimiter*s, such as `**` for strong. Emphasis
        # next to whitespace does not open in CommonMark, so the content is
        # trimmed, its whitespace moved outside; empty content writes
        # nothing.
        def wrap(delimiter : String, & : Inline ->) : Nil
          inner = Inline.new(@single_line, @table)
          inner.continue
          yield inner
          content = inner.to_s
          space if inner.leading_space?
          unless content.empty?
            flush
            @io << delimiter << content << delimiter
            finished
          end
          space if inner.trailing_space?
        end

        # A link to *href*; its text, or its address when it has none.
        def link(href : String, & : Inline ->) : Nil
          inner = Inline.new(true, @table)
          inner.continue
          yield inner
          label = inner.to_s
          if label.empty?
            inner = Inline.new(true, @table)
            inner.continue
            inner.text(href)
            label = inner.to_s
          end
          space if inner.leading_space?
          flush
          @io << '[' << label << "](" << MarkdownBackend.destination(href) << ')'
          finished
          space if inner.trailing_space?
        end

        # A code span, its fence longer than any run of backticks in
        # *text*. Backslashes do not escape inside, so a pipe in a table
        # cell is the one character escaped.
        def code(text : String) : Nil
          content = text.gsub(/\s+/, " ")
          @leading_space ||= @io.empty? && content.starts_with?(' ')
          content = content.strip
          return if content.empty?

          content = content.gsub('|', "\\|") if @table
          longest = content.scan(/`+/).max_of?(&.[0].size) || 0
          fence = "`" * (longest + 1)
          pad = content.starts_with?('`') || content.ends_with?('`') ? " " : ""
          flush
          @io << fence << pad << content << pad << fence
          finished
        end

        # Content that follows markup on the same line, not at its start.
        protected def continue : Nil
          @line_start = false
        end

        private def flush : Nil
          if @break
            @io << "\\\n"
          elsif @space
            @io << ' '
          end
          @break = @space = false
        end

        private def finished : Nil
          @line_start = false
          @digits = false
          @trailing_space = false
        end

        def to_s(io : IO) : Nil
          io << @io.to_s.rstrip
        end
      end

      # A link's destination: characters that would end it, or that are not
      # allowed in one, percent-encoded; `|` too, which ends a table cell.
      # :nodoc:
      def self.destination(url : String) : String
        String.build do |io|
          url.each_char do |char|
            if char.in?(' ', '(', ')', '<', '>', '\\', '`', '|') || char.control?
              char.to_s.each_byte { |byte| io << '%' << byte.to_s(16, upcase: true).rjust(2, '0') }
            else
              io << char
            end
          end
        end
      end
    end
  end
end
