require "../spec_helper"

module MatchersSpec
  struct Noted
    include Punch::Event

    getter note_id : Int64
    getter body : String

    def initialize(@note_id, @body)
    end
  end

  struct Rejected
    include JSON::Serializable

    def initialize
    end
  end

  @[Punch::Public]
  @[Punch::RateLimitExempt("a spec fixture")]
  struct Note < Punch::Command
    struct Input
      include Punch::Input

      getter body : String
    end

    @[Punch::Status(200)]
    struct Noted
      include JSON::Serializable

      def initialize
      end
    end

    @[Punch::Status(422)]
    struct Empty
      include JSON::Serializable

      def initialize
      end
    end

    def call(input : Input, db : Punch::Writer, events : Punch::Events(MatchersSpec::Noted)) : Noted | Empty
      events.publish(MatchersSpec::Noted.new(input.body.size.to_i64, input.body))
      return Empty.new if input.body.empty? # rolled back: nothing published

      Noted.new
    end
  end

  struct Remind
    include Punch::Job

    getter note_id : Int64
    getter channel : String = "email"

    def initialize(@note_id, @channel = "email")
    end

    def perform(job : Punch::Job::Context) : Punch::Job::Result
    end
  end

  # Standard Webhooks' own example (standardwebhooks.com, the
  # specification's test vector).
  SECRET    = "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw"
  ID        = "msg_p5jXN8AQM9LWM0D4loKWxJek"
  TIMESTAMP = Time.unix(1614265330)
  PAYLOAD   = %({"test": 2432232314})
  SIGNATURE = "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE="

  # A receiver as a webhook verifier checks: 204 when signed by one of
  # the secrets within five minutes, 401 otherwise.
  def self.receiver(secrets : Array(String)) : Punch::Spec::Client
    Punch::Spec::Client.new(->(context : Punch::HTTP::Context) {
      body = context.read_body.as(String)
      headers = context.request.headers
      valid = Punch::Webhook::Signature.valid?(secrets, headers["webhook-id"]? || "", headers["webhook-timestamp"]? || "",
        headers["webhook-signature"]? || "", body)
      Punch::HTTP::Response.new(valid ? HTTP::Status::NO_CONTENT : HTTP::Status::UNAUTHORIZED)
    })
  end
end

describe "publish" do
  it "matches events a request committed, by type, fields, and count" do
    client = Punch::Spec.client
    -> { client.post(MatchersSpec::Note.path, json: {body: "hello"}) }.should publish(MatchersSpec::Noted)
    -> { client.post(MatchersSpec::Note.path, json: {body: "hello"}) }.should publish(MatchersSpec::Noted, body: "hello", note_id: 5_i64)
    -> { client.post(MatchersSpec::Note.path, json: {body: "hello"}) }.should_not publish(MatchersSpec::Noted, body: "other")
    -> { 2.times { client.post(MatchersSpec::Note.path, json: {body: "hi"}) } }.should publish(MatchersSpec::Noted, times: 2)
    # A Command that fails rolls back, and its events are never delivered.
    -> { client.post(MatchersSpec::Note.path, json: {body: ""}) }.should_not publish(MatchersSpec::Noted)
  end

  it "says what was published instead" do
    client = Punch::Spec.client
    expectation = publish(MatchersSpec::Noted, body: "bye", times: 1)
    block = -> { client.post(MatchersSpec::Note.path, json: {body: "hello"}); nil }
    expectation.match(block).should be_false
    message = expectation.failure_message(block)
    message.should contain("1 × MatchersSpec::Noted with body: \"bye\"")
    message.should contain("@body=\"hello\"")
  end
end

describe "enqueue" do
  it "matches new waiting jobs by type, fields, due time, and count" do
    clock = Punch::Spec.clock
    Punch::Spec.queue.enqueue(MatchersSpec::Remind.new(1)) # before the block: not counted
    -> { Punch::Spec.queue.enqueue(MatchersSpec::Remind.new(2)) }.should enqueue(MatchersSpec::Remind, times: 1)
    -> { Punch::Spec.queue.enqueue(MatchersSpec::Remind.new(3, "sms"), in: 1.day) }.should enqueue(MatchersSpec::Remind, note_id: 3_i64, channel: "sms", at: clock.now + 1.day)
    -> { Punch::Spec.queue.enqueue(MatchersSpec::Remind.new(4)) }.should_not enqueue(MatchersSpec::Remind, channel: "sms")
    -> { }.should_not enqueue(MatchersSpec::Remind)
  end

  it "says what was enqueued instead" do
    expectation = enqueue(MatchersSpec::Remind, note_id: 9_i64)
    block = -> { Punch::Spec.queue.enqueue(MatchersSpec::Remind.new(8)); nil }
    expectation.match(block).should be_false
    expectation.failure_message(block).should contain("MatchersSpec::Remind with note_id: 9")
    expectation.failure_message(block).should contain("@note_id=8")
  end
end

describe Punch::Webhook::Signature do
  it "signs as the Standard Webhooks test vector does" do
    Punch::Webhook::Signature.sign(MatchersSpec::SECRET, MatchersSpec::ID, MatchersSpec::TIMESTAMP, MatchersSpec::PAYLOAD).should eq(MatchersSpec::SIGNATURE)
  end

  it "accepts a valid signature within the tolerance, by any current secret, among several signatures" do
    now = MatchersSpec::TIMESTAMP + 4.minutes
    args = {MatchersSpec::ID, MatchersSpec::TIMESTAMP.to_unix.to_s}
    Punch::Webhook::Signature.valid?([MatchersSpec::SECRET], *args, MatchersSpec::SIGNATURE, MatchersSpec::PAYLOAD, now: now).should be_true
    Punch::Webhook::Signature.valid?(["whsec_b2xk", MatchersSpec::SECRET], *args, MatchersSpec::SIGNATURE, MatchersSpec::PAYLOAD, now: now).should be_true
    Punch::Webhook::Signature.valid?([MatchersSpec::SECRET], *args, "v1,bm9wZQ== #{MatchersSpec::SIGNATURE}", MatchersSpec::PAYLOAD, now: now).should be_true
  end

  it "refuses a changed body, ID, or timestamp, another secret, an old or future delivery, and malformed headers" do
    now = MatchersSpec::TIMESTAMP
    id, timestamp, signature, payload = MatchersSpec::ID, MatchersSpec::TIMESTAMP.to_unix.to_s, MatchersSpec::SIGNATURE, MatchersSpec::PAYLOAD
    valid = ->(secrets : Array(String), given_id : String, given_timestamp : String, given : String, body : String, at : Time) {
      Punch::Webhook::Signature.valid?(secrets, given_id, given_timestamp, given, body, now: at)
    }
    valid.call([MatchersSpec::SECRET], id, timestamp, signature, payload + " ", now).should be_false
    valid.call([MatchersSpec::SECRET], id + "x", timestamp, signature, payload, now).should be_false
    valid.call([MatchersSpec::SECRET], id, (MatchersSpec::TIMESTAMP.to_unix + 1).to_s, signature, payload, now + 1.second).should be_false
    valid.call(["whsec_b2xk"], id, timestamp, signature, payload, now).should be_false
    valid.call([MatchersSpec::SECRET], id, timestamp, signature, payload, now + 6.minutes).should be_false
    valid.call([MatchersSpec::SECRET], id, timestamp, signature, payload, now - 6.minutes).should be_false
    valid.call([MatchersSpec::SECRET], id, "soon", signature, payload, now).should be_false
    valid.call([MatchersSpec::SECRET], id, timestamp, signature.sub("v1,", "v2,"), payload, now).should be_false
    valid.call([MatchersSpec::SECRET], id, timestamp, "v1,%%%", payload, now).should be_false
    valid.call([MatchersSpec::SECRET], id, timestamp, "", payload, now).should be_false
  end
end

describe "Punch::Spec::Client#deliver_webhook" do
  it "delivers a body signed as a receiver checks it" do
    client = MatchersSpec.receiver([MatchersSpec::SECRET])
    client.deliver_webhook("/webhooks/payments", %({"type":"invoice.paid"}), secret: MatchersSpec::SECRET).status.should eq(HTTP::Status::NO_CONTENT)
    client.deliver_webhook("/webhooks/payments", %({"type":"invoice.paid"}), secret: "whsec_b2xk").status.should eq(HTTP::Status::UNAUTHORIZED)
    client.deliver_webhook("/webhooks/payments", "{}", secret: MatchersSpec::SECRET, at: Time.utc - 1.hour).status.should eq(HTTP::Status::UNAUTHORIZED)
    tampered = HTTP::Headers{"webhook-id" => "msg_other"}
    client.deliver_webhook("/webhooks/payments", "{}", secret: MatchersSpec::SECRET, headers: tampered).status.should eq(HTTP::Status::UNAUTHORIZED)
  end
end
