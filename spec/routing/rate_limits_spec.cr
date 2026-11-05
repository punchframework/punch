require "../spec_helper"
require "../support/auth_schema"

module RateLimitsSpec
  struct Actor
    include Punch::Auth::Actor

    getter principal : Punch::Auth::Principal

    def initialize(@principal)
    end

    def self.load(principal : Punch::Auth::Principal, db : Punch::Reader | Punch::Writer) : self?
      new(principal)
    end
  end

  # Unauthenticated, limited by address and by the address tried.
  @[Punch::RateLimit(3, per: 1.minute, by: :ip)]
  @[Punch::RateLimit(2, per: 1.hour, by: :email, name: "rate_limits_spec.sign_in.email", store: :durable)]
  @[Punch::Public]
  struct SignIn < Punch::Command
    struct Input
      include Punch::Input

      getter email : Punch::Email
    end

    def call(input : Input, db : Punch::Writer) : Nil
    end
  end

  @[Punch::RateLimit(2, per: 1.minute, by: :actor)]
  @[Punch::RateLimit(1, per: 1.minute, by: :token)]
  @[Punch::Public]
  struct Publish < Punch::Command
    struct Input
      include Punch::Input
    end

    def call(input : Input, db : Punch::Writer, actor : Actor) : Nil
    end
  end

  @[Punch::RateLimitExempt("signed by the provider, which retries")]
  @[Punch::Public]
  struct Hook < Punch::Command
    struct Input
      include Punch::Input
    end

    def call(input : Input, db : Punch::Writer) : Nil
    end
  end

  def self.client : Punch::Spec::Client
    Punch::Spec::Client.new(Punch::Routing::Router.new(Punch::Spec.db), openapi: nil)
  end
end

private def sign_in(client : Punch::Spec::Client, email : String = "ada@example.org", headers : HTTP::Headers? = nil) : Punch::Spec::Response
  client.post(RateLimitsSpec::SignIn.path, json: {email: email}, headers: headers)
end

describe Punch::RateLimits::Limiter do
  it "allows the limit at once, then one per period / limit (GCRA)" do
    limiter = Punch::RateLimits::Limiter.new("spec.gcra", 5, per: 1.minute)
    now = Time.utc(2026, 10, 9, 12, 0, 0)
    (0..4).map { limiter.check("k", now).as(Punch::RateLimits::Limiter::Allowed).remaining }.should eq([4, 3, 2, 1, 0])
    limited = limiter.check("k", now).as(Punch::RateLimits::Limiter::Limited)
    limited.retry_after.should eq(12.seconds)
    limiter.check("other", now).should be_a(Punch::RateLimits::Limiter::Allowed)
    limiter.check("k", now + 11.seconds).should be_a(Punch::RateLimits::Limiter::Limited)
    limiter.check("k", now + 12.seconds).as(Punch::RateLimits::Limiter::Allowed).remaining.should eq(0)
    # Fully recovered after the period: the limit again, no burst beyond it.
    allowed = (1..6).map { limiter.check("k", now + 2.minutes).is_a?(Punch::RateLimits::Limiter::Allowed) }
    allowed.should eq([true, true, true, true, true, false])
    {limiter.allowed.get, limiter.limited.get}.should eq({12, 3})
    limiter.policy.should eq(%("spec.gcra";q=5;w=60))
    limiter.to_s.should eq("spec.gcra: 5 per 1m by key")
  end

  it "counts correctly from many fibers on several threads" do
    limiter = Punch::RateLimits::Limiter.new("spec.threads", 1000, per: 1.hour)
    now = Time.utc
    done = Channel(Int32).new
    context = Fiber::ExecutionContext::Parallel.new("rate-limit-spec", 4)
    16.times do
      context.spawn do
        done.send((1..200).count { limiter.check("shared", now).is_a?(Punch::RateLimits::Limiter::Allowed) })
      end
    end
    16.times.sum { done.receive }.should eq(1000)
    limiter.limited.get.should eq(2200)
  end

  it "keeps memory bounded, dropping recovered keys first" do
    limiter = Punch::RateLimits::Limiter.new("spec.bounded", 1, per: 1.minute, max_keys: 32)
    now = Time.utc
    100.times { |index| limiter.check("key#{index}", now) }
    limiter.keys(now).should be <= 32
    limiter.keys(now + 2.minutes).should eq(0)
  end

  it "keeps durable keys in cache.db, shared by every limiter object of that name" do
    limiter = Punch::RateLimits::Limiter.new("spec.durable", 2, per: 1.minute, store: :durable)
    now = Time.utc
    2.times { limiter.check("k", now).should be_a(Punch::RateLimits::Limiter::Allowed) }
    limiter.check("k", now).should be_a(Punch::RateLimits::Limiter::Limited)
    Punch::RateLimits.database.read(&.query_one?("SELECT count(*) FROM punch_rate_limits WHERE limiter = 'spec.durable'", &.read(Int64))).should eq(1)
    limiter.keys(now).should eq(1)
    limiter.reset("k")
    limiter.check("k", now).should be_a(Punch::RateLimits::Limiter::Allowed)
    Punch::RateLimits.database.write { |db| Punch::RateLimits.purge(db, (now + 1.hour).to_unix_ns.to_i64) }.should eq(1)
  end

  it "refuses a second limiter with the same name, and bad names" do
    Punch::RateLimits::Limiter.new("spec.unique", 1, per: 1.second)
    expect_raises(ArgumentError, /two rate limits are named spec.unique/) { Punch::RateLimits::Limiter.new("spec.unique", 1, per: 1.second) }
    expect_raises(ArgumentError, /lowercase/) { Punch::RateLimits::Limiter.new("Spec Unique", 1, per: 1.second) }
  end

  it "keys IPv6 clients by their /64" do
    Punch::RateLimits.ip_key("203.0.113.9").should eq("203.0.113.9")
    Punch::RateLimits.ip_key("2001:db8:0:1:aaaa::1").should eq("2001:db8:0:1::/64")
    Punch::RateLimits.ip_key("2001:DB8::1").should eq("2001:db8:0:0::/64")
    Punch::RateLimits.ip_key("fe80::1%eth0").should eq("fe80:0:0:0::/64")
    Punch::RateLimits.ip_key("::ffff:192.0.2.1").should eq("192.0.2.1")
  end
end

describe "rate-limited operations" do
  it "answer 429 with Retry-After and the limit, and send RateLimit headers" do
    client = RateLimitsSpec.client
    first = sign_in(client)
    first.status.should eq(HTTP::Status::NO_CONTENT)
    first.headers["RateLimit-Policy"].should eq(%("rate_limits_spec.sign_in.ip";q=3;w=60, "rate_limits_spec.sign_in.email";q=2;w=3600))
    first.headers["RateLimit"].should eq(%("rate_limits_spec.sign_in.email";r=1;t=1800))
    sign_in(client, "bob@example.org")
    refused = sign_in(client, "cy@example.org")
    refused.status.should eq(HTTP::Status::NO_CONTENT)
    refused = sign_in(client, "dee@example.org")
    refused.should be_rate_limited("rate_limits_spec.sign_in.ip")
    refused.headers["Retry-After"].should eq("20")
    refused.json["code"].should eq("rate_limited")
    refused.json["retry_after"].should eq(20)
    refused.json["limit"].should eq("rate_limits_spec.sign_in.ip")
    refused.trace.try(&.root.attributes["punch.rate_limit"]?).should eq("rate_limits_spec.sign_in.ip")
  end

  it "limit by an input field, and recover with time" do
    clock = Punch::Spec.clock
    client = RateLimitsSpec.client
    2.times { sign_in(client).status.should eq(HTTP::Status::NO_CONTENT) }
    clock.advance(1.minute) # the address limit recovers, the email limit does not
    sign_in(client).should be_rate_limited("rate_limits_spec.sign_in.email")
    sign_in(client, "ADA@example.org").should be_rate_limited # the same address, normalized
    sign_in(client, "grace@example.org").status.should eq(HTTP::Status::NO_CONTENT)
    clock.advance(30.minutes)
    sign_in(client).status.should eq(HTTP::Status::NO_CONTENT)
  end

  it "answer a browser with a page" do
    client = RateLimitsSpec.client
    3.times { sign_in(client) }
    page = client.post(RateLimitsSpec::SignIn.path, json: {email: "ada@example.org"}, headers: HTTP::Headers{"Accept" => "text/html"})
    page.should be_rate_limited
    page.headers["Content-Type"].should start_with("text/html")
    page.should have_element("code", text: "rate_limited")
  end

  it "limit by the signed-in user and by the API token, inside the transaction" do
    AuthSchema.with_spec_db do
      client = RateLimitsSpec.client.sign_in(1_i64)
      2.times { client.post(RateLimitsSpec::Publish.path).status.should eq(HTTP::Status::NO_CONTENT) }
      client.post(RateLimitsSpec::Publish.path).should be_rate_limited("rate_limits_spec.publish.actor")
      other = RateLimitsSpec.client.sign_in(2_i64)
      other.post(RateLimitsSpec::Publish.path).status.should eq(HTTP::Status::NO_CONTENT)
      # A session has no token: only the actor limit applies to it.
      other.post(RateLimitsSpec::Publish.path).headers["RateLimit-Policy"].should eq(%("rate_limits_spec.publish.actor";q=2;w=60))

      Punch::Spec.reset_rate_limits
      bearer = Punch::Spec.bearer(Punch::Spec.api_token(1_i64))
      RateLimitsSpec.client.post(RateLimitsSpec::Publish.path, headers: bearer).status.should eq(HTTP::Status::NO_CONTENT)
      RateLimitsSpec.client.post(RateLimitsSpec::Publish.path, headers: bearer).should be_rate_limited("rate_limits_spec.publish.token")
    end
  end

  it "are listed with their limits, actor, and exemption in the route table" do
    route = ->(name : String) { Punch::Routing.routes.find!(&.operation.==(name)) }
    route.call("RateLimitsSpec::SignIn").rate_limits.map(&.to_s).should eq([
      "rate_limits_spec.sign_in.ip: 3 per 1m by ip", "rate_limits_spec.sign_in.email: 2 per 1h by email (durable)",
    ])
    route.call("RateLimitsSpec::SignIn").actor.should eq("none")
    route.call("RateLimitsSpec::Publish").actor.should eq("required")
    route.call("RateLimitsSpec::Hook").rate_limit_exempt.should eq("signed by the provider, which retries")
  end

  it "are documented with a 429" do
    registry = Punch::JSONSchema::Registry.new("#/components/schemas/")
    entry = Punch::OpenAPI.operation(RateLimitsSpec::SignIn, Punch::Routing.routes.find!(&.operation.==("RateLimitsSpec::SignIn")), registry)
    response = entry["responses"]["429"]
    response["description"].as_s.should contain("rate_limits_spec.sign_in.ip: 3 per 1m by ip")
    response["headers"]["Retry-After"]["schema"]["type"].should eq("integer")
    Punch::OpenAPI.operation(RateLimitsSpec::Hook, Punch::Routing.routes.find!(&.operation.==("RateLimitsSpec::Hook")), registry)["responses"]["429"]?.should be_nil
  end
end
