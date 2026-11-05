require "../spec_helper"

private def allowed?(method : String, headers : Hash(String, String), trusted = [] of String) : Bool
  request = HTTP::Request.new(method, "/x", HTTP::Headers.new.tap { |all| headers.each { |name, value| all[name] = value } })
  Punch::HTTP::CrossOrigin.allowed?(request, Punch::HTTP::CrossOrigin.normalize(trusted))
end

describe Punch::HTTP::CrossOrigin do
  it "lets safe methods through, whatever their origin" do
    {"GET", "HEAD", "OPTIONS"}.each do |method|
      allowed?(method, {"Sec-Fetch-Site" => "cross-site", "Origin" => "https://evil.example"}).should be_true
    end
  end

  it "decides by Sec-Fetch-Site when a browser sends it" do
    allowed?("POST", {"Sec-Fetch-Site" => "same-origin"}).should be_true
    allowed?("POST", {"Sec-Fetch-Site" => "none"}).should be_true
    allowed?("POST", {"Sec-Fetch-Site" => "cross-site", "Origin" => "https://evil.example", "Host" => "app.example"}).should be_false
    # A sibling subdomain may be hostile.
    allowed?("DELETE", {"Sec-Fetch-Site" => "same-site", "Origin" => "https://blog.app.example"}).should be_false
    # The header wins over an Origin that would match the host.
    allowed?("PATCH", {"Sec-Fetch-Site" => "cross-site", "Origin" => "https://app.example", "Host" => "app.example"}).should be_false
    allowed?("POST", {"Sec-Fetch-Site" => "cross-site", "Origin" => "https://admin.example"}, ["https://admin.example/"]).should be_true
  end

  it "falls back to comparing Origin with Host" do
    allowed?("POST", {"Origin" => "https://app.example", "Host" => "app.example"}).should be_true
    allowed?("POST", {"Origin" => "http://localhost:3000", "Host" => "localhost:3000"}).should be_true
    allowed?("POST", {"Origin" => "https://APP.example", "Host" => "app.example"}).should be_true
    allowed?("POST", {"Origin" => "https://app.example:8443", "Host" => "app.example"}).should be_false
    allowed?("POST", {"Origin" => "https://evil.example", "Host" => "app.example"}).should be_false
    allowed?("POST", {"Origin" => "null", "Host" => "app.example"}).should be_false
    allowed?("POST", {"Origin" => "https://app.example"}).should be_false
    allowed?("POST", {"Origin" => "HTTPS://Admin.Example", "Host" => "app.example"}, ["https://admin.example"]).should be_true
  end

  it "lets requests through that no browser page made, and bearer-token requests" do
    allowed?("POST", {} of String => String).should be_true
    allowed?("POST", {"Authorization" => "Bearer x", "Sec-Fetch-Site" => "cross-site"}).should be_true
    # A browser sends Basic credentials by itself, like a cookie.
    allowed?("POST", {"Authorization" => "Basic eDp5", "Sec-Fetch-Site" => "cross-site"}).should be_false
  end

  it "refuses a request with the session cookie and neither header, as an old browser's cross-site form sends it" do
    allowed?("POST", {"Cookie" => "#{Punch::Auth::COOKIE}=x"}).should be_false
    allowed?("POST", {"Cookie" => "other=x"}).should be_true
    allowed?("POST", {"Cookie" => "#{Punch::Auth::COOKIE}=x", "Sec-Fetch-Site" => "same-origin"}).should be_true
    allowed?("POST", {"Cookie" => "#{Punch::Auth::COOKIE}=x", "Origin" => "https://app.example", "Host" => "app.example"}).should be_true
    allowed?("POST", {"Cookie" => "#{Punch::Auth::COOKIE}=x", "Authorization" => "Bearer x"}).should be_true
  end

  it "accepts only origins as trusted origins" do
    {"admin.example", "https://admin.example/path", "ftp://admin.example", "https://"}.each do |bad|
      expect_raises(ArgumentError, /trusted origin/) { Punch::HTTP::CrossOrigin.normalize([bad]) }
    end
  end
end
