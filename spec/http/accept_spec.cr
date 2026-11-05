require "../spec_helper"

describe Punch::HTTP::Accept do
  offers = ["application/json", "text/html"]

  {
    nil                                                               => "application/json",
    ""                                                                => "application/json",
    "*/*"                                                             => "application/json",
    "application/json"                                                => "application/json",
    "text/html"                                                       => "text/html",
    "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8" => "text/html",
    "text/vnd.turbo-stream.html, text/html, application/xhtml+xml"    => "text/html",
    "application/json, text/html"                                     => "application/json",
    "text/html;q=0.5, application/json;q=0.9"                         => "application/json",
    "text/*, application/json;q=0.5"                                  => "text/html",
    "text/html, */*"                                                  => "text/html",
    "TEXT/HTML"                                                       => "text/html",
    "text/html;q=0, */*"                                              => "application/json",
    "image/png"                                                       => "application/json",
    "text/html;q=2, application/json;q=0.1"                           => "application/json",
    "text/html;q=abc"                                                 => "application/json",
    "garbage, text/html;level=1"                                      => "text/html",
  }.each do |header, expected|
    it "prefers #{expected} for #{header.inspect}" do
      Punch::HTTP::Accept.preferred(header, offers).should eq(expected)
    end
  end

  it "treats a header that is not UTF-8 as absent" do
    bad = "text/html;q=#{String.new(Bytes[0xFF])}"
    Punch::HTTP::Accept.preferred(bad, offers).should eq("application/json")
    Punch::HTTP::Accept.names?(bad, "text/html").should be_false
  end

  it "adds Accept to Vary once, whatever else is listed" do
    response = Punch::HTTP::Response.text(:ok, "")
    response.headers["Vary"] = "Accept-Language"
    Punch::HTTP::Accept.vary(response)
    Punch::HTTP::Accept.vary(response)
    response.headers["Vary"].should eq("Accept-Language,Accept")
  end
end
