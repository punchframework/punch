require "xml"

module Punch::Spec
  # The HTML of *component*, as a page would send it. Without an
  # *authorizer*, every form and link renders; with one
  # (`Punch::Policy::Authorizer.new(actor, reader)`), they ask their policies, as on
  # a page.
  def self.render(component : Component, *, authorizer : Policy::Authorizer? = nil) : String
    HTMLView.render(component, authorizer: authorizer).value
  end

  # *component* as markdown, as an agent reads a page. A component that
  # writes raw HTML does not compile here.
  def self.markdown(component : Component, *, authorizer : Policy::Authorizer? = nil) : String
    View.markdown(component, authorizer)
  end

  # The `Accept` header a browser sends for a page.
  BROWSER_ACCEPT = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"

  # The `Accept` header Turbo sends with a form.
  TURBO_FORM_ACCEPT = "text/vnd.turbo-stream.html, text/html, application/xhtml+xml"

  # The Turbo Stream actions of *stream*, as a response would carry them.
  # Without an *authorizer*, every form and link renders.
  def self.render(stream : TurboStream, *, authorizer : Policy::Authorizer? = nil) : String
    stream.render(authorizer).value
  end

  # Parsed HTML for questions about elements: `Punch::Spec.html(body).find("main h1")`.
  # Uses libxml2's HTML parser, so only spec binaries link it.
  struct HTML
    getter source : String

    def initialize(@source : String)
      @document = XML.parse_html(source, XML::HTMLParserOptions::RECOVER | XML::HTMLParserOptions::NOERROR |
                                         XML::HTMLParserOptions::NOWARNING | XML::HTMLParserOptions::NONET)
    end

    # Elements matching a CSS selector, in document order. Supported: type
    # (`td`), `*`, `#id`, `.class`, `[attr]`, `[attr=value]`, `[attr^=value]`,
    # `[attr*=value]`, the descendant and child (`>`) combinators, and lists
    # (`h1, h2`).
    def find(selector : String) : Array(XML::Node)
      @document.xpath_nodes(Selector.xpath(selector)).to_a
    end

    # The text of the first element matching *selector*, whitespace
    # collapsed; `nil` when none matches.
    def text(selector : String) : String?
      find(selector).first?.try { |node| HTML.text(node) }
    end

    # *value* quoted for an attribute selector, `"lines[0][quantity]"`.
    def self.quote(value : String) : String
      value.includes?('"') ? "'#{value}'" : %("#{value}")
    end

    # The text of *node*, whitespace collapsed.
    def self.text(node : XML::Node) : String
      node.content.gsub(/\s+/, ' ').strip
    end
  end

  def self.html(source : String) : HTML
    HTML.new(source)
  end

  # Translates the CSS selectors `HTML#find` supports into XPath.
  class Selector
    # A selector `find` cannot handle.
    class Error < Exception
    end

    def self.xpath(selector : String) : String
      selector.split(',').join(" | ") { |part| new(part.strip, selector).xpath }
    end

    @reader : Char::Reader

    private def initialize(@selector : String, @whole : String)
      raise Error.new("empty selector in #{whole.inspect}") if selector.empty?
      @reader = Char::Reader.new(selector)
    end

    protected def xpath : String
      xpath = ""
      axis = "//"
      until current == '\0'
        if current.ascii_whitespace? || current == '>'
          child = false
          while current.ascii_whitespace? || current == '>'
            child = true if current == '>'
            advance
          end
          axis = child ? "/" : "//"
          next
        end
        xpath += axis + compound
      end
      xpath
    end

    private def current : Char
      @reader.current_char
    end

    private def advance : Nil
      @reader.next_char
    end

    private def compound : String
      tag = "*"
      predicates = [] of String
      if current == '*'
        advance
      elsif current.ascii_letter?
        tag = name
      end
      loop do
        case current
        when '#'
          advance
          predicates << "[@id=#{literal(name)}]"
        when '.'
          advance
          predicates << "[contains(concat(' ', normalize-space(@class), ' '), #{literal(" #{name} ")})]"
        when '['
          advance
          predicates << attribute
        when '\0', '>', ' ', '\t', '\n'
          break
        else
          raise Error.new("unsupported selector syntax at #{current.inspect} in #{@whole.inspect}")
        end
      end
      tag + predicates.join
    end

    private def attribute : String
      attribute = name
      if current == ']'
        advance
        return "[@#{attribute}]"
      end
      operator = current == '=' ? "" : current.to_s
      advance unless operator.empty?
      raise Error.new("expected = in #{@whole.inspect}") unless current == '='
      advance
      value = attribute_value
      raise Error.new("expected ] in #{@whole.inspect}") unless current == ']'
      advance

      case operator
      when ""  then "[@#{attribute}=#{literal(value)}]"
      when "^" then "[starts-with(@#{attribute}, #{literal(value)})]"
      when "*" then "[contains(@#{attribute}, #{literal(value)})]"
      else          raise Error.new("unsupported attribute operator #{operator}= in #{@whole.inspect}")
      end
    end

    private def name : String
      String.build do |io|
        while current.ascii_alphanumeric? || current == '-' || current == '_'
          io << current
          advance
        end
      end
    end

    private def attribute_value : String
      quote = current
      return name unless quote == '"' || quote == '\''

      advance
      value = String.build do |io|
        until current == quote
          raise Error.new("unterminated string in #{@whole.inspect}") if current == '\0'
          io << current
          advance
        end
      end
      advance
      value
    end

    private def literal(value : String) : String
      return "'#{value}'" unless value.includes?('\'')
      return %("#{value}") unless value.includes?('"')

      raise Error.new("a value with both quote characters is not supported: #{@whole.inspect}")
    end
  end

  # `.should have_element(selector, text: ..., count: ...)`: an element
  # matching the CSS selector, with exactly that text (whitespace
  # collapsed) or text matching a Regex, *count* times if given.
  struct ElementExpectation
    def initialize(@selector : String, @text : String | Regex?, @count : Int32?)
    end

    def match(actual : String | Response) : Bool
      found = matching(actual)
      (count = @count) ? found.size == count : !found.empty?
    end

    def failure_message(actual : String | Response) : String
      all = document(actual).find(@selector)
      texts = all.first(10).map { |node| HTML.text(node).inspect }
      found = all.empty? ? "none matches #{@selector}" : "#{all.size} match #{@selector}: #{texts.join(", ")}#{all.size > 10 ? ", …" : ""}"
      "Expected #{description}; #{found}\nin:\n#{source(actual)[0, 3000]}"
    end

    def negative_failure_message(actual : String | Response) : String
      "Expected no #{description.lchop("an ")}, found #{matching(actual).size}\nin:\n#{source(actual)[0, 3000]}"
    end

    private def description : String
      String.build do |io|
        io << (@count ? "#{@count} element(s)" : "an element") << " matching " << @selector
        if text = @text
          io << " with text " << text.inspect
        end
      end
    end

    private def matching(actual : String | Response) : Array(XML::Node)
      nodes = document(actual).find(@selector)

      case text = @text
      in Nil    then nodes
      in String then nodes.select { |node| HTML.text(node) == text }
      in Regex  then nodes.select { |node| text.matches?(HTML.text(node)) }
      end
    end

    private def document(actual : String | Response) : HTML
      HTML.new(source(actual))
    end

    private def source(actual : String | Response) : String
      actual.is_a?(Response) ? actual.body : actual
    end
  end
end

module Punch::Spec
  # `.should redirect_to(href)`: a `303 See Other` to *href*, the answer
  # to a form a Command accepted.
  struct RedirectExpectation
    def initialize(@target : String)
    end

    def match(actual : Response) : Bool
      actual.status.see_other? && actual.headers["Location"]? == @target
    end

    def failure_message(actual : Response) : String
      "Expected 303 See Other to #{@target}, got #{actual.status.code} #{actual.headers["Location"]?.try { |location| "to #{location}" } || "without Location"}" \
      "#{actual.status.code >= 400 ? "\n#{actual.body[0, 3000]}" : ""}"
    end

    def negative_failure_message(actual : Response) : String
      "Expected no redirect to #{@target}"
    end
  end

  # `.should have_field_error(name, code)`: the form's control named
  # *name* (`email`, `lines[0][quantity]`) is marked invalid and shows the
  # error *code* (its `data-code`, whatever the message's language); with
  # *code* `nil`, any error.
  struct FieldErrorExpectation
    def initialize(@name : String, @code : String?)
    end

    def match(actual : String | Response) : Bool
      !errors(actual).nil?
    end

    def failure_message(actual : String | Response) : String
      html = HTML.new(source(actual))
      controls = html.find("[name=#{quoted}]")
      found = if controls.empty?
                "no control is named #{@name}"
              elsif controls.none? { |control| control["aria-invalid"]? == "true" }
                "#{@name} is not marked invalid"
              else
                "its errors are #{shown(html, controls).inspect}"
              end
      "Expected the field #{@name} to show #{@code ? "the error #{@code}" : "an error"}; #{found}\nin:\n#{source(actual)[0, 3000]}"
    end

    def negative_failure_message(actual : String | Response) : String
      "Expected the field #{@name} not to show #{@code ? "the error #{@code}" : "an error"}"
    end

    private def errors(actual : String | Response) : Array(String)?
      html = HTML.new(source(actual))
      controls = html.find("[name=#{quoted}]").select { |control| control["aria-invalid"]? == "true" }
      return if controls.empty?

      codes = shown(html, controls)
      (code = @code) ? (codes if codes.includes?(code)) : (codes unless codes.empty?)
    end

    private def shown(html : HTML, controls : Array(XML::Node)) : Array(String)
      controls.flat_map do |control|
        (control["aria-describedby"]? || "").split.flat_map do |id|
          html.find("[id=#{HTML.quote(id)}] .field-error").map { |node| node["data-code"]? || HTML.text(node) }
        end
      end
    end

    private def quoted : String
      HTML.quote(@name)
    end

    private def source(actual : String | Response) : String
      actual.is_a?(Response) ? actual.body : actual
    end
  end
end

module Spec::Expectations
  def redirect_to(target : Punch::Href | String)
    Punch::Spec::RedirectExpectation.new(target.to_s)
  end

  def have_field_error(name : String, code : String? = nil)
    Punch::Spec::FieldErrorExpectation.new(name, code)
  end

  # `.should have_stream_action(:replace, invoice.id)`: a Turbo Stream
  # action on that target; with *containing*, a CSS selector its content
  # must match (and *text*, that element's text).
  def have_stream_action(action : Punch::TurboStream::Action, target : Punch::TypedID | String, *, containing : String? = nil,
                         text : String | Regex? = nil)
    selector = "turbo-stream[action=#{action.to_s.downcase}][target=#{Punch::Spec::HTML.quote(Punch::TurboStream.target(target))}]"
    selector = "#{selector} > template #{containing}" if containing
    Punch::Spec::ElementExpectation.new(selector, text, nil)
  end

  def have_element(selector : String, *, text : String | Regex? = nil, count : Int32? = nil)
    Punch::Spec::ElementExpectation.new(selector, text, count)
  end
end
