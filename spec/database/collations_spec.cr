require "../spec_helper"

private def names(reader, sql : String, *args) : Array(String)
  reader.query_all(sql, *args, &.read(String))
end

describe "Collations and text functions in SQL" do
  it "orders and indexes a collated column on the writer and every reader" do
    Punch::Spec.database(file: true) do |db|
      db.write do |writer|
        writer.exec("CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT NOT NULL COLLATE de) STRICT")
        writer.exec("CREATE INDEX people_by_name ON people (name)")
        %w[zulu Ärger apfel Zebra Öl ober].each { |name| writer.exec("INSERT INTO people (name) VALUES (?)", name) }
        names(writer, "SELECT name FROM people ORDER BY name").should eq(%w[apfel Ärger ober Öl Zebra zulu])
      end
      results = Channel(Array(String)).new(4)
      4.times { spawn { results.send(db.read { |reader| names(reader, "SELECT name FROM people ORDER BY name") }) } }
      4.times { results.receive.should eq(%w[apfel Ärger ober Öl Zebra zulu]) }
      db.read do |reader|
        plan = reader.query_all("EXPLAIN QUERY PLAN SELECT name FROM people WHERE name > 'b' ORDER BY name") do |row|
          3.times { row.read(Int64) }
          row.read(String)
        end
        plan.join.should contain("people_by_name")
        names(reader, "SELECT name FROM people WHERE name < 'b'").sort!.should eq(%w[apfel Ärger])
      end
    end
  end

  it "keeps a unique index on a collated column exact" do
    Punch::Spec.database do |db|
      db.write do |writer|
        writer.exec("CREATE TABLE tags (name TEXT NOT NULL COLLATE de UNIQUE) STRICT")
        writer.exec("INSERT INTO tags VALUES ('Café'), ('cafe'), ('Cafe')")
        expect_raises(Punch::Database::ConstraintError) { writer.exec("INSERT INTO tags VALUES ('Café')") }
      end
    end
  end

  it "replaces lower, upper, and like with versions beyond ASCII" do
    Punch::Spec.database do |db|
      db.read do |reader|
        names(reader, "SELECT lower('ÄRGER') || ' ' || upper('straße')").should eq(["ärger STRASSE"])
        reader.query_one?("SELECT 'Ärger' LIKE 'ä%', 'Ärger' LIKE 'a%', '50% off' LIKE '50!%%' ESCAPE '!', NULL LIKE 'a'") do |row|
          {row.read(Int64), row.read(Int64), row.read(Int64), row.read(Int64?)}
        end.should eq({1, 0, 1, nil})
        reader.query_one?("SELECT lower(NULL) IS NULL, upper(12)") { |row| {row.read(Int64), row.read(String)} }.should eq({1, "12"})
        expect_raises(Punch::Database::Error, "ESCAPE expression must be a single character") do
          reader.query_one?("SELECT 'a' LIKE 'a' ESCAPE 'xy'", &.read(Int64))
        end
      end
    end
  end

  it "lets a schema use Punch's functions, which are marked innocuous" do
    Punch::Spec.database do |db|
      db.write do |writer|
        writer.exec("CREATE TABLE t (name TEXT NOT NULL, folded TEXT GENERATED ALWAYS AS (lower(name))) STRICT")
        writer.exec("CREATE INDEX t_by_upper ON t (upper(name))")
        writer.exec("INSERT INTO t (name) VALUES ('ÄRGER')")
      end
      db.read { |reader| names(reader, "SELECT folded FROM t") }.should eq(["ärger"])
    end
  end

  it "reads a like pattern once per statement, and keeps SQLite's limit on its length" do
    Punch::Spec.database do |db|
      db.write do |writer|
        writer.exec("CREATE TABLE t (name TEXT NOT NULL, pattern TEXT NOT NULL) STRICT")
        writer.exec("INSERT INTO t VALUES ('Ärger', 'ä%'), ('ärger', 'a%'), ('50% off', '50!%%'), ('500 off', '50!%%'), ('ab', 'ab!')")
      end
      db.read do |reader|
        # A bound pattern for every row, then one per row.
        names(reader, "SELECT name FROM t WHERE name LIKE ? ESCAPE '!' ORDER BY rowid", "%r%").should eq(["Ärger", "ärger"])
        names(reader, "SELECT name FROM t WHERE name LIKE pattern ESCAPE '!' ORDER BY rowid").should eq(["Ärger", "50% off"])
        names(reader, "SELECT name FROM t WHERE name LIKE pattern ORDER BY rowid").should eq(["Ärger"])
        reader.query_one?("SELECT ? LIKE ?", "a" * 50_000, "a" * 50_000, &.read(Int64)).should eq(1)
        expect_raises(Punch::Database::Error, "LIKE or GLOB pattern too complex") do
          reader.query_one?("SELECT 'a' LIKE ?", "a" * 50_001, &.read(Int64))
        end
      end
    end
  end
end
