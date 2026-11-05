require "../spec_helper"

private def limits_database(name : String, & : Punch::Database ->) : Nil
  db = Punch::Database.memory(name: name, config: Punch::Database::Config.new(readers: 1))
  begin
    yield db
  ensure
    db.close
  end
end

describe Punch::Database::Limits do
  after_each { Punch::Database.reset_limits }

  it "sets the defaults on the writer and the readers" do
    limits_database("limits") do |db|
      too_long = Punch::Database::Config::LIMITS.length + 1
      expect_raises(Punch::Database::Error, /too big/) { db.write(&.exec("SELECT zeroblob(?)", too_long)) }
      expect_raises(Punch::Database::Error, /too big/) { db.read(&.query_all("SELECT zeroblob(?)", too_long, &.read(Bytes))) }
      db.read(&.query_all("SELECT length(zeroblob(?))", too_long - 1, &.read(Int64))).should eq([too_long - 1])
      expect_raises(Punch::Database::Error, /variable number must be between \?1 and \?1000/) { db.read(&.query_all("SELECT ?1001", &.read(Int64?))) }
    end
  end

  it "takes an app's limits for one database and keeps the defaults for the others" do
    Punch::Database.limits "primary", length: 1000
    Punch::Database.limits_for("primary").length.should eq(1000)
    Punch::Database.limits_for("primary").variable_number.should eq(Punch::Database::Config::LIMITS.variable_number)
    limits_database("primary") do |db|
      expect_raises(Punch::Database::Error, /too big/) { db.write(&.exec("SELECT zeroblob(1001)")) }
    end
    limits_database("queue") do |db|
      db.write(&.exec("SELECT zeroblob(1001)"))
    end
  end

  it "refuses a limit SQLite would lower without saying so" do
    expect_raises(ArgumentError, /variable_number must be between 1 and 32766, not 40000/) { Punch::Database.limits "primary", variable_number: 40_000 }
    expect_raises(ArgumentError, /length must be between 1/) { Punch::Database::Limits.new(length: 0) }
  end

  it "counts a migration's statements one by one" do
    Punch::Database.limits "limits", sql_length: 400
    limits_database("limits") do |db|
      script = Array.new(10) { |index| "CREATE TABLE t#{index} (id INTEGER PRIMARY KEY) STRICT;" }.join("\n")
      script.bytesize.should be > 400
      migration = Punch::Migrations::Migration.new(20261101000000, "tables", script, "spec")
      Punch::Migrations::Migrator.new(db, [migration]).migrate
      db.read(&.query_all("SELECT count(*) FROM sqlite_schema WHERE name LIKE 't%'", &.read(Int64))).should eq([10])
      expect_raises(Punch::Database::Error, /too big|too long/) do
        db.write(&.exec("SELECT 1 WHERE 1 IN (#{Array.new(200, "1").join(", ")})"))
      end
    end
  end

  it "applies the LIKE pattern limit to Punch's own like()" do
    Punch::Database.limits "limits", like_pattern_length: 10
    limits_database("limits") do |db|
      db.read(&.query_all("SELECT 'abc' LIKE ?", "a%", &.read(Int64))).should eq([1])
      expect_raises(Punch::Database::Error, /LIKE or GLOB pattern too complex/) do
        db.read(&.query_all("SELECT 'abc' LIKE ?", "a" * 11, &.read(Int64)))
      end
    end
  end

  it "refuses ATTACH" do
    limits_database("limits") do |db|
      expect_raises(Punch::Database::Error, /too many attached databases/) do
        db.write(&.exec("ATTACH DATABASE ':memory:' AS other"))
      end
    end
  end
end
