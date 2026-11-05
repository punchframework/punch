module Punch::Spec
  # An action block of a page agents read, parsed from its markdown as an
  # agent reads it (docs/views.md): `Punch::Spec.actions(body)` or
  # `client.act(page, "Send invoice", {...})`.
  struct ActionBlock
    getter title : String
    getter method : String
    getter path : String
    getter operation_id : String
    # Every field the block names, in order.
    getter fields : Array(String)
    # The fields sent as they are (`name` = `value`): hidden fields and
    # the idempotency key.
    getter fixed : Hash(String, String)
    # The block as written, for failure messages and `contain` checks.
    getter text : String

    def initialize(@title, @method, @path, @operation_id, @fields, @fixed, @text)
    end
  end

  CODE_SPAN = /(`+) ?(.*?) ?\1(?!`)/

  # The action blocks of *markdown*, in order: each `###` heading after the
  # `## Actions` heading, in any language: the section is the page's last
  # `##` heading, since it ends the page. Headings inside a code block do
  # not count, so text a page shows verbatim (`pre`) cannot add an action
  # or a section.
  def self.actions(markdown : String) : Array(ActionBlock)
    rows = markdown.lines(chomp: false)
    outside = outside_code(rows)
    section = (0...rows.size).reverse_each.find { |index| outside[index] && rows[index].starts_with?("## ") }
    return [] of ActionBlock unless section

    starts = (section + 1...rows.size).select { |index| outside[index] && rows[index].starts_with?("### ") }
    blocks = starts.map_with_index do |start, index|
      ending = starts[index + 1]? || rows.size
      rows[start...ending].join.lchop("### ")
    end
    blocks.compact_map do |block|
      title, _, rest = block.partition('\n')
      lines = rest.lines.reject(&.empty?)
      facts = lines.first? || next
      heads = facts.scan(CODE_SPAN).map(&.[2])
      next if heads.size < 2
      method, _, path = heads[0].partition(' ')
      fields = [] of String
      fixed = {} of String => String
      lines.each do |line|
        next unless line.starts_with?("- `")
        spans = line.scan(CODE_SPAN)
        name = spans.first?.try(&.[2]) || next
        fields << name
        if line.matches?(/\A- (`+) ?.*? ?\1 = `/)
          fixed[name] = spans[1]?.try(&.[2]) || ""
        end
      end
      ActionBlock.new(title.strip.gsub(/\\(.)/, "\\1"), method, path, heads[1], fields, fixed, "### #{block.strip}")
    end
  end

  # Whether each of *lines* is outside a fenced code block (GFM: a fence
  # closes on a line of at least as many of its own characters).
  private def self.outside_code(lines : Array(String)) : Array(Bool)
    fence = nil
    lines.map do |line|
      if open = fence
        fence = nil if line.matches?(/\A {0,3}#{Regex.escape(open)}+[ \t]*\r?\n?\z/)
        false
      elsif found = line.match(/\A {0,3}(`{3,}|~{3,})/)
        fence = found[1]
        false
      else
        true
      end
    end
  end

  class Client
    # Sends an action of a page as an agent does: reads the block titled
    # *title* from *page* (`client.read`), sends its fixed fields (hidden
    # values, the idempotency key) and *fields* as a form body, or a query
    # string for a `GET`, with `Accept: text/markdown`. A field the block
    # does not name fails the example: an agent could not have known it.
    #
    # ```
    # page = client.read(Invoices::ShowPage.href(invoice_id: id), headers: Punch::Spec.bearer(token))
    # answer = client.act(page, "Send invoice", {"recipient" => "ada@example.com"}, headers: Punch::Spec.bearer(token))
    # answer.should redirect_to(Invoices::ShowPage.href(invoice_id: id))
    # ```
    def act(page : Response, title : String, fields = {} of String => String, *, headers : ::HTTP::Headers? = nil,
            file = __FILE__, line = __LINE__) : Response
      actions = Spec.actions(page.body)
      action = actions.find(&.title.==(title))
      unless action
        ::fail("No action #{title.inspect} on the page; it has #{actions.map(&.title).inspect}:\n#{page.body[0, 3000]}", file, line)
      end
      params = URI::Params.new
      action.fixed.each { |name, value| params.add(name, value) }
      fields.each do |name, value|
        name = name.to_s
        ::fail("The action #{title.inspect} has no field #{name}; it has #{action.fields.inspect}", file, line) unless action.fields.includes?(name)
        params.delete_all(name)
        values = value.is_a?(Array) ? value.map(&.to_s) : [value.to_s]
        values.each { |item| params.add(name, item) }
      end
      headers = headers.try(&.dup) || ::HTTP::Headers.new
      headers["Accept"] ||= "text/markdown"
      if action.method == "GET"
        target = params.empty? ? action.path : "#{action.path}#{action.path.includes?('?') ? '&' : '?'}#{params}"
        request("GET", target, headers: headers, file: file, line: line)
      else
        headers["Content-Type"] = "application/x-www-form-urlencoded"
        request(action.method, action.path, body: params.to_s, headers: headers, file: file, line: line)
      end
    end
  end

  # `.should have_action(title)`: the markdown has an action block titled
  # *title*; with *operation*, for that operation ID.
  struct ActionExpectation
    def initialize(@title : String, @operation : String?)
    end

    def match(actual : String | Response) : Bool
      Spec.actions(body(actual)).any? { |action| action.title == @title && (@operation.nil? || action.operation_id == @operation) }
    end

    def failure_message(actual : String | Response) : String
      titles = Spec.actions(body(actual)).map { |action| "#{action.title} (#{action.operation_id})" }
      "Expected the action #{@title.inspect}#{@operation.try { |id| " for #{id}" }}; the page has #{titles.inspect}\n#{body(actual)[0, 3000]}"
    end

    def negative_failure_message(actual : String | Response) : String
      "Expected no action #{@title.inspect}\n#{body(actual)[0, 3000]}"
    end

    private def body(actual : String | Response) : String
      actual.is_a?(Response) ? actual.body : actual
    end
  end
end

module Spec::Expectations
  def have_action(title : String, *, operation : String? = nil)
    Punch::Spec::ActionExpectation.new(title, operation)
  end
end
