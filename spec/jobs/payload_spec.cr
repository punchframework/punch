require "../spec_helper"

module PayloadSpec
  RAN  = {} of String => Array(String)
  LOCK = Mutex.new

  def self.ran(tag : String) : Array(String)
    LOCK.synchronize { RAN[tag]?.try(&.dup) || [] of String }
  end

  def self.record(tag : String, what : String) : Nil
    LOCK.synchronize { (RAN[tag] ||= [] of String) << what }
  end

  # Version 1 held whole euros, version 2 cents, version 3 adds the
  # currency; `note` was added later without a version, as optional.
  @[Punch::Payloads::Version(3, from: {1 => V1, 2 => V2})]
  struct Charge
    include Punch::Job

    getter tag : String
    getter cents : Int64
    getter currency : String
    getter note : String?

    def initialize(@tag, @cents, @currency, @note = nil)
    end

    def perform(job : Punch::Job::Context) : Punch::Job::Result
      PayloadSpec.record(tag, "#{cents} #{currency}")
      nil
    end

    struct V1
      include Punch::Payloads::Frozen

      getter tag : String
      getter euros : Int32

      def upgrade : V2
        V2.new(tag, euros.to_i64 * 100)
      end
    end

    struct V2
      include Punch::Payloads::Frozen

      getter tag : String
      getter cents : Int64

      def initialize(@tag, @cents)
      end

      def upgrade : Charge
        raise ArgumentError.new("negative amount #{cents}") if cents < 0
        Charge.new(tag, cents, "EUR")
      end
    end
  end

  # Its version 1 frozen type was deleted: version 1 payloads are parked.
  @[Punch::Payloads::Version(3, from: {2 => V2})]
  struct Trimmed
    include Punch::Job

    getter tag : String

    def initialize(@tag)
    end

    def perform(job : Punch::Job::Context) : Punch::Job::Result
      nil
    end

    struct V2
      include Punch::Payloads::Frozen

      getter tag : String

      def upgrade : Trimmed
        Trimmed.new(tag)
      end
    end
  end

  @[Punch::Payloads::Version(2, from: {1 => Paid::V1})]
  struct Paid
    include Punch::Event

    getter tag : String
    getter cents : Int64

    def initialize(@tag, @cents)
    end

    struct V1
      include Punch::Payloads::Frozen

      getter tag : String
      getter euros : Int32

      def upgrade : Paid
        Paid.new(tag, euros.to_i64 * 100)
      end
    end
  end

  @[Punch::Subscriber::Delivery(:deferred)]
  struct Receipt
    include Punch::Subscriber(Paid)

    def call(event : Paid, job : Punch::Job::Context) : Punch::Job::Result
      PayloadSpec.record(event.tag, "receipt #{event.cents}")
      nil
    end
  end

  TYPES = Punch::Job::Queue::Registry.types

  def self.with_queue(& : Punch::Job::Queue, Punch::Database ->) : Nil
    Punch::Spec.database do |primary|
      Punch::Spec.database do |database|
        yield Punch::Job::Queue.new(database), primary
      end
    end
  end

  def self.entry(queue : Punch::Job::Queue, type : String, version : Int32, payload : String) : Int64
    queue.insert(Punch::Job::Queue::Entry.new("default", type, version, payload, 0, Time.utc, 10)) || raise "not inserted"
  end

  def self.run(queue : Punch::Job::Queue, primary : Punch::Database, types = TYPES) : Array(Punch::Job::Queue::Outcome)
    outcomes = [] of Punch::Job::Queue::Outcome
    while job = queue.claim("spec", 1, types).first?
      outcomes << Punch::Job::Queue.perform(job, queue, primary, "spec", Punch::Trace::Tracer.off)
    end
    outcomes
  end

  def self.must(value : T?) : T forall T
    value || fail "expected a value, got nil"
  end
end

describe "payload versions" do
  it "stores the current version and reads every version it has a frozen type for" do
    PayloadSpec::TYPES["PayloadSpec::Charge"].should eq(3)
    Punch::Job::Queue::Registry.reads["PayloadSpec::Charge"].should eq([3, 2, 1])
    Punch::Job::Queue::Registry.reads["PayloadSpec::Trimmed"].should eq([3, 2])
    Punch::Job::Queue::Registry.reads["PayloadSpec::Receipt(PayloadSpec::Paid)"].should eq([2, 1])
    Punch::Job::Queue.entry(PayloadSpec::Charge.new("t", 1, "EUR"), Time.utc).version.should eq(3)
    Punch::Job::Queue.deferred_entry(PayloadSpec::Receipt, PayloadSpec::Paid.new("t", 1), Time.utc).version.should eq(2)

    Punch::Spec.read_payload(PayloadSpec::Charge, 1, %({"tag": "a", "euros": 5})).should eq(PayloadSpec::Charge.new("a", 500, "EUR"))
    Punch::Spec.read_payload(PayloadSpec::Charge, 2, %({"tag": "b", "cents": 7})).should eq(PayloadSpec::Charge.new("b", 7, "EUR"))
    # Additive: a payload written before `note` existed, and one with a
    # field this binary does not know, written by a newer one.
    Punch::Spec.read_payload(PayloadSpec::Charge, 3, %({"tag": "c", "cents": 1, "currency": "CHF"})).note.should be_nil
    Punch::Spec.read_payload(PayloadSpec::Charge, 3, %({"tag": "d", "cents": 1, "currency": "CHF", "vat": 19})).cents.should eq(1)
    expect_raises(Punch::Payloads::UnreadableVersion, "PayloadSpec::Charge version 4 is not readable here: this binary reads 3, 2, 1") do
      Punch::Spec.read_payload(PayloadSpec::Charge, 4, "{}")
    end
  end

  it "runs older payloads upgraded, jobs and deferred deliveries alike" do
    PayloadSpec.with_queue do |queue, primary|
      tag = Random::Secure.hex(6)
      PayloadSpec.entry(queue, "PayloadSpec::Charge", 1, %({"tag": "#{tag}", "euros": 2}))
      PayloadSpec.entry(queue, "PayloadSpec::Charge", 2, %({"tag": "#{tag}", "cents": 250}))
      PayloadSpec.entry(queue, "PayloadSpec::Charge", 3, %({"tag": "#{tag}", "cents": 3, "currency": "CHF"}))
      PayloadSpec.entry(queue, "PayloadSpec::Receipt(PayloadSpec::Paid)", 1, %({"tag": "#{tag}", "euros": 4}))
      PayloadSpec.entry(queue, "PayloadSpec::Receipt(PayloadSpec::Paid)", 2, %({"tag": "#{tag}", "cents": 5}))
      PayloadSpec.run(queue, primary).should eq([Punch::Job::Queue::Outcome::Done] * 5)
      PayloadSpec.ran(tag).sort.should eq(["200 EUR", "250 EUR", "3 CHF", "receipt 400", "receipt 5"])
    end
  end

  it "leaves newer versions waiting for a binary that reads them" do
    PayloadSpec.with_queue do |queue, primary|
      tag = Random::Secure.hex(6)
      newer = PayloadSpec.entry(queue, "PayloadSpec::Charge", 4, %({"tag": "#{tag}", "amount": "1.00 EUR"}))
      # A rollback: this binary reads up to 3.
      queue.claim("spec", 10, PayloadSpec::TYPES).should be_empty
      queue.next_due(PayloadSpec::TYPES).should be_nil
      # An older binary still, reading up to 2, also leaves version 3 alone.
      current = PayloadSpec.entry(queue, "PayloadSpec::Charge", 3, %({"tag": "#{tag}", "cents": 1, "currency": "EUR"}))
      older = PayloadSpec::TYPES.merge({"PayloadSpec::Charge" => 2})
      queue.claim("old", 10, older).should be_empty
      PayloadSpec.run(queue, primary).should eq([Punch::Job::Queue::Outcome::Done])
      PayloadSpec.must(queue.find(current)).state.should eq("done")
      # The newer binary is deployed again.
      claimed = queue.claim("new", 10, PayloadSpec::TYPES.merge({"PayloadSpec::Charge" => 4}))
      claimed.map(&.id).should eq([newer])
      PayloadSpec.must(queue.find(newer)).attempts.should eq(1)
    end
  end

  it "parks payloads it cannot read without counting the attempt, until retried" do
    PayloadSpec.with_queue do |queue, primary|
      tag = Random::Secure.hex(6)
      malformed = PayloadSpec.entry(queue, "PayloadSpec::Charge", 3, %({"tag": "#{tag}", "cents": "ten"}))
      raising = PayloadSpec.entry(queue, "PayloadSpec::Charge", 2, %({"tag": "#{tag}", "cents": -1}))
      deleted = PayloadSpec.entry(queue, "PayloadSpec::Trimmed", 1, %({"tag": "#{tag}"}))
      PayloadSpec.run(queue, primary).should eq([Punch::Job::Queue::Outcome::Parked] * 3)
      [malformed, raising, deleted].each do |id|
        row = PayloadSpec.must(queue.find(id))
        {row.state, row.attempts}.should eq({"incompatible", 0})
      end
      PayloadSpec.must(PayloadSpec.must(queue.find(malformed)).error).should start_with("PayloadSpec::Charge version 3: the payload does not parse: JSON::SerializableError")
      PayloadSpec.must(queue.find(raising)).error.should eq("PayloadSpec::Charge version 2: the payload does not parse: ArgumentError: negative amount -1")
      PayloadSpec.must(queue.find(deleted)).error.should eq("PayloadSpec::Trimmed version 1: PayloadSpec::Trimmed version 1 is not readable here: this binary reads 3, 2")
      PayloadSpec.ran(tag).should be_empty

      queue.version_counts.should eq([
        Punch::Job::Queue::VersionCount.new("PayloadSpec::Charge", 2, "incompatible", 1),
        Punch::Job::Queue::VersionCount.new("PayloadSpec::Charge", 3, "incompatible", 1),
        Punch::Job::Queue::VersionCount.new("PayloadSpec::Trimmed", 1, "incompatible", 1),
      ])
      queue.list(state: "incompatible").size.should eq(3)
      queue.purge(Time.utc + 1.day).should eq(0)

      queue.retry_job(deleted).should be_true
      PayloadSpec.must(queue.find(deleted)).state.should eq("ready")
      queue.discard_job(raising, "converted by hand").should be_true
      PayloadSpec.must(queue.find(raising)).state.should eq("discarded")
    end
  end
end
