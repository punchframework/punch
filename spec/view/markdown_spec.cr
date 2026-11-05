require "../spec_helper"

module MarkdownSpec
  struct Block
    include Punch::Component

    def initialize(&@block : Punch::View ->)
    end

    def view(v : Punch::View) : Nil
      @block.call(v)
    end
  end

  def self.markdown(&block : Punch::View ->) : String
    Punch::Spec.markdown(Block.new(&block))
  end

  struct InvoiceID < Punch::TypedID
  end

  LINK = Punch::Href.new("/billing/invoices/1", nil)

  # Text from users in every place the backend writes text.
  struct Probe
    include Punch::Component

    def initialize(@text : String)
    end

    def view(v : Punch::View) : Nil
      v.h2 @text
      v.p @text
      v.p do
        v.text "prefix "
        v.strong @text
        v.text " "
        v.em @text
        v.text " "
        v.a @text, href: LINK
        v.br
        v.text @text
      end
      v.ul { v.li @text }
      v.dl do
        v.dt @text
        v.dd @text
      end
      v.blockquote { v.p { v.code @text } }
      v.table do
        v.thead { v.tr { v.th @text } }
        v.tbody { v.tr { v.td { v.code @text } } }
      end
      v.pre @text
    end
  end

  # What `Probe` writes, whatever the text: Punch's markup and no other.
  # The definition list is a list of its own, its item a paragraph.
  TAGS = {"h2" => 1, "p" => 3, "strong" => 1, "em" => 1, "a" => 1, "br" => 1, "ul" => 2, "li" => 2,
          "blockquote" => 1, "code" => 3, "table" => 1, "thead" => 1, "tr" => 2, "th" => 1,
          "tbody" => 1, "td" => 1, "pre" => 1}

  module Probes
    @[Punch::Public]
    @[Punch::RateLimitExempt("a spec fixture")]
    struct Save < Punch::Command
      struct Input
        include Punch::Input

        getter name : String
        getter choice : String?
      end

      def call(input : Input, db : Punch::Writer) : Nil
      end
    end

    @[Punch::Public]
    struct SavePage < Punch::Page
      struct Input
        include Punch::Input
      end

      # Holds the form only; rendering the probe here would make its
      # route depend on itself while the route table is derived.
      def call(input : Input, db : Punch::Reader) : Probe
        Probe.new("")
      end
    end
  end

  # Text from users in every place an action block writes it: a label, a
  # hint, a value, a choice, a button, and a form's name.
  struct ActionProbe
    include Punch::Component

    def initialize(@text : String)
    end

    def view(v : Punch::View) : Nil
      v.form(Probes::Save.action, values: {name: @text}) do |form|
        form.field :name, label: @text, hint: @text
        form.field :choice, as: :select, options: [{"a", @text}]
        form.submit @text
      end
      v.form(Probes::Save.action, aria: {label: @text}) do |form|
        form.submit "Go"
      end
    end
  end

  HOSTILE = [
    "[click](http://evil.example)",
    "![img](http://evil.example/x.png)",
    "[ref]: http://evil.example",
    "[ref][1]\n\n[1]: http://evil.example",
    "**bold** __bold__ _em_ *em* `code` ~~strike~~",
    "<script>alert(1)</script>",
    "<img src=x onerror=alert(1)>",
    "<!-- comment -->",
    "<http://evil.example>",
    "&lt;b&gt; &amp; &#x41;",
    "# not a heading",
    "## not a heading either",
    "- not a list",
    "+ not a list",
    "* not a list",
    "1. not a list",
    "2) not a list",
    "123456789. not a list",
    "> not a quote",
    "    not a code block",
    "\t\tnot a code block",
    "```\nnot a fence",
    "~~~ not a fence",
    "line one\n\n# injected heading\n- injected item",
    "line\r\n===",
    "a | b | c",
    "|---|---|",
    "back\\slash \\[x\\]",
    "trailing backslash\\",
    "=== not a setext underline",
    "--- not a rule",
    "`` ` ``",
    "Ärger über Öl, Straße",
    "see http://evil.example and www.evil.example",
    "mail ada@example.org",
  ]

  def self.cmark(markdown : String) : String
    output = IO::Memory.new
    Process.run("cmark-gfm", ["--unsafe", "-e", "table", "-e", "strikethrough", "-e", "autolink"],
      input: IO::Memory.new(markdown), output: output)
    output.to_s
  end

  def self.text_of(html : String) : String
    HTML.unescape(html.gsub(/<[^>]+>/, " ")).gsub(/\s+/, " ")
  end
end

describe Punch::View::MarkdownBackend do
  it "writes headings, paragraphs, emphasis, and links" do
    MarkdownSpec.markdown do |v|
      v.h1 "Invoice A-42"
      v.p do
        v.text "Customer: "
        v.a "Ada Lovelace", href: Punch::Href.new("/billing/customers/7", nil)
        v.text ". Status: "
        v.strong "draft"
        v.text ", "
        v.em "late"
        v.text ", "
        v.s "void"
        v.text ", "
        v.code "A-42"
      end
      v.h3 "Lines"
    end.should eq(<<-MD)
      # Invoice A-42

      Customer: [Ada Lovelace](/billing/customers/7). Status: **draft**, *late*, ~~void~~, `A-42`

      ### Lines

      MD
  end

  it "leaves out chrome, forms, and the document's head" do
    markdown = MarkdownSpec.markdown do |v|
      v.document("Invoices") do
        v.chrome { |chrome| chrome.nav { chrome.raw Punch::SafeHTML.trusted("<svg></svg>") } }
        v.main do
          v.h1 "Invoices"
          v.frame(MarkdownSpec::InvoiceID.parse(42).as(MarkdownSpec::InvoiceID)) { v.p "Framed" }
        end
      end
    end
    markdown.should eq("# Invoices\n\nFramed\n")
  end

  it "writes lists, nested lists, and definition lists" do
    MarkdownSpec.markdown do |v|
      v.ul do
        v.li "one"
        v.li do
          v.text "two"
          v.ol { v.li "a"; v.li "b" }
        end
      end
      v.dl do
        v.dt "Status"
        v.dd "paid"
        v.dt "Notes"
        v.dd { v.p "first"; v.p "second" }
      end
    end.should eq(<<-MD)
      - one
      - two

        1. a
        2. b

      * Status: paid
      * Notes

        first

        second

      MD
  end

  it "keeps a pipe in a link's address from ending a table cell" do
    Punch::View::MarkdownBackend.destination("https://x.example/a|b").should eq("https://x.example/a%7Cb")
  end

  it "writes tables, padding ragged rows" do
    MarkdownSpec.markdown do |v|
      v.table do
        v.caption "Lines"
        v.thead { v.tr { v.th "Description"; v.th "Amount" } }
        v.tbody do
          v.tr { v.td "Consulting"; v.td "EUR 300.00" }
          v.tr { v.td "Travel" }
        end
      end
    end.should eq(<<-MD)
      Lines

      | Description | Amount |
      |---|---|
      | Consulting | EUR 300.00 |
      | Travel | |

      MD
  end

  it "takes a table's first row as its header without a head" do
    MarkdownSpec.markdown do |v|
      v.table { v.tbody { v.tr { v.td "a"; v.td "b" }; v.tr { v.td "c"; v.td "d" } } }
    end.should eq("| a | b |\n|---|---|\n| c | d |\n")
  end

  it "writes quotes, code blocks, rules, line breaks, and images as their alt text" do
    MarkdownSpec.markdown do |v|
      v.blockquote { v.p "quoted" }
      v.pre "a ```\n  b"
      v.hr
      v.p do
        v.text "one"
        v.br
        v.img(src: Punch::Href.new("/logo.svg", nil), alt: "Logo")
        v.br
      end
    end.should eq("> quoted\n\n````\na ```\n  b\n````\n\n---\n\none\\\nLogo\n")
  end

  it "uses a link's address as its text when it has none" do
    MarkdownSpec.markdown { |v| v.p { v.a(href: Punch::Href.new("/search?q=a b (c)", nil)) { } } }
      .should eq("[/search?q=a b (c)](/search?q=a%20b%20%28c%29)\n")
  end

  it "keeps two lists in a row apart" do
    MarkdownSpec.markdown do |v|
      v.ul { v.li "a" }
      v.ul { v.li "b" }
      v.ol { v.li "c" }
      v.ol { v.li "d" }
      v.dl { v.dt "e"; v.dd "f" }
    end.should eq("- a\n\n* b\n\n1. c\n\n1) d\n\n- e: f\n")
  end

  it "escapes text" do
    Punch::View::MarkdownBackend.escape("1. *x* [y](z) <b>").should eq("1\\. \\*x\\* \\[y\\](z) \\<b\\>")
  end

  if Process.find_executable("cmark-gfm")
    describe "against an independent GFM renderer (cmark-gfm)" do
      MarkdownSpec::HOSTILE.each do |text|
        it "keeps #{text.inspect} as text" do
          html = MarkdownSpec.cmark(Punch::Spec.markdown(MarkdownSpec::Probe.new(text)))
          # A bare URL in user text may become a visible link, whose text
          # is its address. Any other link hides where it goes.
          autolinks = html.scan(%r{<a href="([^"]+)">([^<]+)</a>}).reject { |match| match[1] == MarkdownSpec::LINK.url }
          autolinks.each do |match|
            address = URI.decode(match[1]).sub(/\Amailto:/, "").sub(/\Ahttp:\/\/(?=www\.)/, "")
            address.should eq(HTML.unescape(match[2]))
          end
          tags = html.scan(/<(\w+)/).map(&.[1]).tally
          tags["a"] -= autolinks.size if tags["a"]?
          tags.should eq(MarkdownSpec::TAGS)
          html.should contain(%(<a href="#{MarkdownSpec::LINK.url}">))
          flat = text.gsub(/\s+/, " ").strip
          MarkdownSpec.text_of(html).should contain(flat)
        end
      end
    end

    describe "action blocks against cmark-gfm" do
      plain = MarkdownSpec.cmark(Punch::Spec.markdown(MarkdownSpec::ActionProbe.new("plain")))
      MarkdownSpec::HOSTILE.each do |text|
        it "keeps #{text.inspect} as text" do
          markdown = Punch::Spec.markdown(MarkdownSpec::ActionProbe.new(text))
          html = MarkdownSpec.cmark(markdown)
          autolinks = html.scan(%r{<a href="([^"]+)">([^<]+)</a>})
          autolinks.each do |match|
            address = URI.decode(match[1]).sub(/\Amailto:/, "").sub(/\Ahttp:\/\/(?=www\.)/, "")
            address.should eq(HTML.unescape(match[2]))
          end
          tags = html.scan(/<(\w+)/).map(&.[1]).tally
          tags["a"] -= autolinks.size if tags["a"]?
          tags.delete("a") if tags["a"]? == 0
          tags.should eq(plain.scan(/<(\w+)/).map(&.[1]).tally)
          flat = text.gsub(/\s+/, " ").strip
          # Label, hint, value, choice, and title, an autolink's tags taken
          # out without a space. GFM's autolinks keep the backslash of an
          # escaped `>` after an address in their text.
          HTML.unescape(html.gsub(/<[^>]+>/, "")).gsub(/\s+/, " ").delete('\\').scan(flat.delete('\\')).size.should be >= 5
          Punch::Spec.actions(markdown).map(&.title).should eq([flat, flat])
        end
      end
    end
  else
    pending "against an independent GFM renderer: install cmark-gfm"
  end
end
