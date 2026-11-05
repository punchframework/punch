require "../spec_helper"

private def vendored_version : String
  header = File.read("#{__DIR__}/../../vendor/sqlite/sqlite3.h")
  header.match!(/#define SQLITE_VERSION\s+"([^"]+)"/)[1]
end

private def with_connection(& : Punch::Database::Driver::Connection ->)
  connection = Punch::Database::Driver.open(":memory:")
  begin
    yield connection
  ensure
    connection.close
  end
end

describe Punch::Database::Driver do
  it "links the vendored SQLite, not the system's" do
    Punch::Database::Driver.version.should eq(vendored_version)
    Punch::Database::Driver.threadsafe.should eq(1)
    {% if flag?(:linux) %}
      if executable = Process.executable_path
        output = IO::Memory.new
        Process.run("ldd", [executable], output: output, error: Process::Redirect::Close)
        output.to_s.should_not contain("libsqlite3")
      end
    {% end %}
  end

  it "is built with Punch's compile options" do
    options = Punch::Database::Driver.compile_options
    options.should contain("THREADSAFE=1")
    options.should contain("DQS=0")
    options.should contain("USE_URI")
    options.should contain("ENABLE_COLUMN_METADATA")
    options.should contain("OMIT_LOAD_EXTENSION")
    options.should contain("DEFAULT_FILE_PERMISSIONS=0600")
  end

  it "trusts no schema with functions that are not innocuous, and refuses writable_schema" do
    with_connection do |connection|
      # SQLite does not list these two options; their effect shows.
      connection.scalar_text("PRAGMA trusted_schema").should eq("0")
      connection.exec("PRAGMA writable_schema = ON")
      connection.scalar_text("PRAGMA writable_schema").should eq("0")
    end
  end

  it "describes a statement's columns, their origins, and its parameters without running it" do
    with_connection do |connection|
      connection.exec("CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT NOT NULL) STRICT")
      shape = connection.shape("SELECT c.id, c.name AS customer, count(*) AS n FROM customers c WHERE c.name = :name AND c.id > ?")
      shape.columns.map(&.name).should eq(%w[id customer n])
      shape.columns[1].table.should eq("customers")
      shape.columns[1].origin.should eq("name")
      shape.columns[1].declared_type.should eq("TEXT")
      shape.columns[2].origin.should be_nil
      shape.parameters.should eq([":name", nil])
      shape.read_only.should be_true
      connection.shape("DELETE FROM customers").read_only.should be_false
    end
  end

  it "reports where in the SQL a syntax error is" do
    with_connection do |connection|
      error = expect_raises(Punch::Database::Error, /syntax error/) { connection.exec("SELECT * FROM WHERE") }
      error.offset.should eq(14)
      error.primary_code.should eq(1)
      error.sql.should eq("SELECT * FROM WHERE")
    end
  end

  it "closes cleanly after a failed statement (crystal-sqlite3 raises from close otherwise)" do
    connection = Punch::Database::Driver.open(":memory:")
    connection.exec("CREATE TABLE t (id INTEGER PRIMARY KEY)")
    connection.exec("INSERT INTO t VALUES (1)")
    expect_raises(Punch::Database::ConstraintError, /UNIQUE/) { connection.exec("INSERT INTO t VALUES (?)", {1}) }
    connection.close
  end

  it "keeps the statement usable after a failure" do
    with_connection do |connection|
      connection.exec("CREATE TABLE t (id INTEGER PRIMARY KEY)")
      connection.exec("INSERT INTO t VALUES (?)", {1})
      expect_raises(Punch::Database::ConstraintError) { connection.exec("INSERT INTO t VALUES (?)", {1}) }
      connection.exec("INSERT INTO t VALUES (?)", {2}).changes.should eq(1)
    end
  end

  it "says why a connection cannot open, instead of a bare ConnectionRefused" do
    expect_raises(Punch::Database::Error, /cannot open .*: unable to open database file/) do
      Punch::Database::Driver.open("/nonexistent-#{Random::Secure.hex(4)}/x.db")
    end
  end

  it "names the column and the expected type when a value does not fit" do
    with_connection do |connection|
      error = expect_raises(Punch::Database::ColumnError, /column 1 \(name\) is not Int64/) do
        connection.query("SELECT 1 AS id, 'Ada' AS name", Tuple.new) { |row| row.read(Int64); row.read(Int64) }
      end
      error.column.should eq("name")
      error.index.should eq(1)
    end
  end

  it "runs a script statement by statement, reporting where each starts" do
    with_connection do |connection|
      starts = [] of Int32
      script = "-- a comment\nCREATE TABLE t (id INTEGER PRIMARY KEY);\n/* block\ncomment */ INSERT INTO t VALUES (1);\n-- trailing\n"
      connection.exec_script(script) { |start| starts << start }
      starts.should eq([script.byte_index("CREATE"), script.byte_index("INSERT")])
    end
  end

  it "reports the line and column of a failing statement in a script" do
    with_connection do |connection|
      script = "CREATE TABLE t (id INTEGER PRIMARY KEY);\n-- next\n  INSERT INTO t VALUES (1), (1);"
      error = expect_raises(Punch::Database::ScriptError, /UNIQUE constraint failed: t.id \(line 3, column 3\)/) do
        connection.exec_script(script) { }
      end
      error.position.should eq(script.byte_index("INSERT"))
      error = expect_raises(Punch::Database::ScriptError) { connection.exec_script("SELECT 1;\nSELECT * FORM t;") { } }
      {error.line, error.column}.should eq({2, 10})
    end
  end

  it "reads nullable columns and booleans" do
    with_connection do |connection|
      connection.query("SELECT NULL, 1, 2.5, x'0102'", Tuple.new) do |row|
        row.read(String?).should be_nil
        row.read(Bool).should be_true
        row.read(Float64).should eq(2.5)
        row.read(Bytes).should eq(Bytes[1, 2])
      end
    end
  end
end
