require "../spec_helper"

module VerificationSpec
  T0 = Time.utc(2026, 10, 14, 4, 0, 0)

  def self.primary(outbox : Bool = true, & : Punch::Database ->) : Nil
    database = Punch::Database.memory(name: "primary")
    begin
      Punch::Migrations::Schema.load(database, Punch::Job::Outbox.sql, "outbox") if outbox
      yield database
    ensure
      database.close
    end
  end

  def self.queue(& : Punch::Database ->) : Nil
    database = Punch::Database.memory(name: "queue")
    begin
      Punch::Job::Queue.new(database)
      yield database
    ensure
      database.close
    end
  end

  def self.storage(& : String ->) : Nil
    directory = File.tempname("punch-verification")
    Dir.mkdir(directory)
    begin
      yield directory
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  def self.entry(primary : Punch::Database, key : String, created : Time, handed_over : Time?) : Nil
    primary.write do |writer|
      writer.exec(<<-SQL, key, "Mail::#{key}", created.to_unix_ms, handed_over.try(&.to_unix_ms))
        INSERT INTO punch_outbox (key, queue, type, version, payload, priority, run_at, max_attempts, created_at, handed_over_at)
        VALUES (?, 'default', ?, 1, '{}', 0, 0, 10, ?, ?)
        SQL
    end
  end

  def self.job(queue : Punch::Database, type : String, state : String, unique_key : String?, enqueued : Time,
               finished : Time? = nil) : Int64
    queue.write do |writer|
      writer.exec(<<-SQL, type, state, enqueued.to_unix_ms, unique_key, enqueued.to_unix_ms, finished.try(&.to_unix_ms)).last_insert_id
        INSERT INTO punch_jobs (queue, type, version, payload, state, priority, run_at, attempts, max_attempts,
          unique_key, enqueued_at, finished_at)
        VALUES ('default', ?, 1, '{}', ?, 0, ?, 1, 10, ?, ?, ?)
        SQL
    end
  end

  # Storage with primary.db (an outbox and one entry handed over without
  # a job), queue.db, and ops.db, replicated by real Litestream to a file
  # replica until all three reached it.
  def self.replicated(directory : String, & : Punch::Backup::Litestream, String, Punch::Databases ->) : Nil
    storage = File.join(directory, "storage")
    Dir.mkdir(storage)
    databases = Punch::Databases.open(storage, %w[primary queue ops])
    Punch::Migrations::Schema.load(databases.primary, Punch::Job::Outbox.sql, "outbox")
    databases.primary.write do |writer|
      writer.exec("CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT NOT NULL) STRICT")
      50.times { |i| writer.exec("INSERT INTO notes (body) VALUES (?)", "note #{i}") }
    end
    Punch::Job::Queue.new(databases["queue"])
    databases["ops"].write(&.exec("CREATE TABLE things (id INTEGER PRIMARY KEY) STRICT"))
    entry(databases.primary, "lost", Time.utc - 1.minute, Time.utc - 1.minute)
    config = Punch::Backup::Config.from({"PUNCH_BACKUP_URL" => "file://#{directory}/replica"}, [] of String)
    litestream = Punch::Backup::Litestream.new(config, storage, %w[primary queue ops])
    sidecar = Punch::Backup::Sidecar.new(litestream, output: :close)
    sidecar.start
    begin
      Punch::Spec.eventually(15.seconds) do
        replicas = litestream.replicas.should_not be_nil
        replicas.size.should eq(3)
        replicas.each(&.last_sync_at.should_not(be_nil))
      end
      yield litestream, storage, databases
    ensure
      databases.close
      sidecar.stop
    end
  end
end

describe Punch::Backup::Reconciliation do
  it "proposes what to hand over again, discard, run again, and mark interrupted" do
    VerificationSpec.primary do |primary|
      VerificationSpec.queue do |queue|
        primary_point = VerificationSpec::T0
        queue_point = VerificationSpec::T0 + 3.seconds
        # In both: nothing to do.
        VerificationSpec.entry(primary, "both", primary_point - 10.minutes, primary_point - 10.minutes)
        VerificationSpec.job(queue, "Mail::both", "done", "outbox:both", primary_point - 10.minutes, primary_point - 9.minutes)
        # Handed over, the queue lost the job.
        VerificationSpec.entry(primary, "lost", primary_point - 2.seconds, primary_point - 1.second)
        # Jobs for Commands the primary does not have: unfinished, finished.
        newer = VerificationSpec.job(queue, "Mail::newer", "ready", "outbox:newer", primary_point + 2.seconds)
        sent = VerificationSpec.job(queue, "Mail::sent", "done", "outbox:sent", primary_point + 1.second, primary_point + 2.seconds)
        # Finished after the primary's point, or within the margin before it.
        after = VerificationSpec.job(queue, "Punch::Job::Queue::Purge", "done", "recurring:purge", primary_point, primary_point + 1.second)
        VerificationSpec.entry(primary, "close", primary_point - 1.minute, primary_point - 1.minute)
        close = VerificationSpec.job(queue, "Mail::close", "discarded", "outbox:close", primary_point - 1.minute, primary_point - 3.seconds)
        VerificationSpec.job(queue, "Punch::Job::Queue::Purge", "done", "recurring:earlier", primary_point - 1.hour, primary_point - 1.hour)
        # Running at the queue's point; the check's own job is left out.
        VerificationSpec.entry(primary, "running", primary_point - 5.minutes, primary_point - 5.minutes)
        running = VerificationSpec.job(queue, "Mail::running", "running", "outbox:running", primary_point - 5.minutes)
        own = VerificationSpec.job(queue, "Punch::Backup::Verify", "running", "recurring:verify", primary_point)
        # Older than the retention window: the entry, or the job, may be purged.
        VerificationSpec.job(queue, "Mail::purged", "ready", "outbox:purged", primary_point - 100.hours)
        VerificationSpec.entry(primary, "old", queue_point - 80.hours, queue_point - 80.hours)
        # Not handed over yet: the relay does it.
        VerificationSpec.entry(primary, "pending", primary_point - 1.second, nil)

        found = Punch::Backup::Reconciliation.compare(primary, queue, primary_point: primary_point,
          queue_point: queue_point, retention: 72.hours, except: own)
        found.reenqueue.map(&.key).should eq(%w[lost])
        found.discard.map(&.id).should eq([newer])
        found.orphaned.map(&.id).should eq([sent])
        found.rerun.map(&.id).should eq([after, close])
        found.interrupted.map(&.id).should eq([running])
        found.pending.should eq(1)
        found.counts.should eq({"reenqueue" => 1, "discard" => 1, "orphaned" => 1, "rerun" => 2, "interrupted" => 1, "pending" => 1})
        found.messages.first.should eq("1 to hand over again (handed over, no job): Mail::lost (outbox 2)")
        found.empty?.should be_false
      end
    end
  end

  it "compares only finished and running jobs when the primary has no outbox" do
    VerificationSpec.primary(outbox: false) do |primary|
      VerificationSpec.queue do |queue|
        ready = VerificationSpec.job(queue, "Export", "ready", nil, VerificationSpec::T0 + 1.second)
        done = VerificationSpec.job(queue, "Export", "done", nil, VerificationSpec::T0, VerificationSpec::T0 + 1.second)
        found = Punch::Backup::Reconciliation.compare(primary, queue, primary_point: VerificationSpec::T0,
          queue_point: VerificationSpec::T0, retention: 72.hours)
        found.outbox?.should be_false
        found.discard.should be_empty
        found.rerun.map(&.id).should eq([done])
        found.messages.first.should start_with("no outbox in the primary")
        ready.should be > 0
      end
    end
  end
end

describe Punch::Backup::Restorer do
  it "aligns the files to the earliest end only when that replica is behind" do
    plan = ->(name : String, point : Time) { Punch::Backup::Restorer::Plan.new(name, "0000000000000009", point, 3, 900_i64) }
    quiet = [plan.call("primary", VerificationSpec::T0 + 24.seconds), plan.call("ops", VerificationSpec::T0)]
    Punch::Backup::Restorer.target(quiet).should be_nil
    behind = [plan.call("primary", VerificationSpec::T0 + 30.seconds), plan.call("queue", VerificationSpec::T0 + 29.seconds), plan.call("ops", VerificationSpec::T0)]
    Punch::Backup::Restorer::BEHIND.should eq(25.seconds)
    Punch::Backup::Restorer.target(behind).should eq(VerificationSpec::T0)
    Punch::Backup::Restorer.target(quiet, behind: 20.seconds).should eq(VerificationSpec::T0)
  end

  it "takes Litestream's error line as the reason" do
    Punch::Backup::Restorer.reason("time=… level=INFO msg=x\nError: no matching backup files available\n").should eq("no matching backup files available")
    Punch::Backup::Restorer.reason("panic: oops\n").should eq("panic: oops")
    Punch::Backup::Restorer.reason("").should eq("exited without a message")
  end
end

describe Punch::Backup::Verification do
  it "leaves the larger of a gigabyte and a tenth of the filesystem free" do
    gib = 1_i64 << 30
    Punch::Backup::Verification.space_problem(gib, 100_i64 * gib, 20_i64 * gib).should be_nil
    Punch::Backup::Verification.space_problem(gib, 100_i64 * gib, 10_i64 * gib).to_s.should contain("not enough space")
    Punch::Backup::Verification.space_problem(100_i64, 4_i64 * gib, gib).to_s.should contain("1024.0 MB must stay free")
  end

  it "restores every file, checks it, and runs the reconciliation as a dry run" do
    unless Process.find_executable("litestream")
      pending! "litestream is not installed"
    end
    VerificationSpec.storage do |directory|
      VerificationSpec.replicated(directory) do |litestream, storage, databases|
        # The primary's replica ends seconds after the others.
        restorer = Punch::Backup::Restorer.new(litestream)
        point = ->(name : String) { restorer.plan(name, to: File.join(directory, "#{name}.plan.db")).point }
        sleep 3.seconds
        VerificationSpec.entry(databases.primary, "late", Time.utc, Time.utc)
        Punch::Spec.eventually(10.seconds) { point.call("primary").should be > point.call("queue") + 2.seconds }

        # Quiet files are not behind: each file is restored to its latest.
        verification = Punch::Backup::Verification.run(litestream, 72.hours)
        verification.problems.should be_empty
        verification.passed?.should be_true
        verification.aligned_at.should be_nil
        verification.files.map(&.name).should eq(%w[primary queue ops])
        verification.files.each(&.ok?.should(be_true))
        found = verification.reconciliation.should_not be_nil
        found.reenqueue.map(&.key).should eq(%w[lost late])
        verification.messages.should contain("  2 to hand over again (handed over, no job): Mail::lost (outbox 1), Mail::late (outbox 2)")
        # The copies are gone; the result is kept.
        Dir.children(storage).select(&.starts_with?("verify-")).should be_empty
        status = Punch::Backup::VerificationStatus.read(storage).should_not be_nil
        status.passed?.should be_true
        status.last_passed_at.should eq(verification.finished_at.at_beginning_of_second)
        status.reconciliation.try(&.["reenqueue"]).should eq(2)

        # With the queue's replica behind, every file goes back to its end,
        # and the late write is not restored.
        aligned = Punch::Backup::Verification.run(litestream, 72.hours, behind: 2.seconds)
        aligned.problems.should be_empty
        at = aligned.aligned_at.should_not be_nil
        aligned.files.each(&.plan.point.should(be <= at))
        aligned.reconciliation.should_not be_nil
        aligned.reconciliation.try(&.reenqueue.map(&.key)).should eq(%w[lost])

        # A replica that cannot be restored fails the check; the last pass is kept.
        empty = Punch::Backup::Config.from({"PUNCH_BACKUP_URL" => "file://#{directory}/nothing"}, [] of String)
        failed = Punch::Backup::Verification.run(Punch::Backup::Litestream.new(empty, storage, %w[primary queue]), 72.hours)
        failed.passed?.should be_false
        failed.problems.first.should start_with("primary: ")
        failed.reconciliation.should be_nil
        again = Punch::Backup::VerificationStatus.read(storage).should_not be_nil
        again.passed?.should be_false
        again.last_passed_at.should eq(aligned.finished_at.at_beginning_of_second)
        monitor = Punch::Backup::Monitor.new(litestream, %w[primary], "production")
        monitor.verification_age(aligned.finished_at.at_beginning_of_second + 1.hour).should eq(1.hour)
      end
    end
  end

  it "runs every night as a job, recording the result on its wide event" do
    Punch::Job::Queue.tasks.find!(&.type.==("Punch::Backup::Verify")).schedule.to_s.should eq("cron 0 4 * * *")
    Punch::Job::Queue::Registry.descriptions.find!(&.type.==("Punch::Backup::Verify")).priority.should eq(-100)
    # Nothing replicated: nothing to check.
    Punch::Backup.current = nil
    Punch::Spec.queue.enqueue(Punch::Backup::Verify.new)
    Punch::Spec.perform_jobs.map(&.outcome.to_s).should eq(%w[Done])
    unless Process.find_executable("litestream")
      pending! "litestream is not installed"
    end
    VerificationSpec.storage do |directory|
      VerificationSpec.replicated(directory) do |litestream, _, _|
        store = Punch::Spec.ops
        Punch::Backup.current = litestream
        begin
          Punch::Spec.queue.enqueue(Punch::Backup::Verify.new)
          Punch::Spec.perform_jobs.map(&.outcome.to_s).should eq(%w[Done])
          fields = store.records(kind: "job").map { |record| JSON.parse(record.fields) }.find!(&.["punch.backup.verify.passed"]?)
          fields["punch.backup.verify.passed"].as_bool.should be_true
          fields["punch.backup.verify.files"].should eq(3)
          fields["punch.backup.reconcile.reenqueue"].should eq(1)

          empty = Punch::Backup::Config.from({"PUNCH_BACKUP_URL" => "file://#{directory}/nothing"}, [] of String)
          Punch::Backup.current = Punch::Backup::Litestream.new(empty, litestream.storage, %w[primary])
          Punch::Spec.queue.enqueue(Punch::Backup::Verify.new)
          Punch::Spec.perform_jobs.map(&.outcome.to_s).should eq(%w[Done])
          error = store.errors.find!(&.exception.==("Punch::Backup::VerificationFailed"))
          error.source.should eq("punch.backup.verify")
          error.message.to_s.should start_with("primary: ")
        ensure
          Punch::Backup.current = nil
        end
      end
    end
  end
end

describe Punch::Backup::Heartbeat do
  it "writes to each replicated file that has been quiet, and is left out of the schema" do
    VerificationSpec.storage do |directory|
      databases = Punch::Databases.open(directory, %w[primary queue])
      begin
        heartbeat = Punch::Backup::Heartbeat.new([databases.primary, databases["queue"]])
        databases.primary.write(&.exec("CREATE TABLE notes (id INTEGER PRIMARY KEY) STRICT"))
        now = Time.utc
        # The queue's file last changed a minute ago, the primary's just now.
        queue = databases["queue"].path
        [queue, "#{queue}-wal"].each { |path| File.touch(path, now - 1.minute) if File.exists?(path) }
        heartbeat.beat(now).should eq(%w[queue])
        later = now + 1.minute
        heartbeat.beat(later).should eq(%w[primary queue])
        databases.primary.read(&.query_all("SELECT at FROM _punch_heartbeat", &.read(Int64))).should eq([later.to_unix_ms])
        Punch::Migrations::Schema.dump(databases.primary).should contain("CREATE TABLE notes")
        Punch::Migrations::Schema.dump(databases.primary).should_not contain("_punch_heartbeat")
      ensure
        databases.close
      end
      # Closed: skipped, nothing reported.
      heartbeat = Punch::Backup::Heartbeat.new([databases.primary])
      heartbeat.beat(Time.utc + 1.minute).should be_empty
    end
  end
end
