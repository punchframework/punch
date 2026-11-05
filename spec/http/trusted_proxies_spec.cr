require "../spec_helper"

private def proxies(*entries : String)
  Punch::HTTP::TrustedProxies.parse(entries.to_a)
end

describe Punch::HTTP::TrustedProxies do
  it "matches IPv4 and IPv6 ranges and single addresses" do
    trusted = proxies("10.0.0.0/8", "192.168.1.7", "fd00::/8", "::1")
    trusted.includes?("10.200.3.4").should be_true
    trusted.includes?("11.0.0.1").should be_false
    trusted.includes?("192.168.1.7").should be_true
    trusted.includes?("192.168.1.8").should be_false
    trusted.includes?("fd12:3456::1").should be_true
    trusted.includes?("fe80::1").should be_false
    trusted.includes?("::1").should be_true
    trusted.includes?("not an address").should be_false
  end

  it "matches prefixes that do not end on a byte boundary" do
    trusted = proxies("172.16.0.0/12")
    trusted.includes?("172.31.255.255").should be_true
    trusted.includes?("172.32.0.0").should be_false
    trusted.includes?("172.15.255.255").should be_false
  end

  it "treats IPv4-mapped IPv6 addresses as IPv4" do
    proxies("10.0.0.0/8").includes?("::ffff:10.1.2.3").should be_true
    Punch::HTTP::TrustedProxies.canonical("::FFFF:10.1.2.3").should eq("10.1.2.3")
    Punch::HTTP::TrustedProxies.canonical("2001:DB8:0:0::1").should eq("2001:db8::1")
  end

  it "trusts nobody by default" do
    Punch::HTTP::TrustedProxies.none.includes?("127.0.0.1").should be_false
  end

  it "refuses malformed entries and ranges that trust everyone at boot" do
    ["10.0.0.0/33", "fd00::/129", "10.0.0/8", "proxy.internal", "10.0.0.0/x", "0.0.0.0/0", "::/0", "0.0.0.0/1", "128.0.0.0/1", "::/1", "10.0.0.0/7", "fc00::/7"].each do |entry|
      expect_raises(Punch::HTTP::TrustedProxies::Error) { proxies(entry) }
    end
  end
end
