require "../spec_helper"

private HTML_SOURCE = <<-HTML
  <main id="top" class="page wide"><h1>Invoices</h1>
  <ul class="list"><li class="row">One</li><li class="row overdue">Two  <b>!</b></li></ul>
  <a href="/billing/invoices?after=2" rel="next">Next</a><p>It's "quoted"</p></main>
  HTML

describe Punch::Spec::Selector do
  {
    "h1"                  => "//h1",
    "*"                   => "//*",
    "main > h1"           => "//main/h1",
    "main li"             => "//main//li",
    "#top"                => "//*[@id='top']",
    "li.row.overdue"      => "//li[contains(concat(' ', normalize-space(@class), ' '), ' row ')][contains(concat(' ', normalize-space(@class), ' '), ' overdue ')]",
    "a[rel]"              => "//a[@rel]",
    "a[rel=next]"         => "//a[@rel='next']",
    "a[href^='/billing']" => "//a[starts-with(@href, '/billing')]",
    %(a[href*="after=2"]) => "//a[contains(@href, 'after=2')]",
    "h1, ul>li"           => "//h1 | //ul/li",
  }.each do |css, xpath|
    it "translates #{css}" do
      Punch::Spec::Selector.xpath(css).should eq(xpath)
    end
  end

  it "refuses what it does not support" do
    ["li:first-child", "a[rel~=x]", "a[rel='x]", ""].each do |css|
      expect_raises(Punch::Spec::Selector::Error) { Punch::Spec::Selector.xpath(css) }
    end
  end
end

describe "have_element" do
  it "matches by selector, text, and count" do
    HTML_SOURCE.should have_element("main > h1", text: "Invoices")
    HTML_SOURCE.should have_element("li.row", count: 2)
    HTML_SOURCE.should have_element("li.overdue", text: "Two !")
    HTML_SOURCE.should have_element("li", text: /\ATwo/)
    HTML_SOURCE.should have_element("a[rel=next][href='/billing/invoices?after=2']")
    HTML_SOURCE.should have_element("p", text: %(It's "quoted"))
    HTML_SOURCE.should_not have_element("table")
    HTML_SOURCE.should_not have_element("h1", text: "Customers")
  end

  it "explains a mismatch with what was found" do
    expectation = have_element("li", text: "Three")
    expectation.match(HTML_SOURCE).should be_false
    expectation.failure_message(HTML_SOURCE).should start_with(%(Expected an element matching li with text "Three"; 2 match li: "One", "Two !"\nin:\n<main))
  end

  it "parses responses and finds text" do
    document = Punch::Spec.html(HTML_SOURCE)
    document.text("h1").should eq("Invoices")
    document.text("table").should be_nil
    document.find("li").map { |node| Punch::Spec::HTML.text(node) }.should eq(["One", "Two !"])
  end
end
