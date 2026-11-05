require "../spec_helper"

module OutboxSpec
  def self.must(value : T?) : T forall T
    value || fail "expected a value, got nil"
  end

  SQL = <<-SQL
    CREATE TABLE orders (id INTEGER PRIMARY KEY, item TEXT NOT NULL, shipped INTEGER NOT NULL DEFAULT 0) STRICT;
    #{Punch::Job::Outbox.sql}
    SQL

  RAN  = {} of String => Array(String)
  LOCK = Mutex.new

  def self.ran(tag : String) : Array(String)
    LOCK.synchronize { RAN[tag]?.try(&.dup) || [] of String }
  end

  def self.record(tag : String, what : String) : Nil
    LOCK.synchronize { (RAN[tag] ||= [] of String) << what }
  end

  struct OrderPlaced
    include Punch::Event

    getter order_id : Int64
    getter item : String

    def initialize(@order_id, @item)
    end
  end

  @[Punch::Job::Options(queue: "mail")]
  struct Confirm
    include Punch::Job

    getter order_id : Int64
    getter item : String

    def initialize(@order_id, @item)
    end

    def perform(job : Punch::Job::Context) : Punch::Job::Result
      OutboxSpec.record(item, "confirm #{order_id}")
      nil
    end
  end

  # Runs as a job after the commit; writes to the primary.
  @[Punch::Subscriber::Delivery(:deferred)]
  @[Punch::Job::Options(queue: "shipping", attempts: 3)]
  @[Punch::Job::Concurrency(1, by: :order_id)]
  struct Ship
    include Punch::Subscriber(OrderPlaced)

    def call(event : OrderPlaced, job : Punch::Job::Context) : Punch::Job::Result
      return retry("warehouse busy") if event.item.starts_with?("busy") && job.attempt == 1
      return discard("order #{event.order_id} was cancelled") if event.item.starts_with?("cancelled")

      job.write { |db| db.exec("UPDATE orders SET shipped = shipped + 1 WHERE id = ?", event.order_id) }
      OutboxSpec.record(event.item, "ship #{event.order_id} attempt #{job.attempt}")
      nil
    end
  end

  # After commit as before: deferred subscribers leave it alone.
  struct Count
    include Punch::Subscriber(OrderPlaced)

    def call(event : OrderPlaced) : Nil
      OutboxSpec.record(event.item, "count")
    end
  end

  @[Punch::Status(422)]
  struct Refused
    include JSON::Serializable

    def initialize
    end
  end

  @[Punch::Status(200)]
  struct Placed
    include JSON::Serializable

    getter id : Int64

    def initialize(@id)
    end
  end

  module Orders
    @[Punch::Public]
    @[Punch::RateLimitExempt("spec")]
    struct Place < Punch::Command
      struct Input
        include Punch::Input

        getter item : String
        getter confirm_in : Int32?
      end

      # Enqueues, publishes, then refuses items starting with "refuse": the
      # rollback takes the outbox entries with it.
      def call(input : Input, db : Punch::Writer, events : Punch::Events(OrderPlaced), jobs : Punch::Jobs(Confirm)) : Placed | Refused
        id = db.query_one?("INSERT INTO orders (item) VALUES (?) RETURNING id", input.item, &.read(Int64)) || raise "no row"
        delay = input.confirm_in.try(&.minutes)
        jobs.enqueue(Confirm.new(id, input.item), in: delay)
        events.publish(OrderPlaced.new(id, input.item))
        return Refused.new if input.item.starts_with?("refuse")

        Placed.new(id)
      end
    end
  end

  def self.with_db(& : Punch::Database, Punch::Job::Queue ->) : Nil
    Punch::Spec.database do |database|
      Punch::Migrations::Schema.load(database, SQL, "outbox")
      Punch::Spec.database do |queue_db|
        yield database, Punch::Job::Queue.new(queue_db)
      end
    end
  end

  def self.place(database : Punch::Database, item : String, confirm_in : Int32? = nil) : Punch::Spec::Response
    client = Punch::Spec::Client.new(Punch::Routing::Router.new(database), openapi: nil)
    client.post(Orders::Place.path, json: {item: item, confirm_in: confirm_in})
  end

  def self.outbox(database : Punch::Database) : Array({String, String, Int64?})
    database.read do |db|
      db.query_all("SELECT type, queue, handed_over_at FROM punch_outbox ORDER BY id") { |row| {row.read(String), row.read(String), row.read(Int64?)} }
    end
  end

  def self.unique(prefix : String) : String
    "#{prefix} #{Random::Secure.hex(6)}"
  end

  # Runs every due job of *queue* against *database*, as perform_jobs does
  # for the example's own databases.
  def self.run_jobs(queue : Punch::Job::Queue, database : Punch::Database) : Array(Punch::Job::Queue::Outcome)
    outcomes = [] of Punch::Job::Queue::Outcome
    while job = queue.claim("spec", 1, Punch::Job::Queue::Registry.types).first?
      outcomes << Punch::Job::Queue.perform(job, queue, database, "spec", Punch::Trace::Tracer.off)
    end
    outcomes
  end
end

describe Punch::Job::Outbox do
  it "writes enqueued jobs and deferred deliveries in the Command's transaction" do
    OutboxSpec.with_db do |database, queue|
      item = OutboxSpec.unique("book")
      response = OutboxSpec.place(database, item)
      response.status.should eq(HTTP::Status::OK)
      OutboxSpec.outbox(database).should eq([
        {"OutboxSpec::Confirm", "mail", nil},
        {"OutboxSpec::Ship(OutboxSpec::OrderPlaced)", "shipping", nil},
      ])
      # After commit as before; the deferred subscriber has not run yet.
      OutboxSpec.ran(item).should eq(["count"])
      queue.list.should be_empty
    end
  end

  it "writes nothing when the Command fails" do
    OutboxSpec.with_db do |database, _|
      OutboxSpec.place(database, OutboxSpec.unique("refuse")).status.should eq(HTTP::Status::UNPROCESSABLE_ENTITY)
      OutboxSpec.outbox(database).should be_empty
    end
  end

  it "hands entries over once, keeps them marked, and the jobs run" do
    OutboxSpec.with_db do |database, queue|
      item = OutboxSpec.unique("lamp")
      id = OutboxSpec.place(database, item).json["id"].as_i64
      relay = Punch::Job::Outbox::Relay.new(database, queue)
      relay.drain.should eq(2)
      relay.drain.should eq(0)
      OutboxSpec.outbox(database).all?(&.[2]).should be_true
      jobs = queue.list.sort_by(&.id)
      jobs.map(&.type).should eq(["OutboxSpec::Confirm", "OutboxSpec::Ship(OutboxSpec::OrderPlaced)"])
      jobs.all?(&.unique_key.try(&.starts_with?("outbox:"))).should be_true
      jobs[1].concurrency_key.should eq("OutboxSpec::Ship:#{id}")
      jobs[1].max_attempts.should eq(3)
      OutboxSpec.run_jobs(queue, database).should eq([Punch::Job::Queue::Outcome::Done, Punch::Job::Queue::Outcome::Done])
      OutboxSpec.ran(item).should eq(["count", "confirm #{id}", "ship #{id} attempt 1"])
      database.read(&.query_one?("SELECT shipped FROM orders WHERE id = ?", id, &.read(Int64))).should eq(1)
    end
  end

  it "tells a missing outbox table once, with the way out, and without a backtrace" do
    backend = Log::MemoryBackend.new
    ::Log.setup(:error, backend)
    begin
      Punch::Spec.database do |database|
        Punch::Spec.database do |queue_db|
          relay = Punch::Job::Outbox::Relay.new(database, Punch::Job::Queue.new(queue_db), poll_interval: 5.milliseconds)
          relay.start
          sleep 100.milliseconds
          relay.stop
        end
      end
      errors = backend.entries.select(&.source.==("punch.outbox"))
      errors.size.should eq(1)
      errors.first.message.should contain("punch db:migration --punch outbox")
      errors.first.exception.should be_nil
    ensure
      ::Log.setup(:none)
    end
  end

  it "keeps the due time of a delayed enqueue" do
    OutboxSpec.with_db do |database, queue|
      before = Time.utc
      OutboxSpec.place(database, OutboxSpec.unique("later"), confirm_in: 10)
      Punch::Job::Outbox::Relay.new(database, queue).drain
      confirm = queue.list.find!(&.type.==("OutboxSpec::Confirm"))
      confirm.display_state(Time.utc).should eq("scheduled")
      (confirm.run_at - before).should be_close(10.minutes, 5.seconds)
    end
  end

  it "loses and duplicates nothing when the hand-over stops at any point" do
    {:read, :inserted, :marked}.each do |point|
      OutboxSpec.with_db do |database, queue|
        3.times { OutboxSpec.place(database, OutboxSpec.unique("crash")) }
        Punch::Job::Outbox::Relay.crash = ->(at : Symbol) { raise "crashed at #{at}" if at == point }
        begin
          expect_raises(Exception, "crashed at #{point}") { Punch::Job::Outbox::Relay.new(database, queue).drain }
        ensure
          Punch::Job::Outbox::Relay.crash = nil
        end
        # A new process starts over.
        Punch::Job::Outbox::Relay.new(database, queue).drain
        Punch::Job::Outbox::Relay.new(database, queue).drain.should eq(0)
        queue.list(limit: 100).size.should eq(6)
        OutboxSpec.outbox(database).all?(&.[2]).should be_true
      end
    end
  end

  it "makes one job of an entry handed over by two processes at once" do
    OutboxSpec.with_db do |database, queue|
      20.times { OutboxSpec.place(database, OutboxSpec.unique("race")) }
      done = Channel(Int32).new(4)
      4.times { spawn { done.send(Punch::Job::Outbox::Relay.new(database, queue, batch: 3).drain) } }
      4.times { done.receive }
      queue.list(limit: 100).size.should eq(40)
    end
  end

  it "retries a deferred subscriber like any job" do
    OutboxSpec.with_db do |database, queue|
      item = OutboxSpec.unique("busy")
      OutboxSpec.place(database, item)
      Punch::Job::Outbox::Relay.new(database, queue).drain
      OutboxSpec.run_jobs(queue, database).sort.should eq([Punch::Job::Queue::Outcome::Done, Punch::Job::Queue::Outcome::Retried])
      ship = queue.list.find!(&.type.starts_with?("OutboxSpec::Ship"))
      {ship.state, ship.error}.should eq({"ready", "warehouse busy"})
    end
  end

  it "discards a deferred subscriber's run with its reason" do
    OutboxSpec.with_db do |database, queue|
      OutboxSpec.place(database, OutboxSpec.unique("cancelled"))
      Punch::Job::Outbox::Relay.new(database, queue).drain
      OutboxSpec.run_jobs(queue, database).sort.should eq([Punch::Job::Queue::Outcome::Done, Punch::Job::Queue::Outcome::Discarded])
      ship = queue.list.find!(&.type.starts_with?("OutboxSpec::Ship"))
      {ship.state, ship.error.try(&.ends_with?("was cancelled"))}.should eq({"discarded", true})
    end
  end

  it "wakes the relay on commit, without waiting for its poll" do
    OutboxSpec.with_db do |database, queue|
      relay = Punch::Job::Outbox::Relay.new(database, queue, poll_interval: 10.seconds)
      relay.start
      begin
        sleep 20.milliseconds
        started = Time.instant
        OutboxSpec.place(database, OutboxSpec.unique("fast"))
        Punch::Spec.eventually { queue.list.size.should eq(2) }
        (Time.instant - started).should be < 1.second
        # A last hand-over when stopping.
        database.write { |db| Punch::Job::Outbox.add(db, Punch::Job::Queue.entry(OutboxSpec::Confirm.new(1, "x"), Time.utc)) }
      ensure
        relay.stop
      end
      queue.list.size.should eq(3)
    end
  end

  it "purges entries handed over before the retention window" do
    OutboxSpec.with_db do |database, queue|
      OutboxSpec.place(database, OutboxSpec.unique("old"))
      Punch::Job::Outbox::Relay.new(database, queue).drain
      database.write { |db| Punch::Job::Outbox.purge(db, Time.utc - 1.hour) }.should eq(0)
      database.write { |db| Punch::Job::Outbox.purge(db, Time.utc + 1.second) }.should eq(2)
      OutboxSpec.outbox(database).should be_empty
    end
  end

  it "names what the outbox table lacks" do
    Punch::Spec.database do |database|
      Punch::Job::Outbox.problems(database).should eq(["table punch_outbox is missing; add it with a migration (lib/punch/docs/jobs.md)"])
      database.write(&.exec("CREATE TABLE punch_outbox (id INTEGER PRIMARY KEY, key BLOB) STRICT"))
      problems = Punch::Job::Outbox.problems(database)
      problems.should contain("punch_outbox.key is BLOB, Punch needs TEXT")
      problems.should contain("punch_outbox.payload is missing (lib/punch/docs/jobs.md)")
    end
    OutboxSpec.with_db { |database, _| Punch::Job::Outbox.problems(database).should be_empty }
    Punch::Job::Outbox.used?.should be_true
  end

  it "lists deferred subscribers in the event graph" do
    node = Punch::Subscribers.graph.find!(&.event.==("OutboxSpec::OrderPlaced"))
    node.subscribers.should eq([{"OutboxSpec::Count", "after_commit"}, {"OutboxSpec::Ship", "deferred"}])
  end
end

describe "Punch::Spec jobs helpers" do
  it "hands over the example's outbox before listing and performing" do
    Punch::Migrations::Schema.load(Punch::Spec.db, OutboxSpec::SQL, "outbox")
    item = OutboxSpec.unique("spec")
    id = Punch::Spec.db.write do |writer|
      result = OutboxSpec::Orders::Place.new.call(Punch::Spec.input(OutboxSpec::Orders::Place::Input, item: item), writer,
        Punch::Spec.events(OutboxSpec::Orders::Place, writer), Punch::Spec.jobs(OutboxSpec::Orders::Place, writer))
      result.as(OutboxSpec::Placed).id
    end
    Punch::Spec.enqueued(OutboxSpec::Confirm).map(&.order_id).should eq([id])
    Punch::Spec.perform_jobs.map(&.type).sort!.should eq(["OutboxSpec::Confirm", "OutboxSpec::Ship(OutboxSpec::OrderPlaced)"])
    OutboxSpec.ran(item).should eq(["count", "confirm #{id}", "ship #{id} attempt 1"])
  end
end
