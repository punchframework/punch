module Punch
  class View
    # A backend that collects the elements as a tree and lays the result
    # out once it is complete, in `to_s`: text and markdown, where a block's
    # form depends on what it holds (a table's column widths, a list item's
    # indentation). Chrome and raw HTML are left out.
    abstract class TreeBackend < Backend
      # :nodoc:
      class Node
        getter tag : Tag
        getter children = [] of Node | String
        property href : String?
        property alt : String?
        # Inside a form, for action blocks: every attribute, and for the
        # form itself where it is sent (`MarkdownBackend`).
        property attributes : Hash(String, String)?
        property target : FormTarget?

        def []?(name : String) : String?
          @attributes.try(&.[name]?)
        end

        def initialize(@tag : Tag)
        end
      end

      @root = Node.new(Tag::Fragment)
      @stack : Array(Node)
      # Open forms; their attributes are kept when the backend describes
      # forms.
      @forms = 0

      # With *base*, links are written as absolute URLs below it
      # (`Href#absolute`), as mail needs; without, as they are.
      def initialize(@base : String? = nil)
        @stack = [@root]
      end

      def start(tag : Tag) : Nil
        node = Node.new(tag)
        @stack.last.children << node
        @stack << node
        @forms += 1 if tag.form?
      end

      def attribute(name : String, value : String) : Nil
        @stack.last.alt = value if name == "alt"
        keep(name, value)
      end

      def attribute(name : String, value : Href) : Nil
        keep(name, value.url)
        return unless name == "href"

        base = @base
        @stack.last.href = base ? value.absolute(base) : link(value)
      end

      # The address a link to *value* is written with.
      protected def link(value : Href) : String
        value.url
      end

      def attribute(name : String) : Nil
        keep(name, "")
      end

      def form_target(target : FormTarget) : Nil
        @stack.last.target = target if describes_forms?
      end

      def describe(name : String, value : String) : Nil
        keep(name, value)
      end

      private def keep(name : String, value : String) : Nil
        return unless @forms > 0 && describes_forms?

        node = @stack.last
        (node.attributes ||= {} of String => String)[name] = value
      end

      def started(tag : Tag) : Nil
      end

      def finish(tag : Tag) : Nil
        @stack.pop
        @forms -= 1 if tag.form?
      end

      def text(text : String) : Nil
        @stack.last.children << text
      end

      # Never reached: these backends render through a plain `View`, which
      # has no `raw`, and chrome, where `raw` is allowed, is left out.
      def raw(html : SafeHTML) : Nil
      end

      def head(title : String, stylesheets : Array(Asset::Stylesheet), scripts : Array(Asset::Script), alternate : String? = nil, morph : Bool = false) : Nil
      end

      def chrome? : Bool
        false
      end

      # *text* with *marker* before its first line and the others indented
      # to match.
      protected def self.hang(text : String, marker : String) : String
        pad = " " * marker.size
        text.split('\n').map_with_index { |line, index| index.zero? ? "#{marker}#{line}" : (line.empty? ? line : "#{pad}#{line}") }.join('\n')
      end

      protected def self.indent(text : String, prefix : String) : String
        text.split('\n').map { |line| line.empty? ? prefix.rstrip : "#{prefix}#{line}" }.join('\n')
      end
    end
  end
end
