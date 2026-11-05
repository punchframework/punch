require "../spec_helper"
require "../../src/punch/cli"

module InboundSpec
  SECRET = "whsec_#{Base64.strict_encode("inbound-spec-current-secret-0123")}"
  OLD    = "whsec_#{Base64.strict_encode("inbound-spec-previous-secret-012")}"

  SQL = Punch::Job::Outbox.sql + Punch::Webhook::Invocations.sql + <<-SQL
    CREATE TABLE payments (id INTEGER PRIMARY KEY, ref TEXT NOT NULL UNIQUE, amount INTEGER NOT NULL) STRICT;

    SQL

  class_property secrets : Array(String)? = [SECRET, OLD]
  @@failures = Atomic(Int32).new(0)

  def self.failures : Int32
    @@failures.get
  end

  def self.failed! : Nil
    @@failures.add(1)
  end

  struct PaymentRecorded
    include Punch::Event

    getter ref : String

    def initialize(@ref)
    end
  end

  struct Paid
    include Punch::Input

    getter ref : String
    getter amount : Int64
  end

  struct Envelope
    include Punch::Input

    getter kind : String
  end

  # Written into each provider (a provider's own methods): `paid` is an event, `refund` is ignored,
  # anything else unprocessable.
  macro handlers
    def parse(request : Punch::RawRequest) : Paid | Punch::Webhook::Ignored | Punch::Webhook::Unprocessable
      case envelope = Envelope.from_json(request.body)
      in Punch::Rejection then Punch::Webhook::Unprocessable.new("no kind")
      in Envelope
        return Punch::Webhook::Ignored.new(envelope.kind) unless envelope.kind == "paid"

        case paid = Paid.from_json(request.body)
        in Punch::Rejection then Punch::Webhook::Unprocessable.new("paid without ref and amount")
        in Paid             then paid
        end
      end
    end

    # Writes first, then decides: a negative amount fails, zero is not
    # there yet, a test payment is nothing to do, `boom` is a bug.
    def process(event : Paid, db : Punch::Writer, events : Punch::Events(PaymentRecorded)) : Punch::Webhook::Outcome
      db.exec("INSERT INTO payments (ref, amount) VALUES (?, ?)", event.ref, event.amount)
      raise "boom" if event.ref == "boom"
      return Punch::Webhook::Failed.new("negative amount") if event.amount < 0
      return retry("amount not settled yet") if event.amount == 0
      return discard("a test payment") if event.ref.starts_with?("test")

      events.publish(PaymentRecorded.new(event.ref))
      Punch::Webhook::Processed.new
    end

    def on_failure(invocation : Punch::Webhook::Invocation::Failed | Punch::Webhook::Invocation::Unprocessable, db : Punch::Writer) : Nil
      InboundSpec.failed!
    end
  end

  @[Punch::Webhook::Provider("payments")]
  struct Payments < Punch::Webhook::Inbound
    InboundSpec.handlers

    def verifier : Punch::Webhook::Verifier?
      InboundSpec.secrets.try { |secrets| Punch::Webhook::HMAC.new(secrets) }
    end
  end

  @[Punch::Webhook::Provider("slow", verify: :deferred)]
  struct Slow < Punch::Webhook::Inbound
    InboundSpec.handlers

    def verifier : Punch::Webhook::Verifier?
      Punch::Webhook::HMAC.new([SECRET])
    end
  end

  # Signs nothing; small bodies; the key from a field of the payload.
  @[Punch::Webhook::Provider("open", verify: :none, body_limit: 1024, rate_limit: 5)]
  struct Open < Punch::Webhook::Inbound
    InboundSpec.handlers

    def idempotency_key(request : Punch::RawRequest) : String?
      request.header("x-delivery")
    end
  end

  def self.with_spec_db(&)
    path = File.tempname("inbound-spec", ".sql")
    File.write(path, SQL)
    previous = Punch::Spec.schema
    Punch::Spec.schema = path
    InboundSpec.secrets = [SECRET, OLD]
    begin
      yield
    ensure
      Punch::Spec.schema = previous
      File.delete(path)
    end
  end

  def self.client : Punch::Spec::Client
    Punch::Spec::Client.new(Punch::Routing::Router.new(Punch::Spec.db), openapi: nil)
  end

  def self.payments : Array(String)
    Punch::Spec.db.read(&.query_all("SELECT ref FROM payments ORDER BY id", &.read(String)))
  end

  def self.deliver(body : String, *, path = Payments::Receive.path, secret = SECRET, id = "msg_#{Random::Secure.hex(6)}", at = Time.utc) : Punch::Spec::Response
    client.deliver_webhook(path, body, secret: secret, id: id, at: at)
  end
end

private def paid(ref : String, amount = 100) : String
  {kind: "paid", ref: ref, amount: amount}.to_json
end

describe "inbound webhooks" do
  it "stores a verified delivery, answers 204, and processes it once through the outbox" do
    InboundSpec.with_spec_db do
      response = InboundSpec.deliver(paid("a"), id: "msg_1")
      response.status.should eq(HTTP::Status::NO_CONTENT)
      response.trace.root["punch.webhook.outcome"].should eq("received")
      response.trace.root["punch.webhook.provider"].should eq("payments")
      invocation = Punch::Spec.webhooks.first.as(Punch::Webhook::Invocation::Verified)
      {invocation.provider, invocation.key, invocation.request.body}.should eq({"payments", "msg_1", paid("a")})
      invocation.request.header("webhook-signature").should_not be_nil
      Punch::Spec.enqueued(Punch::Webhook::Process).map(&.invocation_id).should eq([invocation.id])

      -> { Punch::Spec.perform_jobs.map(&.outcome).should eq([Punch::Job::Queue::Outcome::Done]) }
        .should publish(InboundSpec::PaymentRecorded, ref: "a", times: 1)
      InboundSpec.payments.should eq(["a"])
      done = Punch::Spec.webhooks.first.as(Punch::Webhook::Invocation::Processed)
      done.attempts.should eq(1)

      # The same delivery again: answered, nothing stored or run.
      InboundSpec.deliver(paid("a"), id: "msg_1").trace.root["punch.webhook.outcome"].should eq("duplicate")
      Punch::Spec.perform_jobs.should be_empty
      Punch::Spec.webhooks.size.should eq(1)
      # Another body under the key: 409.
      conflict = InboundSpec.deliver(paid("b"), id: "msg_1")
      conflict.status.should eq(HTTP::Status::CONFLICT)
      conflict.json["code"].should eq("idempotency_key_reused")
      Punch::Spec.webhooks.size.should eq(1)
    end
  end

  it "refuses a bad, old, or missing signature at the edge, and stores nothing" do
    InboundSpec.with_spec_db do
      wrong = "whsec_#{Base64.strict_encode("someone-else-entirely-0123456")}"
      InboundSpec.deliver(paid("a"), secret: wrong).json["code"].should eq("invalid_signature")
      InboundSpec.deliver(paid("a"), at: Time.utc - 10.minutes).status.should eq(HTTP::Status::UNAUTHORIZED)
      InboundSpec.client.post(InboundSpec::Payments::Receive.path, body: paid("a")).status.should eq(HTTP::Status::UNAUTHORIZED)
      Punch::Spec.webhooks.should be_empty
      # The secret before the current one, during a rotation.
      InboundSpec.deliver(paid("a"), secret: InboundSpec::OLD).status.should eq(HTTP::Status::NO_CONTENT)
      # Without secrets the app takes no deliveries.
      InboundSpec.secrets = nil
      InboundSpec.deliver(paid("b")).status.should eq(HTTP::Status::NOT_FOUND)
      Punch::Spec.webhooks.size.should eq(1)
    end
  end

  it "verifies later with verify: :deferred, as of when the delivery arrived" do
    InboundSpec.with_spec_db do
      clock = Punch::Spec.clock
      wrong = "whsec_#{Base64.strict_encode("someone-else-entirely-0123456")}"
      InboundSpec.deliver(paid("good"), path: InboundSpec::Slow::Receive.path).status.should eq(HTTP::Status::NO_CONTENT)
      InboundSpec.deliver(paid("bad"), path: InboundSpec::Slow::Receive.path, secret: wrong).status.should eq(HTTP::Status::NO_CONTENT)
      Punch::Spec.webhooks.map(&.state).should eq(%w[received received])
      # An hour later, far past the tolerance, the signature still holds.
      clock.advance(1.hour)
      outcomes = Punch::Spec.perform_jobs.map(&.outcome)
      outcomes.should contain(Punch::Job::Queue::Outcome::Discarded)
      Punch::Spec.webhooks.map(&.state).should eq(%w[processed rejected])
      InboundSpec.payments.should eq(["good"])
    end
  end

  it "keeps a forged first delivery under verify: :deferred from blocking the genuine one" do
    InboundSpec.with_spec_db do
      wrong = "whsec_#{Base64.strict_encode("someone-else-entirely-0123456")}"
      InboundSpec.deliver(paid("forged"), path: InboundSpec::Slow::Receive.path, secret: wrong, id: "msg_known").status.should eq(HTTP::Status::NO_CONTENT)
      InboundSpec.deliver(paid("real"), path: InboundSpec::Slow::Receive.path, id: "msg_known").status.should eq(HTTP::Status::NO_CONTENT)
      Punch::Spec.perform_jobs
      Punch::Spec.webhooks.map(&.state).sort!.should eq(%w[processed rejected])
      InboundSpec.payments.should eq(["real"])
    end
  end

  it "answers 503 once too many deliveries of a provider wait for verification" do
    InboundSpec.with_spec_db do
      Punch::Spec.db.write do |db|
        Punch::Webhook::MAX_UNVERIFIED.times do |index|
          db.exec("INSERT INTO punch_webhooks (provider, key, fingerprint, state, body, headers, attempts, received_at) VALUES ('slow', ?, x'00', 'received', x'', '{}', 0, 0)", "k#{index}")
        end
      end
      InboundSpec.deliver(paid("one more"), path: InboundSpec::Slow::Receive.path).status.should eq(HTTP::Status::SERVICE_UNAVAILABLE)
      InboundSpec.deliver(paid("signed now"), path: InboundSpec::Payments::Receive.path).status.should eq(HTTP::Status::NO_CONTENT)
    end
  end

  it "refuses a timestamp that is not plain digits, and a short or broken secret" do
    now = Time.utc
    signature = Punch::Webhook::Signature.sign(InboundSpec::SECRET, "msg_1", now, "{}")
    ["-9223372036854775808", "+#{now.to_unix}", " #{now.to_unix}", "99999999999999999999"].each do |timestamp|
      Punch::Webhook::Signature.valid?([InboundSpec::SECRET], "msg_1", timestamp, signature, "{}", now: now).should be_false
    end
    Punch::Webhook::Signature.valid?([InboundSpec::SECRET], "msg_1", String.new(Bytes[0xFF]), signature, "{}", now: now).should be_false
    Punch::Webhook::Signature.valid?([InboundSpec::SECRET], "msg_1", now.to_unix.to_s, signature, "{}", now: now).should be_true
    ["", "whsec_", "short", "whsec_%%%"].each do |secret|
      expect_raises(ArgumentError) { Punch::Webhook::HMAC.new([InboundSpec::SECRET, secret]) }
    end
  end

  it "ends ignored events as ignored and unreadable ones as unprocessable, with the failure event" do
    InboundSpec.with_spec_db do
      before = InboundSpec.failures
      InboundSpec.deliver({kind: "refund"}.to_json)
      InboundSpec.deliver(%({"kind": "paid", "ref": 7}))
      -> { Punch::Spec.perform_jobs }.should publish(Punch::Webhook::ProcessingFailed, state: "unprocessable", provider: "payments", times: 1)
      states = Punch::Spec.webhooks
      states.map(&.state).should eq(%w[ignored unprocessable])
      states.map(&.error).should eq(["refund", "paid without ref and amount"])
      (InboundSpec.failures - before).should eq(1)
    end
  end

  it "discards quietly what process says is nothing to do, rolling its writes back" do
    InboundSpec.with_spec_db do
      before = InboundSpec.failures
      InboundSpec.deliver(paid("test-1", 5))
      -> { Punch::Spec.perform_jobs.map(&.outcome).should eq([Punch::Job::Queue::Outcome::Discarded]) }
        .should_not publish(Punch::Webhook::ProcessingFailed)
      InboundSpec.payments.should be_empty
      discarded = Punch::Spec.webhooks.first
      {discarded.class, discarded.error}.should eq({Punch::Webhook::Invocation::Discarded, "a test payment"})
      InboundSpec.failures.should eq(before)
    end
  end

  it "rolls back a handler that fails and records the failure" do
    InboundSpec.with_spec_db do
      InboundSpec.deliver(paid("minus", -5))
      -> { Punch::Spec.perform_jobs.map(&.outcome).should eq([Punch::Job::Queue::Outcome::Discarded]) }
        .should publish(Punch::Webhook::ProcessingFailed, state: "failed", reason: "negative amount", times: 1)
      InboundSpec.payments.should be_empty
      Punch::Spec.webhooks.first.should be_a(Punch::Webhook::Invocation::Failed)
    end
  end

  it "retries a Retry and an exception with backoff, recording each, and fails the invocation after the last attempt" do
    InboundSpec.with_spec_db do
      clock = Punch::Spec.clock
      InboundSpec.deliver(paid("later", 0))
      InboundSpec.deliver(paid("boom"))
      Punch::Spec.perform_jobs.map(&.outcome).should eq([Punch::Job::Queue::Outcome::Retried, Punch::Job::Queue::Outcome::Retried])
      waiting = Punch::Spec.webhooks
      waiting.map(&.state).should eq(%w[verified verified])
      waiting.map(&.attempts).should eq([1, 1])
      waiting.map(&.error).should eq(["amount not settled yet", "Exception: boom"])
      InboundSpec.payments.should be_empty
      published = Punch::Spec.published(Punch::Webhook::ProcessingFailed) do
        9.times do
          clock.advance(7.hours)
          Punch::Spec.perform_jobs
        end
      end
      published.map(&.as(Punch::Webhook::ProcessingFailed).state).should eq(%w[failed failed])
      Punch::Spec.webhooks.map(&.state).should eq(%w[failed failed])
      Punch::Spec.webhooks.map(&.attempts).should eq([10, 10])
    end
  end

  it "takes any body without a signature where the provider verifies nothing, keyed by its own header or the body" do
    InboundSpec.with_spec_db do
      client = InboundSpec.client
      form = HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"}
      client.post(InboundSpec::Open::Receive.path, body: "kind=paid", headers: form).status.should eq(HTTP::Status::NO_CONTENT)
      client.post(InboundSpec::Open::Receive.path, body: "kind=paid", headers: form).status.should eq(HTTP::Status::NO_CONTENT)
      keyed = HTTP::Headers{"x-delivery" => "d-1", "Content-Type" => "application/json"}
      client.post(InboundSpec::Open::Receive.path, body: paid("o"), headers: keyed).status.should eq(HTTP::Status::NO_CONTENT)
      client.post(InboundSpec::Open::Receive.path, body: paid("o"), headers: keyed).status.should eq(HTTP::Status::NO_CONTENT)
      invocations = Punch::Spec.webhooks("open")
      invocations.size.should eq(2)
      invocations.map(&.key).should eq(["sha256:#{Punch::Crypto::Fingerprint.of("kind=paid").hexstring}", "d-1"])
      invocations.first.as(Punch::Webhook::Invocation::Verified).request.header("content-type").should eq("application/x-www-form-urlencoded")
      Punch::Spec.perform_jobs
      Punch::Spec.webhooks("open").map(&.state).should eq(%w[unprocessable processed])

      client.post(InboundSpec::Open::Receive.path, body: "x" * 2000).status.should eq(HTTP::Status::PAYLOAD_TOO_LARGE)
      4.times { client.post(InboundSpec::Open::Receive.path, body: paid("o")) }
      client.post(InboundSpec::Open::Receive.path, body: paid("o")).should be_rate_limited
    end
  end

  it "leaves an invocation alone that a repeated job finds finished" do
    InboundSpec.with_spec_db do
      InboundSpec.deliver(paid("once"))
      Punch::Spec.perform_jobs
      id = Punch::Spec.webhooks.first.id
      Punch::Job::Queue.enqueue(Punch::Webhook::Process.new(id, "payments"))
      Punch::Job::Queue.enqueue(Punch::Webhook::Process.new(id + 100, "payments"))
      Punch::Job::Queue.enqueue(Punch::Webhook::Process.new(id, "gone"))
      Punch::Spec.perform_jobs.map(&.error).should eq([nil, "webhook invocation #{id + 100} is gone", %(no webhook provider "gone" in this binary)])
      InboundSpec.payments.should eq(["once"])
    end
  end

  it "purges processed, ignored, and rejected invocations past the retention, keeping failed ones" do
    InboundSpec.with_spec_db do
      clock = Punch::Spec.clock
      InboundSpec.deliver(paid("kept"))
      InboundSpec.deliver({kind: "refund"}.to_json)
      InboundSpec.deliver(paid("minus", -1))
      Punch::Spec.perform_jobs
      clock.advance(31.days)
      removed = Punch::Spec.db.write { |db| Punch::Webhook::Invocations.purge(db, clock.now - Punch::Webhook.retention) }
      removed.should eq(2)
      Punch::Spec.webhooks.map(&.state).should eq(%w[failed])
    end
  end

  it "lists providers as publishers, and the failure event as Punch's" do
    graph = Punch::Subscribers.graph
    graph.find! { |node| node.event == "InboundSpec::PaymentRecorded" }.publishers
      .should eq(["InboundSpec::Open#process", "InboundSpec::Payments#process", "InboundSpec::Slow#process"])
    graph.find! { |node| node.event == "Punch::Webhook::ProcessingFailed" }.publishers.should eq(["Punch::Webhook::Process"])
    Punch::Webhook.providers.select(&.[1].starts_with?("InboundSpec::")).should eq([{"open", "InboundSpec::Open", "none"}, {"payments", "InboundSpec::Payments", "edge"}, {"slow", "InboundSpec::Slow", "deferred"}])
    Punch::Routing.routes.find! { |route| route.operation == "InboundSpec::Payments::Receive" }.template.should eq("/webhooks/payments")
  end

  it "lists the providers with how they verify and their invocations per state (punch webhooks)" do
    directory = File.tempname("inbound-cli")
    Dir.mkdir(directory)
    previous = ENV["PUNCH_STORAGE"]?
    ENV["PUNCH_STORAGE"] = directory
    begin
      run = ->(args : Array(String)) do
        stdout = IO::Memory.new
        code = Punch::CLI.run(args, stdout: stdout, stderr: IO::Memory.new, commands: [Punch::CLI::Commands::Webhooks] of Punch::CLI::Command.class)
        {code, stdout.to_s}
      end
      code, text = run.call(["webhooks"])
      code.should eq(0)
      text.should contain("open  POST /webhooks/open  InboundSpec::Open  verify: none  (does not verify: anyone can post to it)")
      text.should contain("(no #{directory}/primary.db: counts need the database)")

      database = Punch::Database.open(File.join(directory, "primary.db"))
      Punch::Migrations::Schema.load(database, InboundSpec::SQL, "inbound")
      database.write do |db|
        request = Punch::RawRequest.new("{}", HTTP::Headers.new)
        Punch::Webhook::Invocations.receive(db, "payments", "k1", Punch::Crypto::Fingerprint.of("{}"), request, [] of String, Time.utc, true)
        Punch::Webhook::Invocations.receive(db, "payments", "k2", Punch::Crypto::Fingerprint.of("{}"), request, [] of String, Time.utc, false)
      end
      database.close
      code, json = run.call(["webhooks", "--json"])
      code.should eq(0)
      payments = JSON.parse(json)["providers"].as_a.find! { |provider| provider["name"] == "payments" }
      payments.should eq(JSON.parse({name: "payments", path: "/webhooks/payments", type: "InboundSpec::Payments", verify: "edge",
                                     counts: {received: 1, verified: 1}}.to_json))
    ensure
      previous ? (ENV["PUNCH_STORAGE"] = previous) : ENV.delete("PUNCH_STORAGE")
      FileUtils.rm_rf(directory)
    end
  end
end
