require "../spec_helper"

module StepsSpec
  SQL = <<-SQL
    CREATE TABLE sources (id INTEGER PRIMARY KEY, tag TEXT NOT NULL, value TEXT NOT NULL) STRICT;
    CREATE TABLE copies (source_id INTEGER NOT NULL, tag TEXT NOT NULL, value TEXT NOT NULL) STRICT;
    CREATE TABLE exports (tag TEXT PRIMARY KEY, ready INTEGER NOT NULL) STRICT;
    #{Punch::Job::Steps::Progress.sql}
    SQL

  RAN  = {} of String => Array(String)
  LOCK = Mutex.new

  def self.ran(tag : String) : Array(String)
    LOCK.synchronize { RAN[tag]?.try(&.dup) || [] of String }
  end

  def self.log(tag : String, what : String) : Nil
    LOCK.synchronize { (RAN[tag] ||= [] of String) << what }
  end

  # Tags whose Copy fails at its source *fail_at* while set.
  FAILING = Set(String).new

  def self.failing(tag : String, on : Bool) : Nil
    LOCK.synchronize { on ? FAILING.add(tag) : FAILING.delete(tag) }
  end

  def self.failing?(tag : String) : Bool
    LOCK.synchronize { FAILING.includes?(tag) }
  end

  def self.tag : String
    Random::Secure.hex(6)
  end

  def self.must(value : T?) : T forall T
    value || fail "expected a value, got nil"
  end

  # *count* source rows for *tag*, in `Punch::Spec.db` or *database*.
  def self.sources(tag : String, count : Int32, database : Punch::Database = Punch::Spec.db) : Nil
    Punch::Migrations::Schema.load(database, SQL, "steps") unless Punch::Job::Steps::Progress.present?(database)
    database.write do |db|
      count.times { |index| db.exec("INSERT INTO sources (tag, value) VALUES (?, ?)", tag, "v#{index + 1}") }
    end
  end

  def self.copies(tag : String, database : Punch::Database = Punch::Spec.db) : Array(String)
    database.read do |db|
      db.query_all("SELECT value FROM copies WHERE tag = ? ORDER BY source_id", tag, &.read(String))
    end
  end

  # Copies a tag's sources three at a time, the cursor saved with each
  # batch. With *fail_at*, the batch holding that source fails inside its
  # transaction, after its rows were written, while the tag is failing.
  @[Punch::Job::Options(attempts: 2)]
  struct Copy
    include Punch::Job
    include Punch::Job::Stepped

    getter tag : String
    getter fail_at : Int64?
    getter pause_ms : Int32?

    def initialize(@tag, @fail_at = nil, @pause_ms = nil)
    end

    @[Punch::Job::Step]
    def count(job : Punch::Job::Context) : Punch::Job::StepResult
      StepsSpec.log(tag, "count")
      nil
    end

    @[Punch::Job::Step]
    def copy_rows(job : Punch::Job::Context, rows : Punch::Job::Cursor(Int64)) : Punch::Job::StepResult
      batch = job.read do |db|
        db.query_all("SELECT id, value FROM sources WHERE tag = ? AND id > ? ORDER BY id LIMIT 3", tag, rows.at || 0_i64) do |row|
          {row.read(Int64), row.read(String)}
        end
      end
      return if batch.empty?

      StepsSpec.log(tag, "batch after #{rows.at || "start"}")
      pause_ms.try { |millis| sleep millis.milliseconds }
      job.write do |db|
        batch.each { |id, value| db.exec("INSERT INTO copies (source_id, tag, value) VALUES (?, ?, ?)", id, tag, value) }
        raise "disk full" if StepsSpec.failing?(tag) && batch.any? { |id, _| id == fail_at }

        rows.continue(batch.last[0])
      end
    end

    @[Punch::Job::Step]
    def report(job : Punch::Job::Context) : Punch::Job::StepResult
      StepsSpec.log(tag, "report")
      nil
    end
  end

  # Waits for an export another system prepares, without holding a
  # worker or using attempts.
  @[Punch::Job::Options(attempts: 2)]
  struct Export
    include Punch::Job
    include Punch::Job::Stepped

    getter tag : String

    def initialize(@tag)
    end

    @[Punch::Job::Step]
    def wait_until_ready(job : Punch::Job::Context) : Punch::Job::StepResult
      ready = job.read { |db| db.query_one?("SELECT ready FROM exports WHERE tag = ?", tag, &.read(Int64)) }
      StepsSpec.log(tag, "checked")
      return again(in: 5.minutes) unless ready == 1

      nil
    end

    @[Punch::Job::Step]
    def download(job : Punch::Job::Context) : Punch::Job::StepResult
      StepsSpec.log(tag, "downloaded")
      nil
    end
  end

  # A cursor of two values, as keyset order on a column that is not
  # unique needs.
  record Position, at : Int64, id : Int64 do
    include JSON::Serializable
  end

  struct Walk
    include Punch::Job
    include Punch::Job::Stepped

    getter tag : String

    def initialize(@tag)
    end

    @[Punch::Job::Step]
    def walk(job : Punch::Job::Context, position : Punch::Job::Cursor(Position)) : Punch::Job::StepResult
      at = position.at
      StepsSpec.log(tag, at ? "#{at.at}/#{at.id}" : "start")
      return if at && at.id >= 4

      next_id = (at.try(&.id) || 0_i64) + 1
      position.continue(Position.new(next_id // 2, next_id))
    end
  end

  struct Gives
    include Punch::Job
    include Punch::Job::Stepped

    getter tag : String

    def initialize(@tag)
    end

    @[Punch::Job::Step]
    def first(job : Punch::Job::Context, items : Punch::Job::Cursor(Int32)) : Punch::Job::StepResult
      StepsSpec.log(tag, "first #{items.at || 0}")
      return discard("nothing to do") if items.at == 2

      items.continue((items.at || 0) + 1)
    end
  end
end

describe Punch::Job::Stepped do
  it "runs the steps in order, once each, and records the run as finished" do
    tag = StepsSpec.tag
    StepsSpec.sources(tag, 7)
    id = StepsSpec.must(Punch::Job::Queue.enqueue(StepsSpec::Copy.new(tag)))

    Punch::Spec.perform_jobs.map(&.outcome).should eq([Punch::Job::Queue::Outcome::Done])
    StepsSpec.copies(tag).should eq((1..7).map { |index| "v#{index}" })
    StepsSpec.ran(tag).should eq(["count", "batch after start", "batch after 3", "batch after 6", "report"])
    progress = StepsSpec.must(Punch::Spec.job_progress(id))
    progress.finished?.should be_true
    progress.step.should be_nil
  end

  it "ends the same when stopped after every save, never repeating a finished step or a saved batch" do
    tag = StepsSpec.tag
    StepsSpec.sources(tag, 7)
    Punch::Job::Queue.enqueue(StepsSpec::Copy.new(tag))

    outcomes = Punch::Spec.perform_jobs(interrupt_every: 1).map(&.outcome)
    outcomes.last.should eq(Punch::Job::Queue::Outcome::Done)
    outcomes.count(Punch::Job::Queue::Outcome::Paused).should eq(5)
    StepsSpec.copies(tag).should eq((1..7).map { |index| "v#{index}" })
    StepsSpec.ran(tag).should eq(["count", "batch after start", "batch after 3", "batch after 6", "report"])
    Punch::Spec.queue.find(StepsSpec.must(Punch::Spec.queue.list(type: "StepsSpec::Copy", limit: 1).first?).id).try(&.attempts).should eq(1)
  end

  it "rolls the cursor back with the batch that failed, so a retry repeats only that batch" do
    tag = StepsSpec.tag
    StepsSpec.sources(tag, 7)
    StepsSpec.failing(tag, true)
    clock = Punch::Spec.clock
    id = StepsSpec.must(Punch::Job::Queue.enqueue(StepsSpec::Copy.new(tag, fail_at: 5_i64)))

    Punch::Spec.perform_jobs.map(&.outcome).should eq([Punch::Job::Queue::Outcome::Retried])
    StepsSpec.must(Punch::Spec.job_progress(id)).cursor(Int64).should eq(3)
    StepsSpec.copies(tag).should eq(["v1", "v2", "v3"])

    StepsSpec.failing(tag, false)
    clock.advance(1.minute)
    Punch::Spec.perform_jobs.map(&.outcome).should eq([Punch::Job::Queue::Outcome::Done])
    StepsSpec.copies(tag).should eq((1..7).map { |index| "v#{index}" })
    StepsSpec.ran(tag).should eq(["count", "batch after start", "batch after 3", "batch after 3", "batch after 6", "report"])
  end

  it "resumes a failed run where it stopped when it is retried by hand" do
    tag = StepsSpec.tag
    StepsSpec.sources(tag, 7)
    StepsSpec.failing(tag, true)
    clock = Punch::Spec.clock
    id = StepsSpec.must(Punch::Job::Queue.enqueue(StepsSpec::Copy.new(tag, fail_at: 5_i64)))

    Punch::Spec.perform_jobs
    clock.advance(1.minute)
    Punch::Spec.perform_jobs.map(&.outcome).should eq([Punch::Job::Queue::Outcome::Failed])

    StepsSpec.failing(tag, false)
    Punch::Spec.queue.retry_job(id).should be_true
    Punch::Spec.perform_jobs.map(&.outcome).should eq([Punch::Job::Queue::Outcome::Done])
    StepsSpec.copies(tag).should eq((1..7).map { |index| "v#{index}" })
    StepsSpec.ran(tag).count("count").should eq(1)
  end

  it "waits with again(in:) outside the worker, without counting attempts" do
    tag = StepsSpec.tag
    StepsSpec.sources(tag, 0)
    clock = Punch::Spec.clock
    id = StepsSpec.must(Punch::Job::Queue.enqueue(StepsSpec::Export.new(tag)))

    3.times do
      Punch::Spec.perform_jobs.map(&.outcome).should eq([Punch::Job::Queue::Outcome::Paused])
      row = StepsSpec.must(Punch::Spec.queue.find(id))
      row.display_state(clock.now).should eq("scheduled")
      row.attempts.should eq(0)
      clock.advance(5.minutes)
    end
    Punch::Spec.db.write(&.exec("INSERT INTO exports (tag, ready) VALUES (?, 1)", tag))
    Punch::Spec.perform_jobs.map(&.outcome).should eq([Punch::Job::Queue::Outcome::Done])
    StepsSpec.ran(tag).should eq(["checked", "checked", "checked", "checked", "downloaded"])
  end

  it "resumes a cursor of several values" do
    tag = StepsSpec.tag
    StepsSpec.sources(tag, 0)
    Punch::Job::Queue.enqueue(StepsSpec::Walk.new(tag))

    Punch::Spec.perform_jobs(interrupt_every: 2).last.outcome.should eq(Punch::Job::Queue::Outcome::Done)
    StepsSpec.ran(tag).should eq(["start", "0/1", "1/2", "1/3", "2/4"])
  end

  it "forgets the progress of a discarded run, so a retry by hand starts over" do
    tag = StepsSpec.tag
    StepsSpec.sources(tag, 0)
    id = StepsSpec.must(Punch::Job::Queue.enqueue(StepsSpec::Gives.new(tag)))

    Punch::Spec.perform_jobs.map(&.outcome).should eq([Punch::Job::Queue::Outcome::Discarded])
    Punch::Spec.job_progress(id).should be_nil
    Punch::Spec.queue.retry_job(id).should be_true
    Punch::Spec.perform_jobs
    StepsSpec.ran(tag).should eq(["first 0", "first 1", "first 2", "first 0", "first 1", "first 2"])
  end

  it "parks a run stopped at a step this binary does not have" do
    tag = StepsSpec.tag
    StepsSpec.sources(tag, 3)
    id = StepsSpec.must(Punch::Job::Queue.enqueue(StepsSpec::Copy.new(tag)))
    key = StepsSpec.must(StepsSpec.must(Punch::Spec.queue.find(id)).unique_key)
    Punch::Spec.db.write { |db| Punch::Job::Steps::Progress.save(db, key, "StepsSpec::Copy", "copy_files", nil, Time.utc, false) }

    performed = Punch::Spec.perform_jobs
    performed.map(&.outcome).should eq([Punch::Job::Queue::Outcome::Parked])
    StepsSpec.must(performed.first.error).should contain("stopped at step `copy_files`, which this binary does not have (it has count, copy_rows, report)")
  end

  it "gives a job with steps a key of its own, never the row ID" do
    tag = StepsSpec.tag
    id = StepsSpec.must(Punch::Job::Queue.enqueue(StepsSpec::Copy.new(tag)))
    StepsSpec.must(StepsSpec.must(Punch::Spec.queue.find(id)).unique_key).should start_with("run-")
  end

  it "names the migration when primary.db lacks the progress table" do
    tag = StepsSpec.tag
    Punch::Job::Queue.enqueue(StepsSpec::Copy.new(tag))
    performed = Punch::Spec.perform_jobs
    performed.first.outcome.should eq(Punch::Job::Queue::Outcome::Retried)
    StepsSpec.must(performed.first.error).should contain("punch db:migration --punch steps")
  end

  it "lists the steps of every job with steps" do
    Punch::Job::Steps.names["StepsSpec::Copy"].should eq(["count", "copy_rows", "report"])
  end

  it "stops between calls when the worker stops, and another worker resumes it" do
    tag = StepsSpec.tag
    config = Punch::Job::Queue::Worker::Config.new(poll_interval: 50.milliseconds, heartbeat_interval: 50.milliseconds,
      stale_after: 200.milliseconds, shutdown_timeout: 2.seconds)
    context = Fiber::ExecutionContext::Parallel.new("punch-steps-spec", 2)
    Punch::Spec.database do |primary|
      StepsSpec.sources(tag, 30, primary)
      queue_db = Punch::Database.memory(name: "queue", config: Punch::Database::Config.new(readers: 2))
      begin
        queue = Punch::Job::Queue.new(queue_db)
        id = StepsSpec.must(queue.enqueue(StepsSpec::Copy.new(tag, pause_ms: 20)))
        worker = Punch::Job::Queue::Worker.new(queue, primary, Punch::Trace::Tracer.off, config, context: context, recurring: false)
        worker.start
        Punch::Spec.eventually { StepsSpec.copies(tag, primary).size.should be >= 6 }
        worker.stop

        row = StepsSpec.must(queue.find(id))
        row.state.should eq("ready")
        row.attempts.should eq(0)
        StepsSpec.copies(tag, primary).size.should be < 30

        second = Punch::Job::Queue::Worker.new(queue, primary, Punch::Trace::Tracer.off, config, context: context, recurring: false)
        second.start
        begin
          Punch::Spec.eventually(5.seconds) { StepsSpec.must(queue.find(id)).state.should eq("done") }
        ensure
          second.stop
        end
        StepsSpec.copies(tag, primary).should eq((1..30).map { |index| "v#{index}" })
        StepsSpec.ran(tag).count("count").should eq(1)
      ensure
        queue_db.close
      end
    end
  end
end
