require "html"

module Punch
  class View
    # Where a view's elements go. The view checks nesting and attributes;
    # a backend only writes: HTML, plain text (for mail, `TextBackend`), and
    # markdown (`MarkdownBackend`), from the same components. Turbo Streams
    # are HTML inside `<turbo-stream>` elements (`Punch::TurboStream`).
    abstract class Backend
      # The start of an element; its attributes follow, then `started`.
      abstract def start(tag : Tag) : Nil
      abstract def attribute(name : String, value : String) : Nil
      abstract def attribute(name : String, value : Href) : Nil
      # A boolean attribute that is present, such as `hidden`.
      abstract def attribute(name : String) : Nil
      abstract def started(tag : Tag) : Nil
      abstract def finish(tag : Tag) : Nil
      abstract def text(text : String) : Nil
      abstract def raw(html : SafeHTML) : Nil
      # The document's head, between `<html>` and `<body>`: the title, and
      # the assets to load (`View#document`).
      # *alternate* is the URL of the page's markdown, for an agent-readable
      # page. With *morph*, Turbo morphs page refreshes.
      abstract def head(title : String, stylesheets : Array(Asset::Stylesheet), scripts : Array(Asset::Script), alternate : String? = nil, morph : Bool = false) : Nil
      # Whether `chrome` blocks are written.
      abstract def chrome? : Bool

      # Whether forms are described rather than written: markdown's action
      # blocks. Such a backend gets where each form is sent (`form_target`)
      # and what a control's value looks like (`describe`).
      def describes_forms? : Bool
        false
      end

      # Where the form just started is sent; between `start` and `started`.
      def form_target(target : FormTarget) : Nil
      end

      # The stream a live page's HTML opens, at the end of its body
      # (`Punch::Live`). Only HTML has one.
      def live_source(url : String) : Nil
      end

      # A fact about the control just started that its attributes do not
      # say, such as `format` `date-time`; between `start` and `started`.
      def describe(name : String, value : String) : Nil
      end
    end

    # Writes HTML. Text and attribute values are escaped; only `raw` writes
    # markup as it is.
    class HTMLBackend < Backend
      # With *base*, links to pages and assets are written as absolute
      # URLs below it, as mail needs (`Href#absolute`).
      def initialize(@io : IO, @base : String? = nil)
      end

      def start(tag : Tag) : Nil
        if tag.html?
          @io << "<!doctype html>\n"
        end
        @io << '<' << tag.name
      end

      def attribute(name : String, value : String) : Nil
        @io << ' ' << name << "=\""
        HTML.escape(value, @io)
        @io << '"'
      end

      def attribute(name : String, value : Href) : Nil
        base = @base
        attribute(name, base ? value.absolute(base) : value.url)
      end

      def attribute(name : String) : Nil
        @io << ' ' << name
      end

      def started(tag : Tag) : Nil
        @io << '>'
        @io << '\n' if tag.breaks_after_start?
      end

      def finish(tag : Tag) : Nil
        @io << "</" << tag.name << '>' unless tag.void?
        @io << '\n' unless tag.phrasing?
      end

      def text(text : String) : Nil
        HTML.escape(text, @io)
      end

      def raw(html : SafeHTML) : Nil
        @io << html.value
      end

      def head(title : String, stylesheets : Array(Asset::Stylesheet), scripts : Array(Asset::Script), alternate : String? = nil, morph : Bool = false) : Nil
        @io << "<head>\n<meta charset=\"utf-8\">\n"
        @io << "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
        @io << "<title>"
        HTML.escape(title, @io)
        @io << "</title>\n"
        stylesheets.each do |stylesheet|
          @io << "<link rel=\"stylesheet\" href=\""
          HTML.escape(stylesheet.url, @io)
          @io << "\" data-turbo-track=\"reload\">\n"
        end
        unless scripts.empty?
          # The import map is written as it is: its hash is in the
          # Content-Security-Policy (`Assets.csp`), and asset names and
          # URLs hold no character that needs escaping in a script.
          @io << "<script type=\"importmap\">" << Assets.table.import_map << "</script>\n"
          scripts.each do |script|
            @io << "<script type=\"module\" src=\""
            HTML.escape(script.url, @io)
            @io << "\" data-turbo-track=\"reload\"></script>\n"
          end
        end
        {% if flag?(:punch_dev) %}
          # `punch dev` reloads the page after a restart or an asset change.
          @io << "<script type=\"module\" src=\""
          HTML.escape(Asset::Script.new(Dev::SCRIPT).url, @io)
          @io << "\"></script>\n"
        {% end %}
        if alternate
          @io << "<link rel=\"alternate\" type=\"text/markdown\" href=\""
          HTML.escape(alternate, @io)
          @io << "\">\n"
        end
        if morph
          @io << "<meta name=\"turbo-refresh-method\" content=\"morph\">\n"
          @io << "<meta name=\"turbo-refresh-scroll\" content=\"preserve\">\n"
        end
        @io << "</head>\n"
      end

      def chrome? : Bool
        true
      end

      # Turbo opens the stream with `EventSource` while the element is on
      # the page, and closes it when a visit replaces the body.
      def live_source(url : String) : Nil
        @io << "<turbo-stream-source src=\""
        HTML.escape(url, @io)
        @io << "\"></turbo-stream-source>\n"
      end
    end
  end
end
