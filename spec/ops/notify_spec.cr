require "../spec_helper"

module NotifySpec
  @[Punch::Job::Options(attempts: 1)]
  struct Fail
    include Punch::Job

    def initialize
    end

    def perform(job : Punch::Job::Context) : Punch::Job::Result
      raise ArgumentError.new("no luck")
    end
  end

  # Captures an exception raised in *source*, as the sink would.
  def self.raise_in(source : String, message : String = "missing") : Nil
    tracer = Punch::Trace::Tracer.new(events: [] of Punch::Trace::EventSink)
    root = tracer.start(source)
    begin
      raise KeyError.new(message)
    rescue ex
      root.error(ex)
    end
    root.finish
    Punch::Spec.ops.store([Punch::Ops::Sink.capture(root) || raise "nothing captured"])
  end

  # The events one run of `Ops::Notify` publishes.
  def self.notify : Array(Punch::Event)
    Punch::Spec.queue.enqueue(Punch::Ops::Notify.new)
    Punch::Spec.published { Punch::Spec.perform_jobs.map(&.outcome.to_s).should eq(%w[Done]) }
  end

  def self.storage(&)
    directory = File.tempname("punch-notify")
    Dir.mkdir(directory)
    yield directory
  ensure
    FileUtils.rm_rf(directory) if directory
  end
end

describe Punch::Ops::Notify do
  it "runs every minute and is published by Punch" do
    Punch::Job::Queue.tasks.find!(&.type.==("Punch::Ops::Notify")).schedule.to_s.should eq("every 00:01:00")
    graph = Punch::Subscribers.graph
    %w[Punch::Ops::ErrorOccurred Punch::Ops::JobsFailing Punch::Ops::BackupStale].each do |event|
      graph.find!(&.event.==(event)).publishers.should eq(["Punch::Ops::Notify"])
    end
  end

  it "does nothing where ops recording is off" do
    Punch::Ops.current?.should be_nil
    NotifySpec.notify.should be_empty
  end

  it "announces an error group once when it opens, and again when it recurs after being resolved" do
    store = Punch::Spec.ops
    NotifySpec.raise_in("GET /a")
    NotifySpec.raise_in("GET /a")
    occurred = NotifySpec.notify.map(&.as(Punch::Ops::ErrorOccurred))
    occurred.size.should eq(1)
    group = store.errors.first
    occurred.first.error_id.should eq(group.id)
    occurred.first.exception.should eq("KeyError")
    occurred.first.source.should eq("GET /a")
    occurred.first.occurrences.should eq(2)
    occurred.first.reopened?.should be_false
    # Recurring while open is the same trouble.
    NotifySpec.raise_in("GET /a")
    NotifySpec.notify.should be_empty
    # Reopened by hand: someone already knows.
    store.resolve(group.id)
    store.reopen(group.id)
    NotifySpec.notify.should be_empty
    store.resolve(group.id)
    NotifySpec.raise_in("GET /a")
    again = NotifySpec.notify.map(&.as(Punch::Ops::ErrorOccurred))
    again.map(&.error_id).should eq([group.id])
    again.first.reopened?.should be_true
  end

  it "announces at most ERRORS groups per run, the earliest first" do
    Punch::Spec.ops
    (Punch::Ops::Notify::ERRORS + 2).times { |index| NotifySpec.raise_in("GET /#{index}") }
    NotifySpec.notify.size.should eq(Punch::Ops::Notify::ERRORS)
    NotifySpec.notify.map(&.as(Punch::Ops::ErrorOccurred).source).should eq(["GET /#{Punch::Ops::Notify::ERRORS}", "GET /#{Punch::Ops::Notify::ERRORS + 1}"])
  end

  it "announces a job type failing once, until none of it has failed" do
    Punch::Spec.ops
    first = Punch::Spec.queue.enqueue(NotifySpec::Fail.new).should_not be_nil
    Punch::Spec.perform_jobs
    failing = NotifySpec.notify.compact_map(&.as?(Punch::Ops::JobsFailing))
    failing.map { |event| {event.job_type, event.failed, event.incompatible} }.should eq([{"NotifySpec::Fail", 1, 0}])
    second = Punch::Spec.queue.enqueue(NotifySpec::Fail.new).should_not be_nil
    Punch::Spec.perform_jobs
    NotifySpec.notify.compact_map(&.as?(Punch::Ops::JobsFailing)).should be_empty
    Punch::Spec.queue.discard_job(first)
    Punch::Spec.queue.discard_job(second)
    NotifySpec.notify.compact_map(&.as?(Punch::Ops::JobsFailing)).should be_empty
    Punch::Spec.ops.notices("jobs ").should be_empty
    Punch::Spec.queue.enqueue(NotifySpec::Fail.new)
    Punch::Spec.perform_jobs
    NotifySpec.notify.compact_map(&.as?(Punch::Ops::JobsFailing)).map(&.failed).should eq([1])
  end

  it "finds a lagging replica and a stale or failed restore check, once each" do
    NotifySpec.storage do |directory|
      config = Punch::Backup::Config.from({"PUNCH_BACKUP_URL" => "file:///srv/backups"}, [] of String)
      litestream = Punch::Backup::Litestream.new(config, directory, %w[primary])
      now = Time.utc.at_beginning_of_second
      File.write(litestream.database_path("primary"), "")
      File.write("#{litestream.database_path("primary")}-wal", "")
      File.touch("#{litestream.database_path("primary")}-wal", now - 1.second)
      monitor = Punch::Backup::Monitor.new(litestream, %w[primary], "production", now: now - 30.hours)
      monitor.measure(now + 10.minutes)
      started, ended = Punch::Ops::Notify.stale([] of String, now, monitor)
      ended.should be_empty
      started.map(&.first).should eq(["backup lag primary", "backup verification"])
      lagging = started[0][1]
      {lagging.reason, lagging.database, lagging.lag_seconds}.should eq({"lagging", "primary", 601})
      started[1][1].reason.should eq("unverified")
      noticed = started.map(&.first)
      Punch::Ops::Notify.stale(noticed, now, monitor)[0].should be_empty

      # Nothing left to replicate (no socket here to say it synced), and
      # the last check failed.
      File.delete(litestream.database_path("primary"))
      File.delete("#{litestream.database_path("primary")}-wal")
      monitor.measure(now)
      File.write(File.join(directory, Punch::Backup::VerificationStatus::FILE),
        %({"passed": false, "started_at": "#{(now - 1.hour).to_rfc3339}", "finished_at": "#{now.to_rfc3339}", "last_passed_at": null, "problems": ["primary: gone"]}))
      started, ended = Punch::Ops::Notify.stale(noticed, now, monitor)
      started.should be_empty
      ended.should eq(["backup lag primary"])
      Punch::Ops::Notify.stale([] of String, now, monitor)[0].map { |_, event| event.reason }.should eq(["verification_failed"])
    end
    # Nothing replicated, nothing to watch.
    Punch::Ops::Notify.stale(["backup verification"], Time.utc, nil).should eq({[] of {String, Punch::Ops::BackupStale}, [] of String})
  end
end
