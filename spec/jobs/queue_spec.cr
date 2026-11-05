require "../spec_helper"

module QueueSpec
  # The value, or the example fails: for IDs and rows that must exist.
  def self.must(value : T?) : T forall T
    value || fail "expected a value, got nil"
  end

  # What jobs did, by a tag unique per example, so examples on several
  # threads do not meet.
  RAN  = {} of String => Array(String)
  LOCK = Mutex.new

  def self.ran(tag : String) : Array(String)
    LOCK.synchronize { RAN[tag]?.try(&.dup) || [] of String }
  end

  def self.record(tag : String, what : String) : Nil
    LOCK.synchronize { (RAN[tag] ||= [] of String) << what }
  end

  struct Note
    include Punch::Job

    getter tag : String
    getter text : String

    def initialize(@tag, @text)
    end

    def perform(job : Punch::Job::Context) : Punch::Job::Result
      QueueSpec.record(tag, "#{text}:#{job.attempt}")
      nil
    end
  end

  @[Punch::Job::Options(queue: "mail", attempts: 3, priority: 5)]
  struct Flaky
    include Punch::Job

    getter tag : String
    getter succeed_on : Int32

    def initialize(@tag, @succeed_on)
    end

    def perform(job : Punch::Job::Context) : Punch::Job::Result
      QueueSpec.record(tag, "attempt #{job.attempt}")
      return if job.attempt >= succeed_on

      retry("provider busy")
    end
  end

  # Asks to be retried later than its backoff would.
  struct Later
    include Punch::Job

    getter tag : String

    def initialize(@tag)
    end

    def perform(job : Punch::Job::Context) : Punch::Job::Result
      retry("rate limited", after: 2.hours)
    end
  end

  struct Raises
    include Punch::Job

    getter tag : String

    def initialize(@tag)
    end

    def perform(job : Punch::Job::Context) : Punch::Job::Result
      raise ArgumentError.new("bug in #{tag}")
    end
  end

  struct Gone
    include Punch::Job

    getter tag : String

    def initialize(@tag)
    end

    def perform(job : Punch::Job::Context) : Punch::Job::Result
      discard("nothing left to do")
    end
  end

  # Writes to the primary database and enqueues a follow-up after.
  struct Chain
    include Punch::Job

    getter tag : String
    getter left : Int32

    def initialize(@tag, @left)
    end

    def perform(job : Punch::Job::Context) : Punch::Job::Result
      job.write { |db| db.exec("INSERT INTO chain (tag, left) VALUES (?, ?)", tag, left.to_i64) }
      job.enqueue(Chain.new(tag, left - 1)) if left > 0
      nil
    end
  end

  # Tries to enqueue inside its write: refused.
  struct Sneaky
    include Punch::Job

    getter tag : String

    def initialize(@tag)
    end

    def perform(job : Punch::Job::Context) : Punch::Job::Result
      job.write { |_| job.enqueue(Note.new(tag, "inside")) }
      nil
    end
  end

  struct Slow
    include Punch::Job

    getter tag : String
    getter millis : Int32

    def initialize(@tag, @millis)
    end

    def perform(job : Punch::Job::Context) : Punch::Job::Result
      QueueSpec.record(tag, "start")
      sleep millis.milliseconds
      QueueSpec.record(tag, "end")
      nil
    end
  end

  def self.tag : String
    Random::Secure.hex(6)
  end

  def self.queue(& : Punch::Job::Queue ->) : Nil
    Punch::Spec.database do |database|
      yield Punch::Job::Queue.new(database)
    end
  end

  TYPES = Punch::Job::Queue::Registry.types
end

describe Punch::Job::Queue do
  it "knows every job type of the binary by name, with the payload version it reads" do
    QueueSpec::TYPES["QueueSpec::Note"].should eq(1)
    QueueSpec::TYPES["QueueSpec::Flaky"].should eq(1)
  end

  it "enqueues, claims with an attempt counted, and finishes" do
    QueueSpec.queue do |queue|
      id = QueueSpec.must(queue.enqueue(QueueSpec::Note.new("t", "hi")))
      claimed = queue.claim("p1", 10, QueueSpec::TYPES)
      claimed.map(&.id).should eq([id])
      job = claimed.first
      job.type.should eq("QueueSpec::Note")
      job.queue.should eq("default")
      job.attempts.should eq(1)
      job.max_attempts.should eq(10)
      JSON.parse(job.payload).should eq(JSON.parse(%({"tag":"t","text":"hi"})))
      queue.claim("p2", 10, QueueSpec::TYPES).should be_empty
      queue.finish(job, "p1").should eq(Punch::Job::Queue::Outcome::Done)
      row = QueueSpec.must(queue.find(id))
      row.state.should eq("done")
      row.finished_at.should_not be_nil
      row.claimed_by.should be_nil
    end
  end

  it "takes queue, attempts, and priority from @[Punch::Job::Options]" do
    QueueSpec.queue do |queue|
      queue.enqueue(QueueSpec::Note.new("t", "low"))
      queue.enqueue(QueueSpec::Flaky.new("t", 1))
      claimed = queue.claim("p", 10, QueueSpec::TYPES)
      claimed.map(&.type).should eq(%w[QueueSpec::Flaky QueueSpec::Note])
      claimed.first.queue.should eq("mail")
      claimed.first.max_attempts.should eq(3)
    end
  end

  it "claims due jobs most urgent first: priority, then due time, then order" do
    clock = Punch::Spec.clock
    QueueSpec.queue do |queue|
      later = QueueSpec.must(queue.enqueue(QueueSpec::Note.new("t", "later"), in: 1.minute))
      first = QueueSpec.must(queue.enqueue(QueueSpec::Note.new("t", "first")))
      second = QueueSpec.must(queue.enqueue(QueueSpec::Note.new("t", "second")))
      urgent = QueueSpec.must(queue.enqueue(QueueSpec::Flaky.new("t", 1)))
      queue.claim("p", 2, QueueSpec::TYPES).map(&.id).should eq([urgent, first])
      queue.claim("p", 10, QueueSpec::TYPES).map(&.id).should eq([second])
      queue.next_due(QueueSpec::TYPES).should eq(Time.unix_ms((clock.now + 1.minute).to_unix_ms))
      clock.advance(1.minute)
      queue.claim("p", 10, QueueSpec::TYPES).map(&.id).should eq([later])
      queue.next_due(QueueSpec::TYPES).should be_nil
    end
  end

  it "claims and waits for only the queues it is given, and releases what it claimed" do
    QueueSpec.queue do |queue|
      note = QueueSpec.must(queue.enqueue(QueueSpec::Note.new("t", "default")))
      mail = QueueSpec.must(queue.enqueue(QueueSpec::Flaky.new("t", 1)))
      queue.next_due(QueueSpec::TYPES, ["other"]).should be_nil
      queue.next_due(QueueSpec::TYPES, [] of String).should be_nil
      queue.next_due(QueueSpec::TYPES, ["mail"]).should_not be_nil
      queue.claim("p", 10, QueueSpec::TYPES, [] of String).should be_empty
      queue.claim("p", 10, QueueSpec::TYPES, ["mail"]).map(&.id).should eq([mail])
      queue.claim("p", 10, QueueSpec::TYPES, ["default", "mail"]).map(&.id).should eq([note])
      queue.release([note, mail], "p").should eq(2)
      queue.claim("p", 10, QueueSpec::TYPES).map(&.id).sort!.should eq([note, mail].sort)
    end
  end

  it "shows a ready job that is not due as scheduled" do
    clock = Punch::Spec.clock
    QueueSpec.queue do |queue|
      queue.enqueue(QueueSpec::Note.new("t", "now"))
      at = QueueSpec.must(queue.enqueue(QueueSpec::Note.new("t", "later"), at: clock.now + 1.hour))
      queue.list(state: "scheduled").map(&.id).should eq([at])
      queue.list(state: "ready").size.should eq(1)
      queue.counts.map { |count| {count.state, count.jobs} }.sort!.should eq([{"ready", 1_i64}, {"scheduled", 1_i64}])
      expect_raises(ArgumentError, "not both") { queue.enqueue(QueueSpec::Note.new("t", "x"), at: clock.now, in: 1.second) }
    end
  end

  it "claims only the types it is given, so a binary leaves jobs it does not know" do
    QueueSpec.queue do |queue|
      queue.insert(Punch::Job::Queue::Entry.new("default", "Newer::Job", 1, "{}", 0, Time.utc, 10))
      queue.claim("p", 10, QueueSpec::TYPES).should be_empty
      queue.list(state: "ready").size.should eq(1)
    end
  end

  it "inserts a job with a unique key once" do
    QueueSpec.queue do |queue|
      entry = Punch::Job::Queue.entry(QueueSpec::Note.new("t", "once"), Time.utc, unique_key: "k1")
      queue.insert(entry).should_not be_nil
      queue.insert(entry).should be_nil
      queue.insert([entry, Punch::Job::Queue.entry(QueueSpec::Note.new("t", "two"), Time.utc, unique_key: "k2")]).size.should eq(1)
      queue.list.size.should eq(2)
    end
  end

  it "retries after a backoff and fails after the last attempt" do
    clock = Punch::Spec.clock
    QueueSpec.queue do |queue|
      id = QueueSpec.must(queue.enqueue(QueueSpec::Flaky.new("t", 99)))
      3.times do |attempt|
        job = queue.claim("p", 1, QueueSpec::TYPES).first
        job.attempts.should eq(attempt + 1)
        outcome = queue.retry(job, "p", "provider busy")
        if attempt < 2
          outcome.should eq(Punch::Job::Queue::Outcome::Retried)
          row = QueueSpec.must(queue.find(id))
          row.state.should eq("ready")
          row.error.should eq("provider busy")
          wait = row.run_at - clock.now
          base = 15.0 * 3.0 ** attempt
          wait.total_seconds.should be_close(base, base * 0.16)
          queue.claim("p", 1, QueueSpec::TYPES).should be_empty
          clock.advance(wait)
        else
          outcome.should eq(Punch::Job::Queue::Outcome::Failed)
        end
      end
      row = QueueSpec.must(queue.find(id))
      row.state.should eq("failed")
      row.attempts.should eq(3)
    end
  end

  it "backs off 15 s, tripled each time, to at most 6 hours" do
    Punch::Job::Queue.backoff(1).total_seconds.should be_close(15, 2.3)
    Punch::Job::Queue.backoff(4).total_seconds.should be_close(405, 61)
    Punch::Job::Queue.backoff(30).total_seconds.should be_close(21_600, 3_240)
  end

  it "retries after the span a Retry asks for" do
    clock = Punch::Spec.clock
    QueueSpec.queue do |queue|
      id = QueueSpec.must(queue.enqueue(QueueSpec::Note.new("t", "x")))
      job = queue.claim("p", 1, QueueSpec::TYPES).first
      queue.retry(job, "p", "rate limited", 2.minutes)
      QueueSpec.must(queue.find(id)).run_at.should eq(Time.unix_ms((clock.now + 2.minutes).to_unix_ms))
    end
  end

  it "hands jobs back on release without counting the attempt" do
    QueueSpec.queue do |queue|
      id = QueueSpec.must(queue.enqueue(QueueSpec::Note.new("t", "x")))
      job = queue.claim("p", 1, QueueSpec::TYPES).first
      queue.release([id], "other").should eq(0)
      queue.release([id], "p").should eq(1)
      row = QueueSpec.must(queue.find(id))
      row.state.should eq("ready")
      row.attempts.should eq(0)
      # The worker that held it can no longer record a result.
      queue.finish(job, "p").should eq(Punch::Job::Queue::Outcome::Lost)
    end
  end

  it "hands back jobs of a process that stopped beating, counting the attempt" do
    clock = Punch::Spec.clock
    QueueSpec.queue do |queue|
      alive = QueueSpec.must(queue.enqueue(QueueSpec::Note.new("t", "alive")))
      queue.heartbeat("alive", "serve", nil)
      queue.claim("alive", 1, QueueSpec::TYPES)
      dead = QueueSpec.must(queue.enqueue(QueueSpec::Flaky.new("t", 1)))
      last = QueueSpec.must(queue.enqueue(QueueSpec::Flaky.new("t", 1)))
      queue.heartbeat("dead", "jobs", ["mail"])
      queue.claim("dead", 1, QueueSpec::TYPES)
      queue.processes.map(&.id).sort!.should eq(%w[alive dead])
      clock.advance(30.seconds)
      queue.heartbeat("alive", "serve", nil)
      queue.release_orphans(1.minute).should eq(0)
      clock.advance(40.seconds)
      queue.heartbeat("alive", "serve", nil)
      queue.release_orphans(1.minute).should eq(1)
      queue.processes.map(&.id).should eq(%w[alive])
      row = QueueSpec.must(queue.find(dead))
      row.state.should eq("ready")
      row.attempts.should eq(1)
      QueueSpec.must(row.error).should contain("interrupted: process dead stopped")
      QueueSpec.must(queue.find(alive)).state.should eq("running")
      # Out of attempts: failed, not a loop of crashes.
      queue.retry_job(last).should be_false
      2.times do
        queue.claim("dead", 3, QueueSpec::TYPES)
        clock.advance(2.minutes)
        queue.heartbeat("alive", "serve", nil)
        queue.release_orphans(1.minute)
      end
      queue.claim("dead", 3, QueueSpec::TYPES)
      clock.advance(2.minutes)
      queue.release_orphans(1.minute)
      QueueSpec.must(queue.find(dead)).state.should eq("failed")
    end
  end

  it "retries a failed job by hand with fresh attempts, and discards waiting ones" do
    QueueSpec.queue do |queue|
      id = QueueSpec.must(queue.enqueue(QueueSpec::Note.new("t", "x")))
      queue.retry_job(id).should be_false
      job = queue.claim("p", 1, QueueSpec::TYPES).first
      queue.discard_job(id).should be_false
      queue.fail(job, "p", "unreadable")
      queue.retry_job(id).should be_true
      QueueSpec.must(queue.find(id)).state.should eq("ready")
      QueueSpec.must(queue.find(id)).attempts.should eq(0)
      queue.discard_job(id, "not needed").should be_true
      QueueSpec.must(queue.find(id)).error.should eq("not needed")
    end
  end

  it "purges finished jobs past the retention window, but keeps failed ones" do
    clock = Punch::Spec.clock
    QueueSpec.queue do |queue|
      done = QueueSpec.must(queue.enqueue(QueueSpec::Note.new("t", "done")))
      failed = QueueSpec.must(queue.enqueue(QueueSpec::Note.new("t", "failed")))
      jobs = queue.claim("p", 2, QueueSpec::TYPES)
      queue.finish(jobs.find!(&.id.==(done)), "p")
      queue.fail(jobs.find!(&.id.==(failed)), "p", "broken")
      queue.purge(clock.now - 1.hour).should eq(0)
      clock.advance(2.hours)
      queue.purge(clock.now - 1.hour).should eq(1)
      queue.list.map(&.id).should eq([failed])
    end
  end

  it "cuts stored errors at a character boundary" do
    text = "é" * 5000
    cut = Punch::Job::Queue.cut(text)
    cut.valid_encoding?.should be_true
    cut.bytesize.should be <= Punch::Job::Queue::MAX_ERROR + 3
  end

  it "refuses a file of another layout and keeps it" do
    Punch::Spec.database do |database|
      Punch::Job::Queue.new(database)
      database.write(&.exec("PRAGMA user_version = 99"))
      expect_raises(Punch::Job::Queue::Error, "has queue layout 99; this binary needs 1") { Punch::Job::Queue.new(database) }
    end
  end

  it "claims every job exactly once from two processes on one file" do
    directory = File.tempname("punch-queue")
    Dir.mkdir(directory)
    begin
      path = File.join(directory, "queue.db")
      first = Punch::Job::Queue.new(Punch::Database.open(path))
      second = Punch::Job::Queue.new(Punch::Database.open(path))
      first.insert((1..400).map { |index| Punch::Job::Queue.entry(QueueSpec::Note.new("t", index.to_s), Time.utc) })
      claimed = Channel(Array(Int64)).new(8)
      8.times do |index|
        queue = index.even? ? first : second
        spawn do
          ids = [] of Int64
          loop do
            jobs = queue.claim("p#{index}", 7, QueueSpec::TYPES)
            break if jobs.empty?
            ids.concat(jobs.map(&.id))
          end
          claimed.send(ids)
        end
      end
      all = (1..8).flat_map { claimed.receive }
      all.size.should eq(400)
      all.uniq.size.should eq(400)
      first.database.close
      second.database.close
    ensure
      FileUtils.rm_rf(directory)
    end
  end
end

describe Punch::Job::Context do
  it "refuses a direct enqueue inside a write transaction" do
    QueueSpec.queue do |queue|
      Punch::Spec.database do |primary|
        expect_raises(Punch::Job::Queue::Error, "enqueued directly inside a write transaction") do
          primary.write { |_| queue.enqueue(QueueSpec::Note.new("t", "inside")) }
        end
        queue.list.should be_empty
      end
    end
  end
end

describe Punch::Job::Queue::Worker do
  context = Fiber::ExecutionContext::Parallel.new("punch-jobs-spec", 4)

  config = Punch::Job::Queue::Worker::Config.new(poll_interval: 10.seconds, heartbeat_interval: 50.milliseconds,
    stale_after: 200.milliseconds, shutdown_timeout: 2.seconds)

  run = ->(settings : Punch::Job::Queue::Worker::Config, block : Proc(Punch::Job::Queue, Punch::Database, Punch::Job::Queue::Worker, Nil)) do
    Punch::Spec.database do |primary|
      primary.write(&.exec("CREATE TABLE chain (tag TEXT NOT NULL, left INTEGER NOT NULL) STRICT"))
      QueueSpec.queue do |queue|
        worker = Punch::Job::Queue::Worker.new(queue, primary, Punch::Trace::Tracer.off, settings, context: context)
        worker.start
        begin
          block.call(queue, primary, worker)
        ensure
          worker.stop
        end
      end
    end
  end

  it "runs a job enqueued in its process at once, without waiting for the poll" do
    run.call(config, ->(queue : Punch::Job::Queue, _primary : Punch::Database, _worker : Punch::Job::Queue::Worker) do
      tag = QueueSpec.tag
      started = Time.instant
      queue.enqueue(QueueSpec::Note.new(tag, "hi"))
      Punch::Spec.eventually { QueueSpec.ran(tag).should eq(["hi:1"]) }
      (Time.instant - started).should be < 1.second
      nil
    end)
  end

  it "runs a delayed job when it comes due" do
    run.call(config, ->(queue : Punch::Job::Queue, _primary : Punch::Database, _worker : Punch::Job::Queue::Worker) do
      tag = QueueSpec.tag
      started = Time.instant
      queue.enqueue(QueueSpec::Note.new(tag, "later"), in: 300.milliseconds)
      sleep 150.milliseconds
      QueueSpec.ran(tag).should be_empty
      Punch::Spec.eventually { QueueSpec.ran(tag).should eq(["later:1"]) }
      # `run_at` is stored in whole milliseconds of the wall clock, so up to
      # 1 ms early by the monotonic clock.
      (Time.instant - started).should be >= 299.milliseconds
      nil
    end)
  end

  it "records retries, exceptions, discards, and parks unreadable payloads" do
    run.call(config, ->(queue : Punch::Job::Queue, _primary : Punch::Database, _worker : Punch::Job::Queue::Worker) do
      tag = QueueSpec.tag
      raised = QueueSpec.must(queue.enqueue(QueueSpec::Raises.new(tag)))
      gone = QueueSpec.must(queue.enqueue(QueueSpec::Gone.new(tag)))
      flaky = QueueSpec.must(queue.enqueue(QueueSpec::Flaky.new(tag, 2)))
      later = QueueSpec.must(queue.enqueue(QueueSpec::Later.new(tag)))
      broken = QueueSpec.must(queue.insert(Punch::Job::Queue::Entry.new("default", "QueueSpec::Note", 1, %({"tag":1}), 0, Time.utc, 10)))
      Punch::Spec.eventually do
        QueueSpec.must(queue.find(raised)).state.should eq("ready")
        QueueSpec.must(queue.find(gone)).state.should eq("discarded")
        QueueSpec.must(queue.find(broken)).state.should eq("incompatible")
        QueueSpec.must(queue.find(flaky)).state.should eq("ready")
        QueueSpec.must(queue.find(later)).error.should eq("rate limited")
      end
      QueueSpec.must(queue.find(later)).run_at.should be > Time.utc + 1.hour
      QueueSpec.must(QueueSpec.must(queue.find(raised)).error).should start_with("ArgumentError: bug in #{tag}")
      QueueSpec.must(queue.find(gone)).error.should eq("nothing left to do")
      QueueSpec.must(QueueSpec.must(queue.find(broken)).error).should contain("QueueSpec::Note version 1: the payload does not parse")
      QueueSpec.must(queue.find(broken)).attempts.should eq(0)
      QueueSpec.must(queue.find(flaky)).error.should eq("provider busy")
      nil
    end)
  end

  it "never runs more jobs at once than its concurrency" do
    run.call(Punch::Job::Queue::Worker::Config.new(concurrency: 3, poll_interval: 10.seconds), ->(queue : Punch::Job::Queue, _primary : Punch::Database, worker : Punch::Job::Queue::Worker) do
      tag = QueueSpec.tag
      queue.insert((1..9).map { Punch::Job::Queue.entry(QueueSpec::Slow.new(tag, 60), Time.utc) })
      most = 0
      deadline = Time.instant + 5.seconds
      until QueueSpec.ran(tag).count("end") == 9 || Time.instant > deadline
        most = {most, worker.running.size}.max
        sleep 5.milliseconds
      end
      QueueSpec.ran(tag).count("end").should eq(9)
      most.should eq(3)
      # In order: three start before any ends.
      QueueSpec.ran(tag).first(3).should eq(%w[start start start])
      nil
    end)
  end

  it "lets a job write to the primary database and enqueue a follow-up" do
    run.call(config, ->(queue : Punch::Job::Queue, primary : Punch::Database, _worker : Punch::Job::Queue::Worker) do
      tag = QueueSpec.tag
      queue.enqueue(QueueSpec::Chain.new(tag, 3))
      Punch::Spec.eventually do
        primary.read { |db| db.query_all("SELECT left FROM chain WHERE tag = ? ORDER BY left", tag, &.read(Int64)) }.should eq([0, 1, 2, 3])
      end
      id = QueueSpec.must(queue.enqueue(QueueSpec::Sneaky.new(tag)))
      Punch::Spec.eventually { queue.find(id).try(&.error).to_s.should contain("enqueued directly inside a write transaction") }
      nil
    end)
  end

  it "waits for running jobs when stopping and hands back those that outlast the timeout" do
    Punch::Spec.database do |primary|
      QueueSpec.queue do |queue|
        tag = QueueSpec.tag
        worker = Punch::Job::Queue::Worker.new(queue, primary, Punch::Trace::Tracer.off,
          Punch::Job::Queue::Worker::Config.new(shutdown_timeout: 100.milliseconds, poll_interval: 10.seconds), context: context)
        worker.start
        quick = QueueSpec.must(queue.enqueue(QueueSpec::Slow.new(tag, 30)))
        slow = QueueSpec.must(queue.enqueue(QueueSpec::Slow.new(tag, 600)))
        Punch::Spec.eventually { QueueSpec.ran(tag).count("start").should eq(2) }
        worker.stop
        QueueSpec.must(queue.find(quick)).state.should eq("done")
        row = QueueSpec.must(queue.find(slow))
        row.state.should eq("ready")
        row.attempts.should eq(0)
        queue.processes.should be_empty
        worker.alive?.should be_false
        # The job finishes after all, but its result is not recorded over the release.
        Punch::Spec.eventually { QueueSpec.ran(tag).count("end").should eq(2) }
        sleep 20.milliseconds
        QueueSpec.must(queue.find(slow)).state.should eq("ready")
      end
    end
  end

  it "picks up the jobs of a process that died" do
    run.call(config, ->(queue : Punch::Job::Queue, _primary : Punch::Database, _worker : Punch::Job::Queue::Worker) do
      tag = QueueSpec.tag
      # Another process claimed it and was never heard of again. Enqueued
      # for later, so this worker does not claim it first.
      id = QueueSpec.must(queue.enqueue(QueueSpec::Note.new(tag, "orphan"), in: 1.hour))
      queue.database.write { |db| db.exec("UPDATE punch_jobs SET state = 'running', claimed_by = 'gone', attempts = 1, run_at = 0 WHERE id = ?", id) }
      Punch::Spec.eventually(3.seconds) { QueueSpec.ran(tag).should eq(["orphan:2"]) }
      nil
    end)
  end

  it "continues the trace of the enqueue and writes one wide event per job" do
    Punch::Spec.database do |primary|
      QueueSpec.queue do |queue|
        events = Punch::Trace::MemoryEvents.new
        exporter = Punch::Trace::MemoryExporter.new
        tracer = Punch::Trace::Tracer.new(exporters: [exporter] of Punch::Trace::Exporter, events: [events] of Punch::Trace::EventSink)
        worker = Punch::Job::Queue::Worker.new(queue, primary, tracer, config, context: context)
        tag = QueueSpec.tag
        trace = Punch::Spec.trace { queue.enqueue(QueueSpec::Note.new(tag, "traced")) }
        worker.start
        begin
          Punch::Spec.eventually { events.events.size.should eq(1) }
        ensure
          worker.stop
        end
        event = events.events.first
        event.name.should eq("job QueueSpec::Note")
        event.trace_id.should eq(trace.root.trace_id)
        event["punch.job.type"].should eq("QueueSpec::Note")
        event["punch.job.attempt"].should eq(1)
        event["punch.job.outcome"].should eq("done")
        event["messaging.destination.name"].should eq("default")
      end
    end
  end
end

describe "Punch::Spec.perform_jobs" do
  it "runs due jobs and their follow-ups in the example's fiber" do
    Punch::Spec.db.write(&.exec("CREATE TABLE chain (tag TEXT NOT NULL, left INTEGER NOT NULL) STRICT"))
    tag = QueueSpec.tag
    Punch::Job::Queue.enqueue(QueueSpec::Chain.new(tag, 2))
    Punch::Spec.enqueued(QueueSpec::Chain).map(&.left).should eq([2])
    Punch::Spec.perform_jobs.map(&.outcome.to_s).should eq(%w[Done Done Done])
    Punch::Spec.db.read { |db| db.query_all("SELECT count(*) FROM chain WHERE tag = ?", tag, &.read(Int64)) }.should eq([3])
  end

  it "leaves jobs that are not due until the job clock moves" do
    clock = Punch::Spec.clock
    tag = QueueSpec.tag
    Punch::Job::Queue.enqueue(QueueSpec::Note.new(tag, "later"), in: 1.day)
    Punch::Spec.perform_jobs.should be_empty
    clock.advance(1.day)
    Punch::Spec.perform_jobs.map(&.type).should eq(["QueueSpec::Note"])
    QueueSpec.ran(tag).should eq(["later:1"])
  end
end
