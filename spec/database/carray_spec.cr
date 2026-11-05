require "../spec_helper"

describe Punch::Database::Values do
  it "binds integers, floats, text, and blobs to carray(?)" do
    Punch::Spec.database do |db|
      db.write do |writer|
        writer.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, score REAL NOT NULL, name TEXT NOT NULL, hash BLOB NOT NULL) STRICT")
        5.times { |i| writer.exec("INSERT INTO t (id, score, name, hash) VALUES (?, ?, ?, ?)", i.to_i64 + 1, i + 0.5, "n#{i}", Bytes[i, 0, 255]) }
      end
      db.read do |reader|
        ids = ->(sql : String, values : Punch::Database::Values) { reader.query_all(sql, values, &.read(Int64)).sort }
        ids.call("SELECT id FROM t WHERE id IN carray(?)", Punch::Database::Values.new([2_i64, 4_i64, 9_i64])).should eq([2, 4])
        ids.call("SELECT id FROM t WHERE score IN carray(?)", Punch::Database::Values.new([0.5, 4.5])).should eq([1, 5])
        ids.call("SELECT id FROM t WHERE name IN carray(?)", Punch::Database::Values.new(["n1", "n2", "other"])).should eq([2, 3])
        ids.call("SELECT id FROM t WHERE hash IN carray(?)", Punch::Database::Values.new([Bytes[3, 0, 255], Bytes[3, 0]])).should eq([4])
        ids.call("SELECT id FROM t WHERE id NOT IN carray(?)", Punch::Database::Values.new([1_i64, 2_i64])).should eq([3, 4, 5])
      end
    end
  end

  it "matches nothing for an empty array, and keeps no values between runs of one statement" do
    Punch::Spec.database do |db|
      db.write do |writer|
        writer.exec("CREATE TABLE t (id INTEGER PRIMARY KEY) STRICT")
        writer.exec("WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 3000) INSERT INTO t (id) SELECT i FROM n")
      end
      db.read do |reader|
        sql = "SELECT count(*) FROM t WHERE id IN carray(?)"
        reader.query_all(sql, Punch::Database::Values.new([] of Int64), &.read(Int64)).should eq([0])
        reader.query_all(sql, Punch::Database::Values.new([] of String), &.read(Int64)).should eq([0])
        reader.query_all(sql, Punch::Database::Values.new((1_i64..2500_i64).to_a), &.read(Int64)).should eq([2500])
        reader.query_all(sql, Punch::Database::Values.new([7_i64]), &.read(Int64)).should eq([1])
      end
    end
  end

  it "refuses a text with NUL, which SQLite would cut short" do
    expect_raises(ArgumentError, /NUL/) { Punch::Database::Values.new(["a\0b"]) }
  end
end
