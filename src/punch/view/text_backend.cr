module Punch
  class View
    # Writes plain text: the text part of a mail, which mail clients show as
    # it is. Markdown's structure without its escaping, so a name such as
    # `Ada <script>` reads as written: paragraphs and headings separated by
    # blank lines, lists with `-` or numbers, tables in aligned columns,
    # quotes with `>`, every link as `text <URL>` with an absolute URL below
    # *base* (`Punch.public_url`), and `*strong*`, `_emphasis_`,
    # `~~deleted~~`, and “quotations” marked as plain-text mail marks them.
    # Not the markdown backend: its escaping would show as backslashes in a
    # part mail clients show literally.
    #
    # Elements arrive as a tree; the text is laid out once it is complete,
    # by `to_s`. Chrome and raw HTML are left out.
    class TextBackend < TreeBackend
      def initialize(base : String)
        super(base)
      end

      # The text laid out, ending in one line break.
      def to_s(io : IO) : Nil
        text = TextBackend.flow(@root.children)
        io << text << '\n' unless text.empty?
      end

      # :nodoc:
      def self.flow(children : Array(Node | String)) : String
        blocks = [] of String
        inline = [] of Node | String
        children.each do |child|
          if child.is_a?(String) || child.tag.phrasing?
            inline << child
          else
            blocks << inline(inline) unless inline.empty?
            inline.clear
            blocks << block(child)
          end
        end
        blocks << inline(inline) unless inline.empty?
        blocks.reject(&.empty?).join("\n\n")
      end

      private def self.block(node : Node) : String
        case node.tag
        when .h1?, .h2?
          heading(node)
        when .p?, .h3?, .h4?, .h5?, .h6?, .caption?, .summary?, .legend?, .dt?
          inline(node.children)
        when .pre?
          verbatim(node.children).strip('\n')
        when .hr?
          "----------"
        when .ul?, .ol?
          list(node)
        when .dl?
          node.children.select(Node).map do |part|
            part.tag.dt? ? inline(part.children) : indent(flow(part.children), "  ")
          end.reject(&.empty?).join('\n')
        when .blockquote?
          indent(flow(node.children), "> ")
        when .table?
          table(node)
        else
          flow(node.children)
        end
      end

      # A top-level heading, underlined.
      private def self.heading(node : Node) : String
        title = inline(node.children)
        width = title.lines.max_of?(&.size) || 0
        width.zero? ? "" : "#{title}\n#{(node.tag.h1? ? '=' : '-').to_s * width}"
      end

      private def self.list(node : Node) : String
        items = node.children.select(Node).select(&.tag.li?)
        items.map_with_index do |item, index|
          hang(flow(item.children), node.tag.ol? ? "#{index + 1}. " : "- ")
        end.join('\n')
      end

      # Phrasing content as one paragraph: whitespace collapsed as HTML
      # does, `<br>` kept as a line break, links as `text <URL>`.
      private def self.inline(children : Array(Node | String)) : String
        text = String.build { |io| write_inline(children, io) }
        text.split('\n').map(&.gsub(/ {2,}/, " ").strip).join('\n').strip('\n')
      end

      private def self.write_inline(children : Array(Node | String), io : IO) : Nil
        children.each do |child|
          case child
          in String
            io << child.gsub(/\s+/, " ")
          in Node
            if marker = emphasis(child.tag)
              next wrap(child.children, marker, marker, io)
            end

            case child.tag
            when .br?  then io << '\n'
            when .img? then io << child.alt
            when .q?   then wrap(child.children, "“", "”", io)
            when .a?
              label = inline(child.children)
              if url = child.href
                io << (label.empty? || label == url ? url : "#{label} <#{url}>")
              else
                io << label
              end
            else
              write_inline(child.children, io)
            end
          end
        end
      end

      # Emphasis and deleted text keep a mark, as plain-text mail writes
      # them: without one, a struck-out price would read as the current one.
      private def self.emphasis(tag : Tag) : String?
        case tag
        when .strong?, .b? then "*"
        when .em?, .i?     then "_"
        when .s?, .del?    then "~~"
        end
      end

      # *children* between *open* and *close*, their surrounding whitespace
      # moved outside; nothing when they hold no text.
      private def self.wrap(children : Array(Node | String), open : String, close : String, io : IO) : Nil
        content = String.build { |inner| write_inline(children, inner) }
        text = content.strip
        if text.empty?
          io << ' ' unless content.empty?
          return
        end
        io << ' ' if content[0].whitespace?
        io << open << text << close
        io << ' ' if content[-1].whitespace?
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

      # Rows in columns padded to the widest cell, a rule under the head.
      private def self.table(node : Node) : String
        caption = nil
        rows = [] of {Array(String), Bool}
        node.children.select(Node).each do |section|
          if section.tag.caption?
            caption = inline(section.children)
            next
          end
          section.children.select(Node).each do |row|
            cells = row.children.select(Node).map { |cell| flow(cell.children).gsub(/\s*\n\s*/, " ") }
            rows << {cells, section.tag.thead?}
          end
        end
        columns = rows.max_of?(&.[0].size) || 0
        widths = (0...columns).map { |column| rows.max_of { |cells, _| cells[column]?.try(&.size) || 0 } }
        lines = [] of String
        lines << caption if caption && !caption.empty?
        rows.each_with_index do |(cells, head), index|
          lines << widths.map_with_index { |width, column| (cells[column]? || "").ljust(width) }.join("  ").rstrip
          if head && !rows[index + 1]?.try(&.[1])
            lines << widths.map { |width| "-" * width }.join("  ")
          end
        end
        lines.join('\n')
      end
    end
  end
end
