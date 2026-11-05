require "../spec_helper"

private def pragma(handle : Punch::Reader | Punch::Writer, name : String) : String
  handle.query_one?("PRAGMA #{name}") { |row| row.read(String | Int64).to_s } || fail "no value for #{name}"
end

# Writes marked rows to a file database, clears one table's values and
# drops the other, closes it (the last close checkpoints the WAL), and
# returns how many markers the file still holds.
private def markers_left(pragmas = {} of String => String) : Int32
  directory = File.tempname("punch-spec")
  Dir.mkdir(directory)
  path = File.join(directory, "spec.db")
  db = Punch::Database.open(path, config: Punch::Database::Config.new(readers: 1, pragmas: pragmas))
  begin
    db.write do |writer|
      writer.exec("CREATE TABLE cleared (id INTEGER PRIMARY KEY, email TEXT) STRICT")
      writer.exec("CREATE TABLE dropped (id INTEGER PRIMARY KEY, email TEXT) STRICT")
      100.times do |index|
        writer.exec("INSERT INTO cleared (email) VALUES (?)", "plaintext-marker-#{index}@example.org")
        writer.exec("INSERT INTO dropped (email) VALUES (?)", "plaintext-marker-#{index}@example.org")
      end
    end
    db.write do |writer|
      writer.exec("UPDATE cleared SET email = NULL")
      writer.exec("DROP TABLE dropped")
    end
  ensure
    db.close
  end
  File.read(path).scan("plaintext-marker-").size
ensure
  FileUtils.rm_rf(directory) if directory
end

private def count(db : Punch::Database, table = "t") : Int64
  db.read { |reader| reader.query_one?("SELECT count(*) FROM #{table}") { |row| row.read(Int64) } } || 0_i64
end

private def create_table(db : Punch::Database) : Nil
  db.write { |writer| writer.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE) STRICT") }
end

describe Punch::Database do
  describe "connections" do
    it "sets the pragmas on the writer, with WAL on a file" do
      Punch::Spec.database(file: true) do |db|
        db.write do |writer|
          pragma(writer, "journal_mode").should eq("wal")
          pragma(writer, "busy_timeout").should eq("5000")
          pragma(writer, "synchronous").should eq("1")
          pragma(writer, "foreign_keys").should eq("1")
          pragma(writer, "temp_store").should eq("2")
          pragma(writer, "secure_delete").should eq("1")
          pragma(writer, "query_only").should eq("0")
        end
      end
    end

    it "zeroes what it clears or drops, so the file does not keep it" do
      markers_left.should eq(0)
      # The same writes without secure_delete leave them in free space.
      markers_left({"secure_delete" => "OFF"}).should be > 0
    end

    it "makes readers read-only, with the same busy_timeout" do
      Punch::Spec.database(file: true) do |db|
        db.read do |reader|
          pragma(reader, "query_only").should eq("1")
          pragma(reader, "busy_timeout").should eq("5000")
          pragma(reader, "journal_mode").should eq("wal")
        end
      end
    end

    it "refuses writes through a reader, even INSERT … RETURNING" do
      Punch::Spec.database do |db|
        create_table(db)
        expect_raises(Punch::Database::Error, /readonly/) do
          db.read { |reader| reader.query_all("INSERT INTO t (name) VALUES ('x') RETURNING id") { |row| row.read(Int64) } }
        end
        count(db).should eq(0)
      end
    end

    it "sets busy_timeout first, and leaves journal settings to the writer" do
      config = Punch::Database::Config.new(pragmas: {"cache_size" => "-4000", "busy_timeout" => "100"})
      config.ordered_pragmas(writer: true).first.should eq({"busy_timeout", "100"})
      config.ordered_pragmas(writer: true).should contain({"cache_size", "-4000"})
      config.ordered_pragmas(writer: false).map(&.first).should_not contain("journal_mode")
    end

    it "rejects pragma names and values that are not plain words" do
      expect_raises(ArgumentError, /invalid pragma/) do
        Punch::Database::Config.new(pragmas: {"cache_size" => "1; DROP TABLE t"})
      end
    end

    it "registers collations on the writer and every reader" do
      reverse = ->(a : Bytes, b : Bytes) { b <=> a }
      config = Punch::Database::Config.new(readers: 2, collations: Punch::Text::Collation::BUILTIN + [Punch::Text::Collation.new("reverse", "1", reverse)])
      Punch::Spec.database(file: true, config: config) do |db|
        create_table(db)
        db.write do |writer|
          %w[b c a].each { |name| writer.exec("INSERT INTO t (name) VALUES (?)", name) }
          writer.query_all("SELECT name FROM t ORDER BY name COLLATE reverse") { |row| row.read(String) }.should eq(%w[c b a])
        end
        # Several fibers, so both readers are used.
        results = Channel(Array(String)).new(4)
        4.times do
          spawn do
            results.send(db.read { |reader| sleep 10.milliseconds; reader.query_all("SELECT name FROM t ORDER BY name COLLATE reverse") { |row| row.read(String) } })
          end
        end
        4.times { results.receive.should eq(%w[c b a]) }
      end
    end
  end

  describe "#write" do
    it "gives up with WriterBusy when the writer's queue stays full" do
      config = Punch::Database::Config.new(readers: 1, queue_size: 1, enqueue_timeout: 50.milliseconds)
      Punch::Spec.database(config: config) do |db|
        release = Channel(Nil).new
        started = Channel(Nil).new
        spawn { db.write { started.send(nil); release.receive } }
        started.receive
        spawn { db.write { } } # fills the queue
        Fiber.yield
        expect_raises(Punch::Database::WriterBusy) { db.write { } }
        release.send(nil)
      end
    end

    it "returns the block's value and commits" do
      Punch::Spec.database do |db|
        create_table(db)
        id = db.write { |writer| writer.query_one?("INSERT INTO t (name) VALUES (?) RETURNING id", "Ada") { |row| row.read(Int64) } }
        id.should eq(1)
        db.write { |writer| writer.exec("INSERT INTO t (name) VALUES (?)", "Grace") }.last_insert_id.should eq(2)
        count(db).should eq(2)
      end
    end

    it "rolls back everything when the block raises, and raises the error to the caller" do
      Punch::Spec.database do |db|
        create_table(db)
        expect_raises(Punch::Database::ConstraintError, /UNIQUE constraint failed: t.name/) do
          db.write do |writer|
            writer.exec("INSERT INTO t (name) VALUES (?)", "Ada")
            writer.exec("INSERT INTO t (name) VALUES (?)", "Ada")
          end
        end
        expect_raises(ArgumentError, "boom") do
          db.write do |writer|
            writer.exec("INSERT INTO t (name) VALUES (?)", "Ada")
            raise ArgumentError.new("boom")
          end
        end
        count(db).should eq(0)
        db.write { |writer| writer.exec("INSERT INTO t (name) VALUES (?)", "Ada") }
        count(db).should eq(1)
      end
    end

    it "keeps the writes of after_rollback when a rollback-only transaction rolls back, and runs only their after-commit work" do
      Punch::Spec.database do |db|
        create_table(db)
        ran = [] of String
        db.write do |writer|
          writer.exec("INSERT INTO t (name) VALUES (?)", "rolled back")
          writer.lease.after_commit(-> { ran << "before"; nil })
          writer.lease.rollback_only = true
          writer.lease.after_rollback = ->(kept : Punch::Writer) do
            kept.exec("INSERT INTO t (name) VALUES (?)", "kept")
            kept.lease.after_commit(-> { ran << "kept"; nil })
            nil
          end
        end
        db.read(&.query_all("SELECT name FROM t", &.read(String))).should eq(["kept"])
        ran.should eq(["kept"])
      end
    end

    it "reports the extended code of a constraint failure" do
      Punch::Spec.database do |db|
        create_table(db)
        error = expect_raises(Punch::Database::ConstraintError) { db.write { |writer| writer.exec("INSERT INTO t (name) VALUES (NULL)") } }
        error.code.should eq(1299) # SQLITE_CONSTRAINT_NOTNULL
        error = expect_raises(Punch::Database::ConstraintError) { db.write { |writer| writer.exec("INSERT INTO t (name) VALUES (x'00')") } }
        error.code.should eq(3091) # SQLITE_CONSTRAINT_DATATYPE: STRICT tables enforce column types
      end
    end

    it "serializes writes: read-modify-write from many fibers loses nothing" do
      Punch::Spec.database(file: true) do |db|
        db.write { |writer| writer.exec("CREATE TABLE counter (n INTEGER NOT NULL) STRICT"); writer.exec("INSERT INTO counter VALUES (0)") }
        done = Channel(Nil).new
        16.times do
          spawn do
            25.times do
              db.write do |writer|
                n = writer.query_one?("SELECT n FROM counter", &.read(Int64)) || 0_i64
                writer.exec("UPDATE counter SET n = ?", n + 1)
              end
            end
            done.send(nil)
          end
        end
        16.times { done.receive }
        db.read { |reader| reader.query_one?("SELECT n FROM counter", &.read(Int64)) }.should eq(400)
      end
    end

    it "refuses a write inside a write instead of waiting for itself" do
      Punch::Spec.database do |db|
        expect_raises(Punch::Database::Error, /write called inside a write/) do
          db.write { |_| db.write { |_| nil } }
        end
        db.write { |writer| writer.query_one?("SELECT 1", &.read(Int64)) }.should eq(1)
      end
    end
  end

  describe "#read" do
    it "sees one snapshot for the whole block while writes go on" do
      Punch::Spec.database(file: true, config: Punch::Database::Config.new(readers: 4)) do |db|
        db.write do |writer|
          writer.exec("CREATE TABLE items (id INTEGER PRIMARY KEY) STRICT")
          writer.exec("CREATE TABLE counter (n INTEGER NOT NULL) STRICT")
          writer.exec("INSERT INTO counter VALUES (0)")
        end
        stop = Atomic(Bool).new(false)
        writer_done = Channel(Nil).new
        spawn do
          until stop.get
            db.write { |writer| writer.exec("INSERT INTO items DEFAULT VALUES"); writer.exec("UPDATE counter SET n = n + 1") }
          end
          writer_done.send(nil)
        end
        checks = Channel(Int32).new
        8.times do
          spawn do
            mismatches = 0
            200.times do
              db.read do |reader|
                items = reader.query_one?("SELECT count(*) FROM items") { |row| row.read(Int64) }
                Fiber.yield
                counter = reader.query_one?("SELECT n FROM counter", &.read(Int64))
                mismatches += 1 unless items == counter
              end
            end
            checks.send(mismatches)
          end
        end
        mismatches = (1..8).sum { checks.receive }
        stop.set(true)
        writer_done.receive
        mismatches.should eq(0)
        count(db, "items").should be > 0
      end
    end

    it "refuses a handle used after its block" do
      Punch::Spec.database do |db|
        leaked = db.read { |reader| reader }
        expect_raises(Punch::Database::Error, /after its block ended/) { leaked.query_all("SELECT 1", &.read(Int64)) }
        leaked_writer = db.write { |writer| writer }
        expect_raises(Punch::Database::Error, /after its block ended/) { leaked_writer.exec("SELECT 1") }
      end
    end

    it "keeps no transaction open after a failed query" do
      Punch::Spec.database do |db|
        expect_raises(Punch::Database::Error, /no such table/) { db.read { |reader| reader.query_all("SELECT * FROM missing", &.read(Int64)) } }
        create_table(db)
        db.write(&.exec("INSERT INTO t (name) VALUES ('x')"))
        count(db).should eq(1)
      end
    end
  end

  describe "in memory" do
    it "shares one database between the writer and the readers, and nothing between databases" do
      Punch::Spec.database do |one|
        Punch::Spec.database do |two|
          create_table(one)
          one.write(&.exec("INSERT INTO t (name) VALUES ('x')"))
          count(one).should eq(1)
          expect_raises(Punch::Database::Error, /no such table/) { count(two) }
        end
      end
    end
  end

  describe "#close" do
    it "is idempotent, refuses further use, and reports itself in the health check" do
      db = Punch::Database.memory
      db.health.should be_nil
      db.close
      db.close
      db.closed?.should be_true
      db.health.should eq("memory: closed")
      expect_raises(Punch::Database::Error, /closed/) { db.read { |_| nil } }
      expect_raises(Punch::Database::Error, /closed/) { db.write { |_| nil } }
    end

    it "checkpoints the WAL into the file" do
      directory = File.tempname("punch-spec")
      Dir.mkdir(directory)
      path = File.join(directory, "x.db")
      db = Punch::Database.open(path)
      create_table(db)
      File.exists?("#{path}-wal").should be_true
      db.close
      File.exists?("#{path}-wal").should be_false
    ensure
      FileUtils.rm_rf(directory) if directory
    end
  end

  describe "filesystem check" do
    it "refuses network and virtual filesystems, and accepts local ones" do
      Punch::Database::Filesystem.classify_linux(0x65735546_i64).should eq({"fuse", true})
      Punch::Database::Filesystem.classify_linux(0x6969_i64).should eq({"nfs", true})
      Punch::Database::Filesystem.classify_linux(0x01021997_i64).should eq({"9p", true})
      Punch::Database::Filesystem.classify_linux(0xEF53_i64).should eq({"ext4", false})
      Punch::Database::Filesystem.classify_linux(0x794C7630_i64).should eq({"overlayfs", false})
    end

    it "accepts the temporary directory specs use" do
      Punch::Database::Filesystem.check(File.join(Dir.tempdir, "x.db")).refused.should be_false
    end

    it "refuses to open a database on a refused filesystem, naming the directory" do
      verdict = Punch::Database::Filesystem.check("#{__DIR__}/x.db")
      next unless verdict.refused # only where the repository is on such a filesystem
      expect_raises(Punch::Database::FilesystemError, /#{Regex.escape(verdict.directory)} is on #{verdict.type}/) do
        Punch::Database.open("#{__DIR__}/x.db")
      end
      File.exists?("#{__DIR__}/x.db").should be_false
    end

    it "refuses a directory that does not exist" do
      expect_raises(Punch::Database::Error, /does not exist/) { Punch::Database.open("/nonexistent-#{Random::Secure.hex(4)}/x.db") }
    end
  end

  describe "two writers on one file" do
    it "share it through busy_timeout, within one process" do
      Punch::Spec.database(file: true) do |db|
        create_table(db)
        other = Punch::Database.open(db.path)
        begin
          done = Channel(Nil).new
          [db, other].each_with_index do |target, index|
            spawn do
              500.times { |i| target.write { |writer| writer.exec("INSERT INTO t (name) VALUES (?)", "#{index}-#{i}") } }
              done.send(nil)
            end
          end
          2.times { done.receive }
        ensure
          other.close
        end
        count(db).should eq(1000)
      end
    end

    it "share it through busy_timeout, across processes" do
      binary = File.tempname("punch-db-writer")
      Process.run("crystal", ["build", "#{__DIR__}/../support/db_writer.cr", "-o", binary],
        output: Process::Redirect::Inherit, error: Process::Redirect::Inherit).success?.should be_true
      Punch::Spec.database(file: true) do |db|
        create_table(db)
        output = IO::Memory.new
        process = Process.new(binary, [db.path, "2000"], output: output, error: output)
        2000.times { |i| db.write { |writer| writer.exec("INSERT INTO t (name) VALUES (?)", "parent-#{i}") } }
        status = process.wait
        fail "writer process failed: #{output}" unless status.success?
        count(db).should eq(4000)
        db.read { |reader| reader.query_one?("PRAGMA integrity_check") { |row| row.read(String) } }.should eq("ok")
      end
    ensure
      File.delete?(binary) if binary
    end
  end
end
