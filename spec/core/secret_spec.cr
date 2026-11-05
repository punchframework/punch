require "../spec_helper"
require "log"
require "log/spec"

describe Punch::Secret do
  it "redacts itself in to_s, inspect, and interpolation" do
    secret = Punch::Secret.new("sk_live_123")
    secret.to_s.should eq("[REDACTED]")
    "key=#{secret}".should eq("key=[REDACTED]")
    secret.inspect.should_not contain("sk_live")
    {key: secret}.inspect.should_not contain("sk_live")
    [secret].to_s.should_not contain("sk_live")
  end

  it "stays redacted in log messages" do
    secret = Punch::Secret.new("sk_live_123")
    Log.capture do |logs|
      Log.info { "using #{secret}" }
      logs.check(:info, "using [REDACTED]")
    end
  end

  it "gives the value only through unwrap" do
    Punch::Secret.new("sk_live_123").unwrap.should eq("sk_live_123")
  end

  it "keeps derived values secret" do
    derived = Punch::Secret.new("abc").map(&.upcase)
    typeof(derived).should eq(Punch::Secret(String))
    derived.unwrap.should eq("ABC")
    derived.to_s.should eq("[REDACTED]")
  end

  it "compares strings and bytes by content" do
    (Punch::Secret.new("abc") == Punch::Secret.new("abc")).should be_true
    (Punch::Secret.new("abc") == Punch::Secret.new("abd")).should be_false
    (Punch::Secret.new("abc") == Punch::Secret.new("abcd")).should be_false
    (Punch::Secret.new(Bytes[1, 2]) == Punch::Secret.new(Bytes[1, 2])).should be_true
    (Punch::Secret.new(5) == Punch::Secret.new(5)).should be_true
  end

  it "wraps any domain primitive" do
    email = Punch::Email.parse("ann@example.org").as(Punch::Email)
    Punch::Secret.new(email).to_s.should eq("[REDACTED]")
  end
end
