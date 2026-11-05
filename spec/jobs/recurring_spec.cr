require "../spec_helper"

module RecurringSpec
  def self.must(value : T?) : T forall T
    value || fail "expected a value, got nil"
  end

  @[Punch::Job::Recurring(cron: "30 3 * * *")]
  struct Nightly
    include Punch::Job

    getter scope : String = "all"

    def initialize
    end

    def perform(job : Punch::Job::Context) : Punch::Job::Result
    end
  end

  @[Punch::Job::Recurring(every: 15.minutes)]
  @[Punch::Job::Options(queue: "maintenance")]
  struct Quarterly
    include Punch::Job

    def initialize
    end

    def perform(job : Punch::Job::Context) : Punch::Job::Result
    end
  end

  @[Punch::Job::Concurrency(1, by: :invoice_id)]
  struct PerInvoice
    include Punch::Job

    getter invoice_id : Int64
    getter step : Int32

    def initialize(@invoice_id, @step)
    end

    def perform(job : Punch::Job::Context) : Punch::Job::Result
    end
  end

  @[Punch::Job::Concurrency(2, group: "provider")]
  struct Charge
    include Punch::Job

    getter n : Int32

    def initialize(@n)
    end

    def perform(job : Punch::Job::Context) : Punch::Job::Result
    end
  end

  @[Punch::Job::Concurrency(2, group: "provider")]
  struct Refund
    include Punch::Job

    getter n : Int32

    def initialize(@n)
    end

    def perform(job : Punch::Job::Context) : Punch::Job::Result
    end
  end

  TYPES = Punch::Job::Queue::Registry.types

  def self.at(text : String) : Time
    Time.parse_utc(text, "%Y-%m-%d %H:%M")
  end

  def self.cron(expression : String, after : String) : String?
    Punch::Job::Queue::Cron.parse(expression).next_after(at(after)).try(&.to_s("%Y-%m-%d %H:%M %a"))
  end
end

describe Punch::Job::Queue::Cron do
  it "finds the next run after a time" do
    RecurringSpec.cron("30 3 * * *", "2026-10-11 03:29").should eq("2026-10-11 03:30 Sun")
    RecurringSpec.cron("30 3 * * *", "2026-10-11 03:30").should eq("2026-10-12 03:30 Mon")
    RecurringSpec.cron("*/15 * * * *", "2026-10-11 10:07").should eq("2026-10-11 10:15 Sun")
    RecurringSpec.cron("0 9-17/4 * * MON-FRI", "2026-10-09 17:01").should eq("2026-10-12 09:00 Mon")
    RecurringSpec.cron("0 0 1 JAN,jul *", "2026-02-01 00:00").should eq("2026-07-01 00:00 Wed")
    RecurringSpec.cron("0 0 29 2 *", "2026-03-01 00:00").should eq("2028-02-29 00:00 Tue")
    RecurringSpec.cron("@daily", "2026-12-31 23:59").should eq("2027-01-01 00:00 Fri")
    RecurringSpec.cron("@hourly", "2026-10-11 10:00").should eq("2026-10-11 11:00 Sun")
    RecurringSpec.cron("5 4 * * 7", "2026-10-11 05:00").should eq("2026-10-18 04:05 Sun")
  end

  it "runs on a day matching either day field when both are restricted" do
    # The 13th, or any Friday.
    RecurringSpec.cron("0 0 13 * 5", "2026-10-10 00:00").should eq("2026-10-13 00:00 Tue")
    RecurringSpec.cron("0 0 13 * 5", "2026-10-13 00:00").should eq("2026-10-16 00:00 Fri")
    # Day of month restricted alone.
    RecurringSpec.cron("0 0 13 * *", "2026-10-13 00:00").should eq("2026-11-13 00:00 Fri")
  end

  it "has no next run for a date that never comes" do
    RecurringSpec.cron("0 0 30 2 *", "2026-01-01 00:00").should be_nil
  end

  it "names what is wrong with an expression" do
    {
      "* * * *"     => "needs five fields",
      "60 * * * *"  => "cron minute: \"60\" is outside 0-59",
      "* * * * MOX" => "cron weekday: \"MOX\" is not a number or a name",
      "*/0 * * * *" => "step must be at least 1",
      "5-1 * * * *" => "is outside 0-59",
      "* * 0 * *"   => "cron day of month: \"0\" is outside 1-31",
    }.each do |expression, message|
      expect_raises(ArgumentError, message) { Punch::Job::Queue::Cron.parse(expression) }
    end
  end
end

describe Punch::Job::Queue::Every do
  it "runs at multiples of the interval from the epoch, the same in every process" do
    every = Punch::Job::Queue::Every.new(15.minutes)
    every.next_after(RecurringSpec.at("2026-10-11 10:07")).should eq(RecurringSpec.at("2026-10-11 10:15"))
    every.next_after(RecurringSpec.at("2026-10-11 10:15")).should eq(RecurringSpec.at("2026-10-11 10:30"))
    expect_raises(ArgumentError, "at least one minute") { Punch::Job::Queue::Every.new(30.seconds) }
  end
end

describe Punch::Job::Queue::Scheduler do
  it "lists the recurring jobs of the binary, Punch's own purges among them" do
    tasks = Punch::Job::Queue.tasks.to_h { |task| {task.type, task.schedule.to_s} }
    tasks["RecurringSpec::Nightly"].should eq("cron 30 3 * * *")
    tasks["RecurringSpec::Quarterly"].should eq("every 00:15:00")
    tasks["Punch::Job::Queue::Purge"].should eq("every 01:00:00")
    tasks["Punch::Auth::Purge"].should eq("every 01:00:00")
    tasks["Punch::Ops::Purge"].should eq("every 01:00:00")
    tasks["Punch::Caches::Trim"].should eq("every 00:10:00")
  end

  it "enqueues each run once, also from two processes, and makes up no missed runs" do
    clock = Punch::Spec.clock(RecurringSpec.at("2026-10-11 10:07"))
    Punch::Spec.database do |database|
      queue = Punch::Job::Queue.new(database)
      tasks = Punch::Job::Queue.tasks.select(&.type.starts_with?("RecurringSpec::"))
      first = Punch::Job::Queue::Scheduler.new(queue, tasks)
      second = Punch::Job::Queue::Scheduler.new(queue, tasks)
      first.tick.should be_empty
      second.tick.should be_empty
      first.next_runs.should eq([RecurringSpec.at("2026-10-12 03:30"), RecurringSpec.at("2026-10-11 10:15")])
      clock.now = RecurringSpec.at("2026-10-11 10:15")
      first.tick.size.should eq(1)
      second.tick.should be_empty
      job = queue.list.first
      {job.type, job.queue, job.run_at, job.unique_key}.should eq({"RecurringSpec::Quarterly", "maintenance",
                                                                   RecurringSpec.at("2026-10-11 10:15"), "recurring:RecurringSpec::Quarterly:#{RecurringSpec.at("2026-10-11 10:15").to_unix_ms}"})
      JSON.parse(job.payload).should eq(JSON.parse("{}"))
      # Down for an hour: one run at the next time, not four.
      clock.now = RecurringSpec.at("2026-10-11 11:16")
      first.tick.size.should eq(1)
      first.next_runs[1].should eq(RecurringSpec.at("2026-10-11 11:30"))
      queue.list.size.should eq(2)
    end
  end

  it "fills a recurring job's fields from their defaults" do
    Punch::Spec.database do |database|
      queue = Punch::Job::Queue.new(database)
      task = Punch::Job::Queue.tasks.find!(&.type.==("RecurringSpec::Nightly"))
      entry = task.entry.call(Time.utc)
      JSON.parse(entry.payload).should eq(JSON.parse(%({"scope": "all"})))
      RecurringSpec::Nightly.from_json(entry.payload).scope.should eq("all")
      queue.insert(entry).should_not be_nil
    end
  end
end

describe "Punch::Job::Queue concurrency limits" do
  it "runs one job per key at a time and unblocks the next when it ends" do
    Punch::Spec.database do |database|
      queue = Punch::Job::Queue.new(database)
      first = RecurringSpec.must(queue.enqueue(RecurringSpec::PerInvoice.new(7, 1)))
      second = RecurringSpec.must(queue.enqueue(RecurringSpec::PerInvoice.new(7, 2)))
      other = RecurringSpec.must(queue.enqueue(RecurringSpec::PerInvoice.new(8, 1)))
      queue.find(first).try(&.concurrency_key).should eq("RecurringSpec::PerInvoice:7")
      claimed = queue.claim("p", 10, RecurringSpec::TYPES)
      claimed.map(&.id).should eq([first, other])
      queue.find(second).try(&.state).should eq("blocked")
      queue.claim("p", 10, RecurringSpec::TYPES).should be_empty
      queue.finish(claimed[0], "p")
      queue.find(second).try(&.state).should eq("ready")
      queue.claim("p", 10, RecurringSpec::TYPES).map(&.id).should eq([second])
    end
  end

  it "unblocks after a retry, a release, and a crash, and shares a group's limit across types" do
    clock = Punch::Spec.clock
    Punch::Spec.database do |database|
      queue = Punch::Job::Queue.new(database)
      ids = [RecurringSpec::Charge.new(1), RecurringSpec::Refund.new(2), RecurringSpec::Charge.new(3)].map { |job| RecurringSpec.must(queue.enqueue(job)) }
      claimed = queue.claim("p", 10, RecurringSpec::TYPES)
      claimed.map(&.id).should eq(ids[0, 2])
      queue.find(ids[2]).try(&.state).should eq("blocked")
      queue.retry(claimed[0], "p", "busy")
      queue.find(ids[2]).try(&.state).should eq("ready")
      third = queue.claim("p", 10, RecurringSpec::TYPES)
      third.map(&.id).should eq([ids[2]])
      queue.release([ids[2]], "p")
      queue.find(ids[2]).try(&.state).should eq("ready")
      # A crashed holder: the sweep hands its job back and unblocks.
      queue.heartbeat("dead", "jobs", nil)
      queue.claim("dead", 10, RecurringSpec::TYPES).map(&.id).should eq([ids[2]])
      clock.advance(1.hour)
      queue.heartbeat("p", "serve", nil)
      queue.database.write { |db| db.exec("UPDATE punch_jobs SET state = 'blocked' WHERE id = ?", ids[0]) }
      queue.release_orphans(1.minute).should eq(1)
      queue.find(ids[0]).try(&.state).should eq("ready")
    end
  end
end

describe "Punch::Job::Queue pausing" do
  it "claims nothing from a paused queue until it resumes" do
    Punch::Spec.database do |database|
      queue = Punch::Job::Queue.new(database)
      id = RecurringSpec.must(queue.enqueue(RecurringSpec::Quarterly.new))
      queue.enqueue(RecurringSpec::PerInvoice.new(1, 1))
      queue.pause("maintenance").should be_true
      queue.pause("maintenance").should be_false
      queue.paused.should eq(["maintenance"])
      queue.claim("p", 10, RecurringSpec::TYPES).map(&.queue).should eq(["default"])
      queue.next_due(RecurringSpec::TYPES).should be_nil
      queue.resume("maintenance").should be_true
      queue.claim("p", 10, RecurringSpec::TYPES).map(&.id).should eq([id])
      expect_raises(ArgumentError, "queue names") { queue.pause("Mail") }
    end
  end
end
