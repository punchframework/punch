require "../spec_helper"

module ViewSpec
  # Renders the block's elements as a fragment.
  struct Block
    include Punch::Component

    def initialize(&@block : Punch::View ->)
    end

    def view(v : Punch::View) : Nil
      @block.call(v)
    end
  end

  struct RawBlock
    include Punch::Component

    def initialize(&@block : Punch::HTMLView ->)
    end

    def view(v : Punch::HTMLView) : Nil
      @block.call(v)
    end
  end

  struct Layout
    include Punch::Component

    def initialize(@title : String)
    end

    def view(v : Punch::View, &) : Nil
      v.document(@title, lang: "de") do
        v.chrome { |chrome| chrome.nav { chrome.raw Punch::SafeHTML.trusted(%(<svg aria-hidden="true"></svg>)) } }
        v.main { yield }
      end
    end
  end

  struct Page
    include Punch::Component

    def initialize(@name : String)
    end

    def view(v : Punch::View) : Nil
      v.render(Layout.new("Hello #{@name}")) do
        v.h1 @name
        v.render Block.new(&.p("inside"))
      end
    end
  end

  def self.html(&block : Punch::View ->) : String
    Punch::Spec.render(Block.new(&block))
  end

  HOSTILE = [
    %(<script>alert(1)</script>),
    %("><img src=x onerror=alert(1)>),
    %(' onmouseover='alert(1)),
    %(&lt;already escaped&gt;),
    %(</p><p>),
  ]
end

describe Punch::View do
  it "writes elements with their text, escaped" do
    ViewSpec.html(&.p("a < b & c")).should eq("<p>a &lt; b &amp; c</p>\n")
    ViewSpec.html { |v| v.p { v.text "x "; v.strong "y" } }.should eq("<p>x <strong>y</strong></p>\n")
  end

  it "keeps hostile text text, in content and in attributes" do
    ViewSpec::HOSTILE.each do |hostile|
      html = ViewSpec.html do |v|
        v.section(id: hostile, class: hostile, data: {value: hostile}, title: hostile) do
          v.h2 hostile
          v.p { v.text hostile; v.a hostile, href: Punch::Href.external("https://example.org/") }
        end
      end
      document = Punch::Spec.html(html)
      document.find("*").map(&.name).should eq(%w[html body section h2 p a])
      document.find("section").first["title"].should eq(hostile)
      document.find("section").first["data-value"].should eq(hostile)
      document.text("h2").should eq(hostile.gsub(/\s+/, ' ').strip)
      html.should_not contain("<script")
      html.should_not contain("<img")
    end
  end

  it "writes attributes by their names, hyphenated" do
    html = ViewSpec.html do |v|
      v.div(id: "x", class: ["a", nil, "", "b"], data: {turbo_frame: "lines", turbo: false, count: 3},
        aria: {label: "Close", hidden: true}, hidden: true, tabindex: -1) { }
    end
    html.should eq(%(<div id="x" class="a b" data-turbo-frame="lines" data-turbo="false" data-count="3" aria-label="Close" aria-hidden="true" hidden tabindex="-1"></div>\n))
  end

  it "leaves out false and nil attributes, and an empty class list" do
    ViewSpec.html { |v| v.p("x", hidden: false, title: nil, class: [nil]) }.should eq("<p>x</p>\n")
  end

  it "writes times as RFC 3339" do
    ViewSpec.html { |v| v.p { v.time "today", datetime: Time.utc(2026, 10, 9, 8, 30) } }
      .should eq(%(<p><time datetime="2026-10-09T08:30:00Z">today</time></p>\n))
  end

  it "writes void elements without content" do
    ViewSpec.html { |v| v.p { v.text "a"; v.br; v.text "b" }; v.hr(class: "rule") }
      .should eq(%(<p>a<br>b</p>\n<hr class="rule">\n))
  end

  it "writes lists and tables" do
    html = ViewSpec.html do |v|
      v.ul { v.li "one"; v.li { v.strong "two" } }
      v.dl { v.dt "Term"; v.dd "Definition" }
      v.table do
        v.caption "Lines"
        v.thead { v.tr { v.th "A", scope: "col" } }
        v.tbody { v.tr { v.td { v.ul { v.li "nested" } } } }
      end
    end
    document = Punch::Spec.html(html)
    document.find("ul > li").size.should eq(3)
    document.text("th[scope=col]").should eq("A")
    document.text("td li").should eq("nested")
    document.text("dl dd").should eq("Definition")
  end

  it "renders a layout around content, with chrome and raw HTML inside it" do
    html = Punch::Spec.render(ViewSpec::Page.new("Ada"))
    html.should start_with("<!doctype html>\n<html lang=\"de\">\n<head>\n<meta charset=\"utf-8\">\n")
    html.should contain("<title>Hello Ada</title>")
    html.should have_element("body > nav > svg[aria-hidden=true]")
    html.should have_element("body > main > h1", text: "Ada")
    html.should have_element("main > p", text: "inside")
    html.should end_with("</main>\n</body>\n</html>\n")
  end

  it "writes raw HTML only where text may go" do
    Punch::Spec.render(ViewSpec::RawBlock.new { |v| v.p { v.raw Punch::SafeHTML.trusted("<b>x</b>") } })
      .should eq("<p><b>x</b></p>\n")
    expect_raises(Punch::View::NestingError, "<ul> cannot hold raw HTML, only <li> (in ul)") do
      Punch::Spec.render(ViewSpec::RawBlock.new { |v| v.ul { v.raw Punch::SafeHTML.trusted("<li>x</li>") } })
    end
  end

  describe "nesting" do
    {
      "a block in a paragraph"     => {->(v : Punch::View) { v.p { v.div { } } }, "<p> can hold only text and phrasing elements such as <strong> or <a>, not <div> (in p)"},
      "a list item outside a list" => {->(v : Punch::View) { v.div { v.li "x" } }, "<li> belongs directly inside <ul> or <ol>, not <div> (in div)"},
      "a paragraph in a list"      => {->(v : Punch::View) { v.ul { v.p "x" } }, "<ul> can hold only <li>, not <p> (in ul)"},
      "text in a list"             => {->(v : Punch::View) { v.ol { v.text "x" } }, "<ol> cannot hold text, only <li> (in ol)"},
      "a row without a section"    => {->(v : Punch::View) { v.table { v.tr { } } }, "<tr> belongs directly inside <thead> or <tbody> or <tfoot>, not <table> (in table)"},
      "a cell outside a row"       => {->(v : Punch::View) { v.table { v.tbody { v.td "x" } } }, "<td> belongs directly inside <tr>, not <tbody> (in table > tbody)"},
      "a link in a link"           => {->(v : Punch::View) { v.p { v.a(href: Punch::Href.external("https://a.example")) { v.a "b", href: Punch::Href.external("https://b.example") } } }, "<a> cannot hold another <a> (in p > a)"},
      "a heading in a heading"     => {->(v : Punch::View) { v.h1 { v.h2 "x" } }, "<h1> can hold only text and phrasing elements such as <strong> or <a>, not <h2> (in h1)"},
      "a document inside a block"  => {->(v : Punch::View) { v.div { v.document("x") { } } }, "document must be the outermost element of a view, and only one (in div)"},
      "a second document"          => {->(v : Punch::View) { v.document("x") { }; v.document("y") { } }, "document must be the outermost element of a view, and only one (at the top)"},
      "a summary outside details"  => {->(v : Punch::View) { v.summary "x" }, "<summary> belongs directly inside <details>, not <fragment> (at the top)"},
    }.each do |name, (block, message)|
      it "rejects #{name}" do
        expect_raises(Punch::View::NestingError, message) { ViewSpec.html(&block) }
      end
    end

    it "allows what HTML and markdown both allow" do
      ViewSpec.html do |v|
        v.details { v.summary "More"; v.p "Text" }
        v.blockquote { v.p "Quote" }
        v.h2 { v.a(href: Punch::Href.external("https://example.org")) { v.em "x" } }
        v.p { v.code "a"; v.kbd "b"; v.small "c"; v.abbr "d", title: "e" }
      end.should have_element("details > summary", text: "More")
    end
  end
end

describe Punch::HTTP::Response do
  it "sends a rendered view as HTML" do
    response = Punch::HTTP::Response.html(:ok, Punch::HTMLView.render(ViewSpec::Block.new(&.p("x"))))
    response.headers["Content-Type"].should eq("text/html; charset=utf-8")
    response.body.should eq("<p>x</p>\n")
  end
end
