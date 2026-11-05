require "compiler/crystal/syntax"
require "yaml"
require "./docs_check/generated"
require "./docs_check/messages"

module Punch
  # The checks behind `punch docs:check`, for Punch's own documentation. Not
  # part of `require "punch"`.
  #
  # - Every code block in a guide (`docs/guides/`) says what keeps it true:
  #   `source=PATH [select=NAMES] [elide=NAMES] [bare[=NAMES]]` copies a file
  #   or some of its definitions (`bare`: their doc comments and
  #   annotations, or those of the definitions it names, as `# ...`), `fails=spec/fail/NAME.cr` shows a file that must not
  #   compile (the next `text` block holds its message), `illustrative="why"`
  #   is neither, and `console` and `text` blocks need nothing, unless
  #   they say `message=PATH`: then they quote a message of that file
  #   (`Messages`). In "Common mistakes", every `text` and `console` block
  #   does, or follows a failing example.
  # - Each copy matches its source; `--write` refreshes the copies.
  # - Relative links and their anchors resolve in every page under `docs/`,
  #   and every `lib/punch/docs/…` path in Punch's sources and template
  #   names a page (and heading) that exists.
  # - `docs/llms.txt` lists every page, `docs/README.md` every page outside
  #   the guides, and `docs/guides/README.md` every guide; each guide states
  #   the Punch version it applies to and ends its topic with "Rules".
  module DocsCheck
    DIRECTORY = "docs"
    GUIDES    = "docs/guides"
    INDEX     = "docs/llms.txt"
    # The front page for people, and the guides' own index.
    FRONT          = "docs/README.md"
    GUIDES_INDEX   = "docs/guides/README.md"
    COMPILE_ERRORS = "spec/core/compile_errors_spec.cr"
    # Where Punch names its pages by their path in an app.
    CITING = %w[src template]
    # Guides with no "Rules" section: indexes, the introduction, and the tutorial.
    NO_RULES = %w[README.md glossary.md getting-started.md introduction.md]
    # The section whose quoted messages must name their source.
    MISTAKES = "## Common mistakes"
    # Pages under `docs/guides/` that are not guides.
    NOT_GUIDES = %w[README.md glossary.md]
    # The comment that starts a copied file, by the block's language.
    COMMENTS = {"crystal" => "# ", "yaml" => "# ", "sh" => "# ", "sql" => "-- ", "ruby" => "# "}
    # Languages whose illustrative blocks need a reason: the ones a reader
    # could mistake for Punch code.
    CODE = %w[crystal sql ecr]

    record Problem, path : String, line : Int32, message : String do
      def to_s(io : IO) : Nil
        io << path << ':' << line << ": " << message
      end
    end

    record Outcome, problems : Array(Problem), pages : Int32, quotes : Int32, links : Int32, written : Array(String)

    # A fenced code block: its info string and the lines between the fences
    # (indexes into the page's lines).
    record Fence, info : String, open : Int32, close : Int32, content : String do
      def language : String
        info.split(' ', 2).first? || ""
      end

      # `key=value`, `key="a value"`, or a bare `key` (an empty string).
      def attributes : Hash(String, String)
        attributes = {} of String => String
        info.lchop(language).scan(/(\w+)(?:=(?:"([^"]*)"|(\S+)))?/) do |match|
          attributes[match[1]] = match[2]? || match[3]? || ""
        end
        attributes
      end
    end

    # A markdown page: its lines, fences, and the anchors of its headings.
    class Page
      getter path : String
      getter lines : Array(String)
      getter fences = [] of Fence
      @anchors : Set(String)?

      def initialize(@path : String, text : String)
        @lines = text.lines
        scan
      end

      def anchors : Set(String)
        @anchors ||= begin
          anchors = Set(String).new
          counts = Hash(String, Int32).new(0)
          prose_lines.each do |_, line|
            if heading = line.match(/^\#{1,6}\s+(.*?)\s*#*\s*$/)
              slug = DocsCheck.slug(heading[1])
              anchors << (counts[slug] == 0 ? slug : "#{slug}-#{counts[slug]}")
              counts[slug] += 1
            end
            line.scan(/<a\s+(?:id|name)="([^"]+)"/) { |match| anchors << match[1] }
          end
          anchors
        end
      end

      # Each line outside code blocks, with its number.
      def prose_lines : Array({Int32, String})
        inside = Set(Int32).new
        fences.each { |fence| (fence.open..fence.close).each { |index| inside << index } }
        lines.each_with_index.reject { |_, index| inside.includes?(index) }.map { |line, index| {index + 1, line} }.to_a
      end

      # The page with *fence*'s content replaced.
      def replace(fence : Fence, content : String) : Nil
        @lines = lines[0..fence.open] + content.lines + lines[fence.close..]
        @fences.clear
        scan
      end

      def text : String
        lines.join('\n') + "\n"
      end

      private def scan : Nil
        index = 0
        while index < lines.size
          if open = lines[index].match(/^\s*(`{3,}|~{3,})\s*(.*)$/)
            marker = open[1]
            close = (index + 1...lines.size).find { |i| lines[i].strip.starts_with?(marker) && lines[i].strip.chars.all?(marker[0]) } || lines.size
            @fences << Fence.new(open[2].strip, index, close, lines[index + 1...close].join('\n'))
            index = close + 1
          else
            index += 1
          end
        end
      end
    end

    # GitHub's anchor for a heading: lowercase, without punctuation, spaces
    # as hyphens.
    def self.slug(heading : String) : String
      text = heading.gsub(/\[([^\]]*)\]\([^)]*\)/, "\\1")
      text.downcase.gsub(/[^\p{L}\p{N}\- _]/, "").gsub(' ', '-')
    end

    def self.run(write : Bool) : Outcome
      Run.new(write).run
    end

    private class Run
      @problems = [] of Problem
      @quotes = 0
      @links = 0
      @written = [] of String
      @pages = {} of String => Page
      @messages = {} of String => Array(Regex)

      def initialize(@write : Bool)
      end

      def run : Outcome
        generate
        Dir.glob(File.join(DIRECTORY, "**", "*.md")).sort!.each do |path|
          next if path.starts_with?(File.join(GUIDES, "examples") + "/")
          @pages[path] = Page.new(path, File.read(path))
        end
        guides.each { |page| check_guide(page) }
        @pages.each_value { |page| check_links(page) }
        check_index
        check_front_pages
        check_citations
        Outcome.new(@problems, @pages.size, @quotes, @links, @written)
      end

      # The generated reference pages: written in write mode, compared
      # otherwise.
      private def generate : Nil
        Generated.pages.each do |page|
          case text = page.text
          in Problem then @problems << text
          in String
            current = File.exists?(page.path) ? File.read(page.path) : nil
            next if current == text
            if @write
              Dir.mkdir_p(File.dirname(page.path))
              File.write(page.path, text)
              written(page.path)
            else
              problem(page.path, 1, "#{page.path} does not match #{page.sources}. Run 'punch docs:check --write'; never edit it by hand.")
            end
          end
        end
      end

      private def guides : Array(Page)
        @pages.values.select { |page| page.path.starts_with?(GUIDES + "/") && !File.basename(page.path).starts_with?('_') }
      end

      private def written(path : String) : Nil
        @written << path unless @written.includes?(path)
      end

      private def problem(path : String, line : Int32, message : String) : Nil
        @problems << Problem.new(path, line, message)
      end

      private def check_guide(page : Page) : Nil
        name = File.basename(page.path)
        fences(page)
        unless NOT_GUIDES.includes?(name)
          expected = "Applies to Punch #{DocsCheck.version_range}."
          line = page.lines.index(&.starts_with?("Applies to Punch "))
          if line.nil?
            problem(page.path, 1, "A guide states the Punch version it applies to, near the top: #{expected}")
          elsif page.lines[line].strip != expected
            problem(page.path, line + 1, "The version line reads '#{page.lines[line].strip}'; this Punch is '#{expected}'.")
          end
        end
        unless NO_RULES.includes?(name) || page.lines.any?(&.==("## Rules"))
          problem(page.path, page.lines.size, "A topic guide ends with a '## Rules' section: its invariants as short imperative lines.")
        end
      end

      # Each block of *page*: quoted, failing, illustrative with a reason,
      # `console`, or `text`. Quotes are refreshed in write mode, which
      # changes the page's lines, so the blocks are walked by position.
      private def fences(page : Page) : Nil
        index = 0
        changed = false
        while fence = page.fences[index]?
          attributes = fence.attributes
          line = fence.open + 1
          if source = attributes["source"]?
            @quotes += 1

            case expected = Quote.new(source, fence.language, attributes["select"]?, attributes["elide"]?, bare: attributes["bare"]?).text
            in Problem then problem(page.path, line, expected.message)
            in String
              if expected != fence.content
                if @write
                  page.replace(fence, expected)
                  changed = true
                else
                  problem(page.path, line, "This copy of #{source}#{attributes["select"]?.try { |names| " (#{names})" }} differs from the source. Run 'punch docs:check --write' and review the change.")
                end
              end
            end
          elsif fixture = attributes["fails"]?
            failing(page, fence, fixture, page.fences[index + 1]?)
          elsif attributes.has_key?("illustrative")
            if CODE.includes?(fence.language) && attributes["illustrative"].empty?
              problem(page.path, line, %(An illustrative #{fence.language} block names why it is not quoted: illustrative="fragment of Send#call".))
            end
          else
            plain(page, fence, attributes, index > 0 ? page.fences[index - 1] : nil)
          end
          index += 1
        end
        if changed
          File.write(page.path, page.text)
          written(page.path)
        end
      end

      # A `console` or `text` block: it needs nothing, unless it quotes a
      # message or stands under "Common mistakes", where a message names
      # its source (or follows the failing example it belongs to).
      private def plain(page : Page, fence : Fence, attributes : Hash(String, String), previous : Fence?) : Nil
        line = fence.open + 1
        plain = {"console", "text"}.includes?(fence.language)
        if plain && (sources = attributes["message"]?)
          message(page, fence, sources)
        elsif !plain || fence.info != fence.language
          problem(page.path, line, %(A code block in a guide is quoted (source=PATH select=NAME), fails (fails=spec/fail/NAME.cr), illustrative (illustrative="why"), console, or text; this one is '#{fence.info}'.))
        elsif mistakes?(page, fence) && !previous.try(&.attributes.has_key?("fails"))
          problem(page.path, line, %(A message under "Common mistakes" names the file it comes from, so it stays current: a 'text message=src/punch/ameba/sql_text.cr' block, or 'message=crystal' (sqlite, turbo) for another program's.))
        end
      end

      # A block that quotes a message of one of *sources* (comma-separated
      # paths) holds it as the source writes it now.
      private def message(page : Page, fence : Fence, sources : String) : Nil
        paths = sources.split(',').map(&.strip)
        return if paths.any? { |path| Messages::EXTERNAL.includes?(path) }

        line = fence.open + 1
        if missing = paths.find { |path| !File.file?(path) }
          return problem(page.path, line, "#{missing} does not exist.")
        end
        patterns = paths.flat_map { |path| @messages[path] ||= Messages.of(path) }
        found = if paths.any? { |path| Messages.anywhere?(path) }
                  patterns.any?(&.matches?(fence.content))
                else
                  Messages.covers?(patterns, fence.content)
                end
        return if found

        problem(page.path, line, "This message is not in #{paths.join(" or ")}: each line of the block is a string there, to its end, with its interpolations as any text. Copy the message as the source writes it now.")
      end

      # Whether *fence* is in the page's "Common mistakes".
      private def mistakes?(page : Page, fence : Fence) : Bool
        page.lines[0...fence.open].reverse_each.find(&.starts_with?("## ")) == MISTAKES
      end

      # A block that must not compile matches its fixture, and the `text`
      # block after it holds the message the compile-error spec expects.
      private def failing(page : Page, fence : Fence, fixture : String, message : Fence?) : Nil
        line = fence.open + 1
        unless File.exists?(fixture)
          return problem(page.path, line, "#{fixture} does not exist.")
        end

        source = File.read(fixture).lines.skip_while { |text| text.starts_with?("require ") || text.blank? }.join('\n').rstrip
        if source != fence.content
          if @write
            page.replace(fence, source)
            File.write(page.path, page.text)
            written(page.path)
          else
            problem(page.path, line, "This copy of #{fixture} differs from the fixture. Run 'punch docs:check --write' and review the change.")
          end
        end
        expected = DocsCheck.compile_errors[File.basename(fixture, ".cr")]?
        if expected.nil?
          problem(page.path, line, "#{fixture} has no expected message in #{COMPILE_ERRORS}.")
        elsif message.nil? || message.info != "text" || !message.content.includes?(expected)
          problem(page.path, line, "The 'text' block after a failing example holds the compiler's message, which includes: #{expected}")
        end
      end

      private def check_links(page : Page) : Nil
        page.prose_lines.each do |number, line|
          line.gsub(/`[^`]*`/, "").scan(/\]\(([^)\s]+)(?:\s+"[^"]*")?\)/) do |match|
            target = match[1]
            next if target.matches?(/^[a-z][a-z0-9+.-]*:/i)
            @links += 1
            path, _, anchor = target.partition('#')
            resolved = path.empty? ? page.path : Path[File.dirname(page.path), path].normalize.to_s
            target_exists(page.path, number, target, resolved, anchor)
          end
        end
      end

      private def target_exists(path : String, line : Int32, target : String, resolved : String, anchor : String) : Nil
        unless File.exists?(resolved)
          return problem(path, line, "The link to #{target} leads nowhere: #{resolved} does not exist.")
        end
        return if anchor.empty?

        page = @pages[resolved]? || (resolved.ends_with?(".md") ? Page.new(resolved, File.read(resolved)) : nil)
        unless page && page.anchors.includes?(anchor)
          problem(path, line, "The link to #{target} leads nowhere: #{resolved} has no heading with the anchor '##{anchor}'.")
        end
      end

      # The index names every page.
      private def check_index : Nil
        index = @pages[INDEX]? || (File.exists?(INDEX) ? Page.new(INDEX, File.read(INDEX)) : nil)
        unless index
          return problem(INDEX, 1, "#{INDEX} is missing: the index of every guide and reference page, in llms.txt format.")
        end

        check_links(index) unless @pages.has_key?(INDEX)
        listed = index.lines.flat_map(&.scan(/\]\(([^)#\s]+)/).map { |match| Path[DIRECTORY, match[1]].normalize.to_s })
        @pages.each_key do |path|
          next if File.basename(path).starts_with?('_')
          problem(INDEX, 1, "#{path} is not in the index. Add a line: - [Title](#{Path[path].relative_to(DIRECTORY)}): what it answers.") unless listed.includes?(path)
        end
      end

      # The front page names every page outside the guides, and the guides'
      # index every guide, so a person browsing `docs/` finds each page.
      private def check_front_pages : Nil
        others = @pages.keys.reject { |path| path.starts_with?(GUIDES + "/") || path == FRONT }
        listed_in(FRONT, others, "the front page for people")
        listed_in(GUIDES_INDEX, guides.map(&.path).reject(GUIDES_INDEX), "the guides by group")
      end

      private def listed_in(index_path : String, paths : Array(String), what : String) : Nil
        return if paths.empty?
        unless index = @pages[index_path]?
          return problem(index_path, 1, "#{index_path} is missing: #{what}, linking every page.")
        end

        directory = File.dirname(index_path)
        listed = index.lines.flat_map(&.scan(/\]\(([^)#\s]+)/).map { |match| Path[directory, match[1]].normalize.to_s })
        paths.each do |path|
          next if File.basename(path).starts_with?('_')
          problem(index_path, 1, "#{path} is not linked from #{index_path} (#{what}). Add a line: - [Title](#{Path[path].relative_to(directory)}): what it answers.") unless listed.includes?(path)
        end
      end

      # `lib/punch/docs/PAGE#ANCHOR` in Punch's sources and template: where
      # an app finds the page.
      private def check_citations : Nil
        CITING.each do |directory|
          Dir.glob(File.join(directory, "**", "*")).sort!.each do |path|
            next unless File.file?(path)
            File.read_lines(path).each_with_index(1) do |line, number|
              line.scan(%r{lib/punch/docs/([\w/.-]+\.md)(?:#([\w-]+))?}) do |match|
                @links += 1
                target_exists(path, number, match[0], File.join(DIRECTORY, match[1]), match[2]? || "")
              end
            end
          end
        end
      end
    end

    # The copy a quoting block should hold.
    struct Quote
      def initialize(@source : String, @language : String, @select : String?, @elide : String?, *, @bare : String? = nil)
      end

      def text : String | Problem
        return Problem.new(@source, 1, "#{@source} does not exist.") unless File.file?(@source)

        content = File.read(@source)
        names = @select.try(&.split(',').map(&.strip)) || [] of String
        body = if names.empty?
                 content.rstrip
               else
                 case @language
                 when "crystal" then Excerpt.new(@source, content, (@elide.try(&.split(',').map(&.strip)) || [] of String), bare: @bare.try { |bare| bare.empty? ? [] of String : bare.split(',').map(&.strip) }).render(names)
                 when "sql"     then sql(content, names)
                 when "yaml"    then yaml(content, names)
                 else                Problem.new(@source, 1, "select= works in crystal, sql, and yaml blocks, not #{@language}.")
                 end
               end
        return body if body.is_a?(Problem)

        comment = COMMENTS[@language]?
        comment ? "#{comment}#{shown_path}\n#{body}" : body
      end

      # The path as the app sees it: the reference app and the examples app
      # are apps, so their prefix is left out.
      private def shown_path : String
        @source.lchop("reference/").lchop("docs/guides/examples/")
      end

      # Named queries by `-- name:`, each up to the next one.
      private def sql(content : String, names : Array(String)) : String | Problem
        lines = content.lines
        names.map do |name|
          start = lines.index(&.matches?(/^--\s*name:\s*#{Regex.escape(name)}\s/))
          return Problem.new(@source, 1, "#{@source} has no query '-- name: #{name}'.") unless start

          finish = (start + 1...lines.size).find { |i| lines[i].starts_with?("-- name:") } || lines.size
          lines[start...finish].join('\n').rstrip
        end.join("\n\n")
      end

      # A key and everything indented under it, by its path `a.b.c`, below
      # the lines of the keys that hold it. Keys left out before it show as
      # `# ...`.
      private def yaml(content : String, names : Array(String)) : String | Problem
        lines = content.lines
        level_of = ->(i : Int32) { lines[i].size - lines[i].lstrip.size }
        content_line = ->(i : Int32) { !lines[i].blank? && !lines[i].lstrip.starts_with?('#') }
        shown = Set(Int32).new
        names.each do |name|
          start, indent = 0, -1
          name.split('.').each do |key|
            # Only the direct children of the key found last: `en.invoices`
            # is not `en.layout.invoices`.
            child = ((indent >= 0 ? start + 1 : start)...lines.size).find(&content_line)
            found = child.try do |from|
              (from...lines.size).find do |i|
                next false unless content_line.call(i)
                break if level_of.call(i) <= indent
                level_of.call(i) == level_of.call(from) && lines[i].lstrip.starts_with?("#{key}:")
              end
            end
            return Problem.new(@source, 1, "#{@source} has no key #{name}.") unless found

            shown << found
            start, indent = found, level_of.call(found)
          end
          finish = (start + 1...lines.size).find { |i| content_line.call(i) && level_of.call(i) <= indent } || lines.size
          (start...finish).each { |i| shown << i }
        end
        # Every shown line once, in the file's order, and `# ...` where
        # lines between two of them are left out.
        out = [] of String
        previous = nil
        shown.to_a.sort!.each do |i|
          skipped = previous ? (previous + 1...i) : (0...i)
          out << "#{" " * level_of.call(i)}# ..." if previous && skipped.any?(&content_line)
          out << lines[i]
          previous = i
        end
        out.join('\n').rstrip
      end
    end

    # Some definitions of a Crystal file, by name, inside the modules and
    # types that hold them, as the file writes them. Siblings left out show
    # as `# ...`, and so do the bodies of the inner definitions in *elide*.
    class Excerpt
      @lines : Array(String)
      @out = [] of String
      # The first line of the siblings left out since the last one shown.
      @omitted : Int32? = nil
      # Whether the last line shown opens a module or type.
      @opened = false

      def initialize(@path : String, @source : String, @elide : Array(String), *, @bare : Array(String)? = nil)
        @lines = @source.lines
      end

      def render(names : Array(String)) : String | Problem
        root = Crystal::Parser.parse(@source)
        found = [] of String
        collect(found, items(root), "")
        names = joined(names, found)
        if missing = names.find { |name| !found.includes?(name) }
          return Problem.new(@path, 1, "#{@path} defines no #{missing}. It defines: #{found.join(", ")}.")
        end

        emit(items(root), "", names)
        flush
        @out.join('\n')
      rescue ex : Crystal::SyntaxException
        Problem.new(@path, ex.line_number, ex.message || "syntax error")
      end

      # The names of `select=`, split at commas, with the pieces of an
      # example's description that holds a comma joined again.
      private def joined(pieces : Array(String), found : Array(String)) : Array(String)
        names = [] of String
        current = nil
        pieces.each do |piece|
          current = current ? "#{current}, #{piece}" : piece
          if found.includes?(current)
            names << current
            current = nil
          end
        end
        current ? names << current : names
      end

      private def items(node : Crystal::ASTNode) : Array(Crystal::ASTNode)
        case node
        when Crystal::Expressions then node.expressions.reject(Crystal::Nop)
        when Crystal::Nop         then [] of Crystal::ASTNode
        else                           [node] of Crystal::ASTNode
        end
      end

      # The name a definition is selected by: `A::B` for a type (also one
      # `record` or `Punch.composite` declares), `A::B#m`
      # and `A::B.m` for methods, and for an example its full description
      # as the spec runner prints it (`customers API creates a customer`).
      private def name(node : Crystal::ASTNode, prefix : String) : String?
        case node
        when Crystal::VisibilityModifier then name(node.exp, prefix)
        when Crystal::Def                then "#{prefix}#{node.receiver ? "." : "#"}#{node.name}"
        when Crystal::Macro              then "#{prefix}.#{node.name}"
        when Crystal::Call               then example(node).try { |own| prefix.empty? ? own : "#{prefix} #{own}" } || type_name(node).try { |own| prefix.empty? ? own : "#{prefix}::#{own}" }
        else
          type_name(node).try { |own| prefix.empty? ? own : "#{prefix}::#{own}" }
        end
      end

      # The name of a type or constant *node* defines, without its prefix.
      private def type_name(node : Crystal::ASTNode) : String?
        case node
        when Crystal::ModuleDef, Crystal::ClassDef, Crystal::EnumDef, Crystal::AnnotationDef, Crystal::Alias
          node.name.to_s
        when Crystal::Call
          # `record Name, …` defines a struct, and so does `Punch.composite
          # Name, …`.
          first = node.args.first?
          declares = (node.name == "record" && node.obj.nil?) || (node.name == "composite" && node.obj.to_s == "Punch")
          first.to_s if declares && first.is_a?(Crystal::Path)
        when Crystal::Assign
          target = node.target
          target.to_s if target.is_a?(Crystal::Path)
        end
      end

      # What `describe`, `context`, or `it` describes, for a call of one.
      private def example(node : Crystal::Call) : String?
        return unless node.obj.nil? && {"describe", "context", "it"}.includes?(node.name) && node.block

        case first = node.args.first?
        when Crystal::StringLiteral then first.value
        when Crystal::Path          then first.to_s
        end
      end

      private def body(node : Crystal::ASTNode) : Crystal::ASTNode?
        case node
        when Crystal::VisibilityModifier           then body(node.exp)
        when Crystal::ModuleDef, Crystal::ClassDef then node.body
        when Crystal::EnumDef                      then Crystal::Expressions.new(node.members)
        when Crystal::Call                         then node.block.try(&.body) if example(node) || type_name(node)
        end
      end

      private def collect(found : Array(String), nodes : Array(Crystal::ASTNode), prefix : String) : Nil
        nodes.each do |node|
          next unless own = name(node, prefix)
          found << own
          if inner = body(node)
            collect(found, items(inner), own)
          end
        end
      end

      private def emit(nodes : Array(Crystal::ASTNode), prefix : String, names : Array(String)) : Nil
        nodes.each do |node|
          # A require is the file's plumbing, not a definition left out.
          next if node.is_a?(Crystal::Annotation) || node.is_a?(Crystal::Require)
          own = name(node, prefix)
          if own && names.includes?(own)
            flush
            selected(node, own)
          elsif own && (inner = body(node)) && names.any? { |wanted| {"::", "#", ".", " "}.any? { |separator| wanted.starts_with?("#{own}#{separator}") } }
            flush
            (head(node, own)..header_end(node)).each { |number| @out << line(number) }
            @opened = true
            emit(items(inner), own, names)
            flush
            @out << line(end_line(node))
          else
            @omitted ||= leading(start_line(node))
          end
        end
      end

      # The definition with the comments and annotations right above it,
      # inner definitions named in `elide` shortened to their signature.
      private def selected(node : Crystal::ASTNode, own : String) : Nil
        skipped = [] of Range(Int32, Int32)
        elided(node, skipped)
        line = head(node, own)
        while line <= end_line(node)
          if range = skipped.find(&.begin.==(line))
            @out << "#{indent(range.begin)}# ..."
            line = range.end + 1
          else
            @out << line(line)
            line += 1
          end
        end
      end

      # Starts *node* with the comments and annotations right above it, and
      # returns the line to go on from. With `bare` (every definition, or
      # those it names) they show as `# ...`, one with the siblings left out
      # just before.
      private def head(node : Crystal::ASTNode, own : String) : Int32
        first = leading(start_line(node))
        bare = @bare.try { |names| names.empty? || names.includes?(own) }
        return first.tap { spaced(first) } unless bare && first < start_line(node)

        marker = "#{indent(start_line(node))}# ..."
        unless @out.last? == marker
          spaced(first)
          @out << marker
        end
        start_line(node)
      end

      private def elided(node : Crystal::ASTNode, skipped : Array(Range(Int32, Int32))) : Nil
        inner = case node
                when Crystal::Def then return
                else                   body(node)
                end
        return unless inner

        items(inner).each do |child|
          child = child.exp if child.is_a?(Crystal::VisibilityModifier)

          short = case child
                  when Crystal::Def then child.receiver ? "self.#{child.name}" : child.name
                  else                   name(child, "").try(&.split("::").last)
                  end
          if short && @elide.includes?(short)
            contents = case child
                       when Crystal::Def then child.body
                       else                   body(child)
                       end
            first = contents.try { |content| items(content).first? }.try { |statement| leading(start_line(statement)) }
            skipped << (first..end_line(child) - 1) if first && first < end_line(child)
          else
            elided(child, skipped)
          end
        end
      end

      # The first of the comment and annotation lines right above *line*.
      private def leading(line : Int32) : Int32
        while line > 1 && (@lines[line - 2].lstrip.starts_with?('#') || @lines[line - 2].lstrip.starts_with?("@["))
          line -= 1
        end
        line
      end

      # A blank line before what starts at *line*, where the source has one
      # and the excerpt does not just open a module or type.
      private def spaced(line : Int32) : Nil
        @out << "" if !@out.empty? && !@opened && line > 1 && @lines[line - 2].blank?
        @opened = false
      end

      private def flush : Nil
        if omitted = @omitted
          spaced(omitted)
          @out << "#{indent(omitted)}# ..."
          @omitted = nil
        end
      end

      # The last line of what opens *node*: its first line, or for a
      # `record Name, …` over several lines the one with its `do`.
      private def header_end(node : Crystal::ASTNode) : Int32
        opening = node.as?(Crystal::Call).try(&.block).try(&.location).try(&.line_number)
        opening || start_line(node)
      end

      private def start_line(node : Crystal::ASTNode) : Int32
        node.location.try(&.line_number) || 1
      end

      private def end_line(node : Crystal::ASTNode) : Int32
        node.end_location.try(&.line_number) || start_line(node)
      end

      private def line(number : Int32) : String
        @lines[number - 1]
      end

      private def indent(number : Int32) : String
        text = @lines[number - 1]
        text[0, text.size - text.lstrip.size]
      end
    end

    # "0.1" before 1.0, where every minor version may break; "1.x" after.
    def self.version_range : String
      version = YAML.parse(File.read("shard.yml"))["version"].as_s
      major, minor = version.split('.')
      major == "0" ? "0.#{minor}" : "#{major}.x"
    end

    # The message each `spec/fail/` file must fail with.
    def self.compile_errors : Hash(String, String)
      errors = {} of String => String
      messages(Crystal::Parser.parse(File.read(COMPILE_ERRORS)), errors)
      errors
    end

    private def self.messages(node : Crystal::ASTNode, errors : Hash(String, String)) : Nil
      case node
      when Crystal::Expressions then node.expressions.each { |child| messages(child, errors) }
      when Crystal::Assign      then messages(node.value, errors)
      when Crystal::HashLiteral
        node.entries.each do |entry|
          key, value = entry.key, entry.value
          errors[key.value] = value.value if key.is_a?(Crystal::StringLiteral) && value.is_a?(Crystal::StringLiteral)
        end
      end
    end
  end
end
