require "../spec_helper"

module OpsSpec
  struct Pinged
    include Punch::Event

    getter tag : String

    def initialize(@tag)
    end
  end

  # Fails after commit: the response stands, the error is recorded.
  struct Grumpy
    include Punch::Subscriber(Pinged)

    def call(event : Pinged) : Nil
      raise ArgumentError.new("grumpy about #{event.tag}") if event.tag.starts_with?("grumpy")
    end
  end

  @[Punch::Public]
  @[Punch::RateLimitExempt("a spec fixture")]
  struct Ping < Punch::Command
    struct Input
      include Punch::Input

      getter tag : String
    end

    struct Ponged
      include JSON::Serializable

      def initialize
      end
    end

    def call(input : Input, db : Punch::Writer, events : Punch::Events(Pinged)) : Ponged
      events.publish(Pinged.new(input.tag))
      Ponged.new
    end
  end

  @[Punch::Public]
  @[Punch::RateLimitExempt("a spec fixture")]
  struct Boom < Punch::Command
    struct Input
      include Punch::Input

      getter key : String
    end

    def call(input : Input, db : Punch::Writer) : Nil
      {"a" => 1}.fetch(input.key) { raise KeyError.new("no #{input.key}") }
      nil
    end
  end

  struct Crash
    include Punch::Job

    getter tag : String

    def initialize(@tag)
    end

    def perform(job : Punch::Job::Context) : Punch::Job::Result
      raise IndexError.new("crash #{tag}")
    end
  end

  struct Fine
    include Punch::Job

    def initialize
    end

    def perform(job : Punch::Job::Context) : Punch::Job::Result
      nil
    end
  end

  @[Punch::Public]
  struct Count < Punch::Query
    struct Input
      include Punch::Input
    end

    struct Counted
      include JSON::Serializable

      getter one : Int64

      def initialize(@one)
      end
    end

    def call(input : Input, db : Punch::Reader) : Counted
      Counted.new(db.query_one?("SELECT 1", name: "OpsSpec.one", &.read(Int64)) || 0_i64)
    end
  end

  def self.must(value : T?) : T forall T
    value || fail "expected a value, got nil"
  end

  # A finished wide event as a request would emit it, with *exception*
  # raised in it when given.
  def self.event(name : String = "GET /x", kind : Punch::Trace::Kind = :server, exception : Exception? = nil, & : Punch::Trace::Span ->) : Punch::Trace::Span
    sink = Punch::Trace::MemoryEvents.new
    tracer = Punch::Trace::Tracer.new(events: [sink] of Punch::Trace::EventSink)
    root = tracer.start(name, kind)
    Punch::Trace.with(root) { yield root }
    root.error(exception) if exception
    root.finish
    sink.events.first
  end

  def self.event(name : String = "GET /x", kind : Punch::Trace::Kind = :server, exception : Exception? = nil) : Punch::Trace::Span
    event(name, kind, exception) { }
  end

  def self.raised(message : String) : Exception
    raise ArgumentError.new(message)
  rescue ex
    ex
  end
end

describe Punch::Ops do
  describe "the store" do
    it "groups exceptions by fingerprint, counts them, and keeps the request's wide event" do
      store = Punch::Spec.ops
      2.times { |index| store.store([OpsSpec.must(Punch::Ops::Sink.capture(OpsSpec.event(exception: OpsSpec.raised("bad #{index}"))))]) }
      store.store([OpsSpec.must(Punch::Ops::Sink.capture(OpsSpec.event("GET /y", exception: OpsSpec.raised("elsewhere"))))])
      groups = store.errors
      groups.map(&.source).should eq(["GET /y", "GET /x"])
      group = groups.last
      group.exception.should eq("ArgumentError")
      group.occurrences.should eq(2)
      group.message.should eq("bad 1")
      OpsSpec.must(group.backtrace).should contain("ops_spec.cr")
      occurrences = store.occurrences(group.id)
      occurrences.size.should eq(2)
      record = OpsSpec.must(store.record(OpsSpec.must(occurrences.first.record_id)))
      record.kind.should eq("request")
      record.failed.should be_true
      JSON.parse(record.fields)["error"].should eq("ArgumentError")
      record.trace_id.should eq(occurrences.first.trace_id)
    end

    it "resolves, opens again on a new occurrence, and reopens by hand" do
      store = Punch::Spec.ops
      capture = OpsSpec.must(Punch::Ops::Sink.capture(OpsSpec.event(exception: OpsSpec.raised("bad"))))
      store.store([capture])
      id = store.errors.first.id
      store.resolve(id).should be_true
      store.resolve(id).should be_false
      store.errors.should be_empty
      store.errors(resolved: true).map(&.id).should eq([id])
      store.store([capture])
      OpsSpec.must(store.error(id)).resolved?.should be_false
      store.resolve(id)
      store.reopen(id).should be_true
      store.reopen(id).should be_false
      store.summary.open_errors.should eq(1)
    end

    it "purges history past retention but keeps open errors" do
      clock = Punch::Spec.clock
      store = Punch::Spec.ops
      old = OpsSpec.must(Punch::Ops::Sink.capture(OpsSpec.event(exception: OpsSpec.raised("old"))))
      store.store([old.copy_with(at: clock.now - 20.days)])
      resolved = OpsSpec.must(Punch::Ops::Sink.capture(OpsSpec.event("GET /gone", exception: OpsSpec.raised("gone"))))
      store.store([resolved.copy_with(at: clock.now - 20.days)])
      store.resolve(store.errors.find!(&.source.==("GET /gone")).id)
      store.store([OpsSpec.must(Punch::Ops::Sink.capture(OpsSpec.event("job Fine", :consumer))).copy_with(at: clock.now - 1.day)])
      # The resolved group (its occurrence goes with it), the open group's
      # occurrence, and both old records; the open group stays.
      store.purge(clock.now - 14.days).should eq(4)
      store.errors(resolved: nil).map(&.source).should eq(["GET /x"])
      store.records.map(&.name).should eq(["job Fine"])
    end

    it "refuses a file of another layout" do
      Punch::Spec.database do |db|
        db.write(&.exec("CREATE TABLE punch_ops_errors (id INTEGER PRIMARY KEY)"))
        db.write(&.exec("PRAGMA user_version = 99"))
        expect_raises(Punch::Ops::Error, /ops layout 99/) { Punch::Ops::Store.new(db) }
      end
    end
  end

  describe "fingerprints" do
    it "ignore the message and line numbers, and tell sources apart" do
      a = OpsSpec.raised("one")
      b = OpsSpec.raised("two")
      Punch::Ops.fingerprint(a, "GET /x").should eq(Punch::Ops.fingerprint(b, "GET /x"))
      Punch::Ops.fingerprint(a, "GET /x").should_not eq(Punch::Ops.fingerprint(a, "GET /y"))
      Punch::Ops.frames(a).none?(&.matches?(/:\d+/)).should be_true
      Punch::Ops.frames(a).first.should contain("ops_spec.cr")
    end
  end

  describe "the sink" do
    it "keeps failures always, job runs and events by sample, successful requests never" do
      job = OpsSpec.event("job Fine", :consumer)
      Punch::Ops::Sink.capture(job, 1.0).try(&.keep).should be_true
      Punch::Ops::Sink.capture(job, 0.0).should be_nil
      Punch::Ops::Sink.capture(OpsSpec.event("job Crash", :consumer, OpsSpec.raised("x")), 0.0).try(&.keep).should be_true
      Punch::Ops::Sink.capture(OpsSpec.event).should be_nil
      with_events = OpsSpec.event(&.append("punch.events", "OpsSpec::Pinged"))
      capture = OpsSpec.must(Punch::Ops::Sink.capture(with_events, 1.0))
      capture.keep.should be_false
      capture.events.should eq(["OpsSpec::Pinged"])
      Punch::Ops::Sink.capture(with_events, 0.0).should be_nil
    end

    it "writes in batches from its own fiber and drains on close" do
      store = Punch::Spec.ops
      sink = Punch::Ops::Sink.new(store, batch: 7)
      50.times { |index| sink.emit(OpsSpec.event("job Fine #{index}", :consumer)) }
      sink.close
      store.records(limit: 100).size.should eq(50)
      sink.emit(OpsSpec.event("job late", :consumer))
      sink.dropped.should eq(0)
    end

    it "drops and counts what does not fit instead of waiting" do
      store = Punch::Spec.ops
      sink = Punch::Ops::Sink.new(store, capacity: 1)
      events = Array.new(200) { OpsSpec.event("job Fine", :consumer) }
      events.each { |event| sink.emit(event) }
      sink.close
      (store.records(limit: 1000).size + sink.dropped).should be <= 200
      sink.dropped.should be > 0
    end
  end

  describe "fed by the app" do
    it "records an operation's exception through the client, with the route as source" do
      ops = Punch::Spec.ops
      response = Punch::Spec.client(raise_errors: false).post(OpsSpec::Boom.path, json: {key: "b"})
      response.status.code.should eq(500)
      group = ops.errors.first
      group.exception.should eq("KeyError")
      group.source.should eq("POST /ops_spec/boom")
      group.message.should eq("no b")
    end

    it "records committed events and an after-commit subscriber's exception" do
      ops = Punch::Spec.ops
      Punch::Spec.client.post(OpsSpec::Ping.path, json: {tag: "fine"}).status.code.should eq(200)
      Punch::Spec.client.post(OpsSpec::Ping.path, json: {tag: "grumpy one"}).status.code.should eq(200)
      ops.events.map(&.event).should eq(["OpsSpec::Pinged", "OpsSpec::Pinged"])
      group = ops.errors.first
      group.source.should eq("OpsSpec::Grumpy")
      group.message.should eq("grumpy about grumpy one")
      OpsSpec.must(ops.record(OpsSpec.must(ops.occurrences(group.id).first.record_id))).failed.should be_false
    end

    it "records job runs, failed ones with their error" do
      ops = Punch::Spec.ops
      Punch::Spec.queue.enqueue(OpsSpec::Crash.new("a"))
      Punch::Spec.queue.enqueue(OpsSpec::Fine.new)
      Punch::Spec.perform_jobs
      runs = ops.records(kind: "job")
      runs.map(&.name).sort!.should eq(["job OpsSpec::Crash", "job OpsSpec::Fine"])
      crash = runs.find!(&.name.ends_with?("Crash"))
      crash.failed.should be_true
      crash.job_id.should_not be_nil
      ops.records(job_id: crash.job_id).size.should eq(1)
      ops.errors.first.source.should eq("job OpsSpec::Crash")
      ops.summary.failed_runs_24h.should eq(1)
    end

    it "purges through the recurring job" do
      clock = Punch::Spec.clock
      ops = Punch::Spec.ops
      ops.store([OpsSpec.must(Punch::Ops::Sink.capture(OpsSpec.event("job Old", :consumer))).copy_with(at: clock.now - 30.days)])
      Punch::Spec.queue.enqueue(Punch::Ops::Purge.new)
      Punch::Spec.perform_jobs
      ops.records.map(&.name).should eq(["job Punch::Ops::Purge"])
    end
  end

  describe "performance" do
    it "adds up runs and named queries per name and bucket, with percentiles from the buckets" do
      store = Punch::Spec.ops
      3.times do
        event = OpsSpec.event do |root|
          root.tally_query("Billing.invoice", 2.0, 1, true)
          root.tally_query("Billing.invoice", 30.0, 1, false)
          root.add("punch.db.writer_wait_ms", 1.5)
          root.set("punch.idempotency", "replayed")
        end
        store.store(Punch::Ops::Sink.tallies(event))
      end
      since = Punch::Spec.clock.now - 1.hour
      request = store.stats("request", since: since).find!(&.name.==("GET /x"))
      request.count.should eq(3)
      request.failed.should eq(0)
      request.wait_ms.should eq(4.5)
      request.replays.should eq(3)
      query = store.stats("query", since: since).find!(&.name.==("Billing.invoice"))
      {query.count, query.failed, query.rows}.should eq({6, 3, 6})
      query.max_ms.should eq(30.0)
      query.average_ms.should eq(16.0)
      # Half the runs took 2 ms (bucket up to 2.5 ms), half 30 ms (up to 50 ms, capped at the longest).
      query.percentile(0.5).should eq(2.5)
      query.percentile(0.99).should eq(30.0)
      store.series("query", "Billing.invoice", since: since).map(&.count).should eq([6])
    end

    it "counts requests and named queries of the app through the client" do
      ops = Punch::Spec.ops
      2.times { Punch::Spec.client.get(OpsSpec::Count.path).status.code.should eq(200) }
      since = Punch::Spec.clock.now - 1.hour
      ops.stats("request", since: since).find!(&.name.==("GET /ops_spec/count")).count.should eq(2)
      ops.stats("query", since: since).find!(&.name.==("OpsSpec.one")).count.should eq(2)
      ops.slowest(since: since).should be_empty
    end

    it "keeps slow requests, at most a sample per route and bucket, and writes the stats at close" do
      previous = Punch::Ops.slow
      Punch::Ops.slow = 0.milliseconds
      begin
        store = Punch::Spec.ops
        Punch::Ops::Sink.capture(OpsSpec.event).try(&.keep).should be_true
        sink = Punch::Ops::Sink.new(store)
        15.times { sink.emit(OpsSpec.event("GET /slow")) }
        sink.close
        store.records(kind: "request", limit: 100).size.should eq(Punch::Ops::Sink::SLOW_PER_BUCKET)
        store.slowest(since: Time.utc - 1.hour).size.should eq(Punch::Ops::Sink::SLOW_PER_BUCKET)
        store.stats("request", since: Time.utc - 1.hour).find!(&.name.==("GET /slow")).count.should eq(15)
      ensure
        Punch::Ops.slow = previous
      end
    end

    it "purges stats past retention" do
      clock = Punch::Spec.clock
      store = Punch::Spec.ops
      tallies = Punch::Ops::Tallies.new
      tallies[{"request", "GET /old", Punch::Ops.bucket(clock.now - 20.days)}] = Punch::Ops::Tally.new.tap(&.run(1.0, false))
      tallies[{"request", "GET /new", Punch::Ops.bucket(clock.now)}] = Punch::Ops::Tally.new.tap(&.run(1.0, false))
      store.store(tallies)
      store.purge(clock.now - 14.days).should eq(1)
      store.stats("request", since: clock.now - 30.days).map(&.name).should eq(["GET /new"])
    end

    it "opens a file of layout 1 or 2 as layout 3 and keeps its history, its open errors counted as notified" do
      {1, 2}.each do |layout|
        Punch::Spec.database do |db|
          db.write do |writer|
            tables = Punch::Ops::Store::TABLES.to_a - Punch::Ops::Store::NOTICE_TABLES.to_a
            tables -= Punch::Ops::Store::STATS_TABLES.to_a if layout == 1
            tables.each do |sql|
              writer.exec(sql.sub(",\n  opened_at   INTEGER NOT NULL DEFAULT 0,\n  notified_at INTEGER", ""))
            end
            writer.exec("INSERT INTO punch_ops_errors (fingerprint, exception, source, first_seen, last_seen, occurrences) VALUES ('f', 'E', 's', 1, 1, 3)")
            writer.exec("PRAGMA user_version = #{layout}")
          end
          store = Punch::Ops::Store.new(db)
          db.read { |reader| reader.query_one?("PRAGMA user_version", &.read(Int64)) }.should eq(3)
          store.errors.first.occurrences.should eq(3)
          store.stats("request", since: Time.utc - 1.hour).should be_empty
          store.unnotified.should be_empty
        end
      end
    end
  end

  describe "reports" do
    it "records an error raised outside any trace" do
      ops = Punch::Spec.ops
      tracer = Punch::Trace::Tracer.new(events: [Punch::Spec::OpsEvents.new] of Punch::Trace::EventSink)
      tracer.report(OpsSpec.raised("heartbeat"), "jobs: heartbeat")
      ops.errors.first.source.should eq("jobs: heartbeat")
      ops.records(kind: "other").size.should eq(1)
    end
  end
end
