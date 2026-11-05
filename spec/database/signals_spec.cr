require "../spec_helper"

private def fill(db : Punch::Database, rows : Int32) : Nil
  db.write do |writer|
    rows.times { writer.exec("INSERT INTO t (body) VALUES (?)", "x" * 3000) }
  end
end

private def create(db : Punch::Database) : Nil
  db.write { |writer| writer.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, body TEXT NOT NULL) STRICT") }
end

describe Punch::Database::Signals do
  it "counts writes waiting for the writer" do
    Punch::Spec.database do |db|
      registry = Punch::Metrics::Registry.new
      db.observe(registry)
      release = Channel(Nil).new
      started = Channel(Nil).new
      done = Channel(Nil).new
      spawn do
        db.write { |_writer| started.send(nil); release.receive }
        done.send(nil)
      end
      started.receive
      3.times { spawn { db.write(&.exec("SELECT 1")); done.send(nil) } }
      Punch::Spec.eventually do
        Punch::Spec.metrics(registry).value("db.client.connection.pending_requests",
          "db.namespace": "memory", "db.client.connection.pool.name": "memory writer").should eq(3)
      end
      release.send(nil)
      4.times { done.receive }
      Punch::Spec.metrics(registry).value("db.client.connection.pending_requests").should eq(0)
    end
  end

  it "checkpoints after checkpoint_pages frames, timed, and reports the WAL" do
    config = Punch::Database::Config.new(readers: 2, checkpoint_pages: 50)
    Punch::Spec.database(file: true, config: config) do |db|
      registry = Punch::Metrics::Registry.new
      db.observe(registry)
      create(db)
      fill(db, 10)
      metrics = Punch::Spec.metrics(registry)
      metrics.value("punch.db.wal.frames", "db.namespace": "spec").should be > 0
      metrics.has?("punch.db.checkpoint.duration").should be_false
      db.signals.checkpoints.should eq({0, 0})

      fill(db, 40)
      # The writer checkpoints after answering the write.
      Punch::Spec.eventually { db.signals.checkpoints.should eq({1, 0}) }
      metrics = Punch::Spec.metrics(registry)
      metrics.value("punch.db.wal.frames").should eq(0)
      metrics.value("punch.db.wal.size").should be > 50 * 4096
      metrics.value("punch.db.size").should eq(File.size(db.path))
      checkpoints = metrics.distribution("punch.db.checkpoint.duration", "punch.db.checkpoint.complete": true)
      checkpoints.count.should eq(1)
      checkpoints.sum.should be > 0.0
      checkpoints.bounds.should eq(Punch::Metrics::DURATION_BOUNDS)
    end
  end

  it "reports a checkpoint a reader kept from copying every frame" do
    config = Punch::Database::Config.new(readers: 2, checkpoint_pages: 50)
    Punch::Spec.database(file: true, config: config) do |db|
      registry = Punch::Metrics::Registry.new
      db.observe(registry)
      create(db)
      fill(db, 1)
      reading = Channel(Nil).new
      release = Channel(Nil).new
      done = Channel(Nil).new
      spawn do
        db.read do |reader|
          reader.query_one?("SELECT count(*) FROM t") { |row| row.read(Int64) }
          reading.send(nil)
          release.receive
        end
        done.send(nil)
      end
      reading.receive
      fill(db, 60)
      # The checkpoint runs after the write returns: keep the reader until it has.
      Punch::Spec.eventually { db.signals.checkpoints[0].should eq(1) }
      release.send(nil)
      done.receive
      db.signals.checkpoints.should eq({1, 1})
      metrics = Punch::Spec.metrics(registry)
      metrics.distribution("punch.db.checkpoint.duration", "punch.db.checkpoint.complete": false).count.should eq(1)
      metrics.value("punch.db.wal.frames").should be > 50
    end
  end

  it "after an incomplete checkpoint, waits for checkpoint_pages more frames before the next" do
    config = Punch::Database::Config.new(readers: 2, checkpoint_pages: 50)
    Punch::Spec.database(file: true, config: config) do |db|
      create(db)
      fill(db, 1)
      reading = Channel(Nil).new
      release = Channel(Nil).new
      done = Channel(Nil).new
      # A reader that holds its snapshot, as Litestream does between its
      # own checkpoints.
      spawn do
        db.read do |reader|
          reader.query_one?("SELECT count(*) FROM t") { |row| row.read(Int64) }
          reading.send(nil)
          release.receive
        end
        done.send(nil)
      end
      reading.receive
      fill(db, 60)
      Punch::Spec.eventually { db.signals.checkpoints.should eq({1, 1}) }
      # Small writes past the threshold: no checkpoint after each of them.
      10.times { fill(db, 1) }
      sleep 50.milliseconds
      db.signals.checkpoints.should eq({1, 1})
      fill(db, 45)
      Punch::Spec.eventually { db.signals.checkpoints.should eq({2, 2}) }
      release.send(nil)
      done.receive
      # Once the reader is gone, the next checkpoint copies everything.
      fill(db, 60)
      Punch::Spec.eventually { db.signals.checkpoints.should eq({3, 2}) }
    end
  end

  it "reports only the writer queue of a database in memory, and nothing once closed" do
    registry = Punch::Metrics::Registry.new
    db = Punch::Database.memory(name: "scratch")
    db.observe(registry)
    registry.collect.map(&.name).should eq(["db.client.connection.pending_requests"])
    db.close
    registry.collect.should be_empty
  end

  it "refuses the wal_autocheckpoint pragma: the writer checkpoints itself" do
    expect_raises(ArgumentError, /checkpoint_pages/) do
      Punch::Database::Config.new(pragmas: {"wal_autocheckpoint" => "100"})
    end
    expect_raises(ArgumentError, /checkpoint_pages/) { Punch::Database::Config.new(checkpoint_pages: 0) }
  end
end
