require "../spec_helper"

describe Punch::Href do
  it "accepts absolute links to other sites" do
    %w[https://example.org https://example.org/a?b=1#c http://example.org mailto:ada@example.org tel:+4930123].each do |url|
      Punch::Href.external(url).url.should eq(url)
      Punch::Href.external(url).external?.should be_true
    end
  end

  it "refuses anything else" do
    ["javascript:alert(1)", "JavaScript:alert(1)", "data:text/html,<b>x</b>", "/billing/invoices", "//evil.example",
     "example.org", "https://", "https://exa mple.org", "https://example.org/\nx", "vbscript:x", "mailto:", ""].each do |url|
      Punch::Href.external?(url).should be_nil
      expect_raises(ArgumentError, "not an external link") { Punch::Href.external(url) }
    end
  end

  it "refuses invisible characters that change how an address reads" do
    ["https://example.org/\u202Egpj.exe", "https://exa\u200Bmple.org", "https://example.org/\u00ADx"].each do |url|
      Punch::Href.external?(url).should be_nil
    end
  end

  it "never takes a script URL, even from Punch's own code" do
    [" javascript:alert(1)", "DATA:text/html,x"].each do |url|
      expect_raises(ArgumentError, "script URL") { Punch::Href.new(url, nil) }
    end
  end
end
