require "../spec_helper"

module RecoverySpec
  T0 = Time.utc(2026, 10, 14, 4, 0, 0)

  def self.storage(& : String ->) : Nil
    directory = File.tempname("punch-recovery")
    Dir.mkdir(directory)
    begin
      yield directory
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  def self.entry(primary : Punch::Database, key : String, created : Time, handed_over : Time?) : Int64
    primary.write do |writer|
      writer.exec(<<-SQL, key, "Mail::#{key}", created.to_unix_ms, handed_over.try(&.to_unix_ms)).last_insert_id
        INSERT INTO punch_outbox (key, queue, type, version, payload, priority, run_at, max_attempts, created_at, handed_over_at)
        VALUES (?, 'default', ?, 1, '{}', 0, 0, 10, ?, ?)
        SQL
    end
  end

  def self.job(queue : Punch::Database, type : String, state : String, unique_key : String?, enqueued : Time,
               finished : Time? = nil, attempts : Int32 = 1) : Int64
    queue.write do |writer|
      writer.exec(<<-SQL, type, state, enqueued.to_unix_ms, attempts.to_i64, unique_key, enqueued.to_unix_ms, finished.try(&.to_unix_ms)).last_insert_id
        INSERT INTO punch_jobs (queue, type, version, payload, state, priority, run_at, attempts, max_attempts,
          unique_key, enqueued_at, finished_at)
        VALUES ('default', ?, 1, '{}', ?, 0, ?, ?, 10, ?, ?, ?)
        SQL
    end
  end

  def self.state(queue : Punch::Database, id : Int64) : {String, Int64}
    queue.read(&.query_one?("SELECT state, attempts FROM punch_jobs WHERE id = ?", id) { |row| {row.read(String), row.read(Int64)} }).should_not be_nil
  end

  def self.notes(path : String) : Int64
    Punch::Backup::Restorer.open(path, &.read(&.query_one?("SELECT count(*) FROM notes", &.read(Int64)))).should_not be_nil
  end

  # Storage with primary.db (an outbox, notes, and one entry handed over
  # without a job), queue.db, and ops.db, replicated by real Litestream to
  # a file replica until all three reached it. The files are closed and
  # Litestream stopped after the block, as for a restore.
  def self.replicated(directory : String, & : Punch::Backup::Litestream, Punch::Databases ->) : Punch::Backup::Litestream
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
      synced(litestream)
      yield litestream, databases
    ensure
      databases.close
      sidecar.stop
    end
    litestream
  end

  # Waits until every replica has an upload.
  def self.synced(litestream : Punch::Backup::Litestream) : Nil
    Punch::Spec.eventually(15.seconds) do
      replicas = litestream.replicas.should_not be_nil
      replicas.size.should eq(litestream.names.size)
      replicas.each(&.last_sync_at.should_not(be_nil))
    end
  end

  def self.litestream? : Bool
    !Process.find_executable("litestream").nil?
  end
end

describe Punch::Backup::Recovery do
  it "applies the confirmed reconciliation and ends recovery mode" do
    RecoverySpec.storage do |storage|
      databases = Punch::Databases.open(storage, %w[primary queue])
      begin
        primary = databases.primary
        queue = databases["queue"]
        Punch::Migrations::Schema.load(primary, Punch::Job::Outbox.sql, "outbox")
        Punch::Job::Queue.new(queue)
        point = RecoverySpec::T0
        lost = RecoverySpec.entry(primary, "lost", point - 2.seconds, point - 1.second)
        newer = RecoverySpec.job(queue, "Mail::newer", "running", "outbox:newer", point + 2.seconds)
        sent = RecoverySpec.job(queue, "Mail::sent", "done", "outbox:sent", point + 1.second, point + 2.seconds)
        RecoverySpec.entry(primary, "after", point - 1.minute, point - 1.minute)
        after = RecoverySpec.job(queue, "Mail::after", "done", "outbox:after", point - 1.minute, point + 1.second)
        RecoverySpec.entry(primary, "running", point - 5.minutes, point - 5.minutes)
        running = RecoverySpec.job(queue, "Mail::running", "running", "outbox:running", point - 5.minutes, attempts: 3)
        found = Punch::Backup::Reconciliation.compare(primary, queue, primary_point: point, queue_point: point,
          retention: 72.hours)
        found.discard.map(&.id).should eq([newer])
        found.orphaned.map(&.id).should eq([sent])
        found.rerun.map(&.id).should eq([after])
        found.interrupted.map(&.id).should eq([running])
        queue.write do |db|
          db.exec("INSERT INTO punch_job_processes (id, kind, pid, host, queues, started_at, heartbeat_at) VALUES ('old', 'serve', 1, 'h', '*', 0, ?)", point.to_unix_ms)
        end
        restored_at = point + 1.hour
        report = Punch::Backup::Recovery::Report.new(restored_at: restored_at, requested: nil, aligned_at: nil,
          files: [Punch::Backup::Restorer::Plan.new("primary", "0000000000000002", point, 2, 100_i64)],
          replaced: nil, reconciliation: found)
        report.save(File.join(storage, Punch::Backup::Recovery::FILE))
        # Read back as saved, the lists intact.
        Punch::Backup::Recovery.pending?(storage).should be_true
        Punch::Backup::Recovery.read(storage).try(&.reconciliation.try(&.interrupted.map(&.id))).should eq([running])
        # Changed by hand meanwhile: left as it is.
        Punch::Job::Queue.new(queue).discard_job(newer).should be_false
        queue.write(&.exec("UPDATE punch_jobs SET state = 'ready' WHERE id = ?", newer))
        Punch::Job::Queue.new(queue).discard_job(newer, "by hand").should be_true
      ensure
        databases.close
      end

      Punch::Spec.clock(restored_at + 1.minute)
      confirmed = Punch::Backup::Recovery.confirm(storage)
      confirmed = confirmed.should be_a(Punch::Backup::Recovery::Report)
      confirmed.confirmed_at.should eq(restored_at + 1.minute)
      confirmed.applied.should eq({"discard" => 0, "rerun" => 1, "interrupted" => 1, "reenqueue" => 1})
      Punch::Backup::Recovery.pending?(storage).should be_false
      Punch::Backup::Recovery.last(storage).try(&.applied).should eq(confirmed.applied)

      databases = Punch::Databases.open(storage, %w[primary queue])
      begin
        queue = databases["queue"]
        RecoverySpec.state(queue, newer).should eq({"discarded", 1})
        RecoverySpec.state(queue, sent).should eq({"done", 1})
        RecoverySpec.state(queue, after).should eq({"ready", 0})
        RecoverySpec.state(queue, running).should eq({"ready", 2})
        queue.read(&.query_one?("SELECT count(*) FROM punch_job_processes", &.read(Int64))).should eq(0)
        # The relay hands the lost entry over again.
        databases.primary.read(&.query_all("SELECT handed_over_at FROM punch_outbox WHERE id = ?", lost, &.read(Int64?))).should eq([nil])
        Punch::Job::Outbox::Relay.new(databases.primary, Punch::Job::Queue.new(queue)).drain.should eq(1)
        queue.read(&.query_one?("SELECT state FROM punch_jobs WHERE unique_key = 'outbox:lost'", &.read(String))).should eq("ready")
      ensure
        databases.close
      end
      refused = Punch::Backup::Recovery.confirm(storage).should be_a(Punch::Backup::Recovery::Refused)
      refused.code.should eq("not_recovering")
    end
  end

  it "holds background work back until the restore is confirmed" do
    RecoverySpec.storage do |storage|
      ran = Channel(Nil).new(1)
      # No restore waiting: runs at once.
      Punch::Backup::Recovery::Hold.new(storage).start { ran.send(nil) }
      ran.receive?.should be_nil
      File.write(File.join(storage, Punch::Backup::Recovery::FILE), "{}")
      hold = Punch::Backup::Recovery::Hold.new(storage, 20.milliseconds)
      started = Atomic(Int32).new(0)
      hold.start { started.add(1) }
      hold.held?.should be_true
      sleep 100.milliseconds
      started.get.should eq(0)
      registry = Punch::Metrics::Registry.new
      hold.observe(registry)
      Punch::Spec.metrics(registry).value("punch.backup.recovery").should eq(1)
      File.delete(File.join(storage, Punch::Backup::Recovery::FILE))
      Punch::Spec.eventually(2.seconds) { started.get.should eq(1) }
      hold.held?.should be_false
      Punch::Spec.metrics(registry).value("punch.backup.recovery").should eq(0)
      hold.stop

      # Stopped before the confirmation: never started.
      File.write(File.join(storage, Punch::Backup::Recovery::FILE), "{}")
      stopped = Punch::Backup::Recovery::Hold.new(storage, 20.milliseconds)
      stopped.start { started.add(1) }
      stopped.stop
      File.delete(File.join(storage, Punch::Backup::Recovery::FILE))
      sleep 100.milliseconds
      started.get.should eq(1)
    end
  end

  it "refuses while the app or a Litestream has the storage, and after a swap that stopped halfway" do
    RecoverySpec.storage do |directory|
      config = Punch::Backup::Config.from({"PUNCH_BACKUP_URL" => "file://#{directory}/replica"}, [] of String)
      app = File.join(directory, "app")
      Dir.mkdir(app)
      Punch::Backup::Recovery.share(app).should be_true
      Punch::Backup::Recovery.share(app).should be_true
      litestream = Punch::Backup::Litestream.new(config, app, %w[primary])
      refused = Punch::Backup::Recovery.restore(litestream, 72.hours).should be_a(Punch::Backup::Recovery::Refused)
      refused.code.should eq("app_running")

      orphan = File.join(directory, "orphan")
      Dir.mkdir(orphan)
      litestream = Punch::Backup::Litestream.new(config, orphan, %w[primary])
      File.open(litestream.lock_path, "a") do |file|
        file.flock_exclusive
        refused = Punch::Backup::Recovery.restore(litestream, 72.hours).should be_a(Punch::Backup::Recovery::Refused)
        refused.code.should eq("litestream_running")
      end
      # Nothing to restore from: refused, nothing replaced, no scratch left.
      File.write(File.join(orphan, "primary.db"), "")
      refused = Punch::Backup::Recovery.restore(litestream, 72.hours).should be_a(Punch::Backup::Recovery::Refused)
      refused.code.should eq("restore_failed")
      Dir.children(orphan).sort.should eq(%w[litestream.lock primary.db punch.lock])

      Punch::Backup::Recovery.incomplete(orphan).should be_nil
      File.write(File.join(orphan, Punch::Backup::Recovery::INCOMPLETE), {replaced: "/x/replaced-1"}.to_json)
      Punch::Backup::Recovery.incomplete(orphan).to_s.should contain("run punch restore again; the files it had replaced are in /x/replaced-1")
    end
  end

  it "restores every file into the storage, moving the replaced ones aside, and starts recovery mode" do
    pending! "litestream is not installed" unless RecoverySpec.litestream?
    RecoverySpec.storage do |directory|
      litestream = RecoverySpec.replicated(directory) do |_, databases|
        databases.primary.write { |db| db.exec("INSERT INTO notes (body) VALUES ('last')") }
        sleep 2.seconds
      end
      storage = litestream.storage
      File.write(File.join(storage, "cache.db"), "stale")
      # Lost since: the restore brings the replica's state back.
      File.delete(File.join(storage, "primary.db"))

      planned = Punch::Backup::Recovery.plan(litestream).should be_a({Time?, Array(Punch::Backup::Restorer::Plan)})
      planned[1].map(&.name).should eq(%w[primary queue ops])
      Dir.children(storage).should_not contain("restore-plan")

      report = Punch::Backup::Recovery.restore(litestream, 72.hours).should be_a(Punch::Backup::Recovery::Report)
      report.files.map(&.name).should eq(%w[primary queue ops])
      report.aligned_at.should be_nil
      RecoverySpec.notes(File.join(storage, "primary.db")).should eq(51)
      found = report.reconciliation.should_not be_nil
      found.reenqueue.map(&.key).should eq(%w[lost])
      replaced = report.replaced.should_not be_nil
      Dir.children(replaced).should contain("cache.db")
      Dir.children(replaced).should contain("queue.db")
      Dir.children(replaced).should contain(".queue.db-litestream")
      Dir.children(storage).should_not contain("cache.db")
      Dir.children(storage).select(&.starts_with?("restore-")).should be_empty
      Punch::Backup::Recovery.incomplete(storage).should be_nil
      Punch::Backup::Recovery.read(storage).try(&.files.map(&.max_txid)).should eq(report.files.map(&.max_txid))
      Punch::Backup::Restorer.integrity(File.join(storage, "queue.db")).should be_empty

      # A second restore while the first waits replaces its report too.
      again = Punch::Backup::Recovery.restore(litestream, 72.hours).should be_a(Punch::Backup::Recovery::Report)
      Dir.children(again.replaced.should_not(be_nil)).should contain(Punch::Backup::Recovery::FILE)
    end
  end

  it "restores to a time asked for, and replicates the restored files onward" do
    pending! "litestream is not installed" unless RecoverySpec.litestream?
    RecoverySpec.storage do |directory|
      at = Time.utc
      litestream = RecoverySpec.replicated(directory) do |_, databases|
        sleep 1.second
        at = Time.utc
        sleep 2.seconds
        databases.primary.write { |db| 10.times { db.exec("INSERT INTO notes (body) VALUES ('later')") } }
        sleep 2.seconds
      end
      storage = litestream.storage
      planned = Punch::Backup::Recovery.plan(litestream, at: at).should be_a({Time?, Array(Punch::Backup::Restorer::Plan)})
      planned[1].each(&.point.should(be <= at))
      report = Punch::Backup::Recovery.restore(litestream, 72.hours, at: at).should be_a(Punch::Backup::Recovery::Report)
      report.requested.should eq(at)
      RecoverySpec.notes(File.join(storage, "primary.db")).should eq(50)

      # Litestream continues the replica from the restored file: a restore
      # of the latest point has what was written after it, not what the
      # restore went back from.
      databases = Punch::Databases.open(storage, %w[primary queue ops])
      sidecar = Punch::Backup::Sidecar.new(litestream, output: :close)
      sidecar.start
      begin
        RecoverySpec.synced(litestream)
        databases.primary.write { |db| db.exec("INSERT INTO notes (body) VALUES ('after the restore')") }
        sleep 2.seconds
      ensure
        databases.close
        sidecar.stop
      end
      latest = Punch::Backup::Recovery.restore(litestream, 72.hours).should be_a(Punch::Backup::Recovery::Report)
      latest.files.size.should eq(3)
      RecoverySpec.notes(File.join(storage, "primary.db")).should eq(51)
    end
  end
end
