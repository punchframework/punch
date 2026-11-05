require "../spec_helper"
require "../../src/punch/cli/tool"

private record Run, code : Int32, stdout : String, stderr : String

private def punch(*args : String) : Run
  stdout, stderr = IO::Memory.new, IO::Memory.new
  code = Punch::CLI.run(args.to_a, stdout, stderr)
  Run.new(code, stdout.to_s, stderr.to_s)
end

private def tool(*args : String) : Run
  stdout, stderr = IO::Memory.new, IO::Memory.new
  code = Punch::CLI.run(args.to_a, stdout, stderr, Punch::CLI::TOOL_COMMANDS)
  Run.new(code, stdout.to_s, stderr.to_s)
end

private def git(*args : String) : Nil
  Process.run("git", args.to_a, error: Process::Redirect::Inherit).success? || fail "git #{args.join(" ")} failed"
end

private def json(*args : String) : JSON::Any
  JSON.parse(punch(*args, "--json").stdout)
end

# Runs the block in a fresh app directory. Examples run one at a time, so
# changing the working directory is safe here.
private def in_app(& : ->)
  directory = File.tempname("punch-app")
  Dir.mkdir_p(File.join(directory, "db/migrations"))
  begin
    Dir.cd(directory) { yield }
  ensure
    FileUtils.rm_rf(directory)
  end
end

private def write_migration(name : String, sql : String) : Nil
  File.write("db/migrations/#{name}", sql)
end

describe "punch db:migration" do
  it "creates a timestamped file" do
    in_app do
      path = json("db:migration", "CreateInvoices")["path"].as_s
      path.should match(%r{\Adb/migrations/\d{14}_create_invoices\.sql\z})
      File.read(path).should start_with("-- ")
      Punch::Migrations.from_directory.size.should eq(1)
    end
  end

  it "rejects a missing or empty name" do
    in_app do
      punch("db:migration").code.should eq(2)
      json("db:migration", "--")["error"]["code"].should eq("invalid_name")
    end
  end
end

describe "punch db:migration --punch" do
  it "writes Punch's own tables as a migration, for each set" do
    Punch::CLI::Commands::PunchTables::NAMES.each do |name|
      in_app do
        path = json("db:migration", "--punch", name)["path"].as_s
        path.should match(%r{\Adb/migrations/\d{14}_add_punch_#{name}\.sql\z})
        File.read(path).should eq(Punch::CLI::Commands::PunchTables.sql(name))
      end
    end
  end

  it "names the app's users table with --users, and refuses what it cannot use" do
    in_app do
      File.read(json("db:migration", "--punch", "auth", "--users", "people")["path"].as_s).should contain("REFERENCES people (id)")
      json("db:migration", "--punch", "outbox", "--users", "people")["error"]["code"].should eq("unexpected_argument")
      json("db:migration", "--punch", "cache")["error"]["code"].should eq("unknown_tables")
      json("db:migration", "--punch")["error"]["code"].should eq("missing_argument")
      json("db:migration", "--punch", "auth", "--users", "x; DROP")["error"]["code"].should eq("invalid_name")
    end
  end
end

describe Punch::CLI::Commands::PunchTables do
  it "finds no drift in the tables it writes, and names the migration when a column is gone or changed" do
    schema = Punch::CLI::Commands::PunchTables::NAMES.join("\n") { |name| Punch::CLI::Commands::PunchTables.sql(name) }
    Punch::CLI::Commands::PunchTables.drift(Punch::CLI::Commands::PunchTables.columns(schema)).should be_empty
    # A set the app does not use is left out; the progress of jobs with
    # steps never is.
    Punch::CLI::Commands::PunchTables.drift(Punch::CLI::Commands::PunchTables.columns("CREATE TABLE notes (id INTEGER PRIMARY KEY) STRICT;")).should eq([
      "punch_job_progress is missing from db/schema.sql; every app has it, since Punch's own jobs run in steps. punch db:migration --punch steps writes it.",
    ])
    Punch::CLI::Commands::PunchTables.drift(Punch::CLI::Commands::PunchTables.columns(Punch::Job::Steps::Progress.sql)).should be_empty

    old = Punch::Job::Steps::Progress.sql + Punch::Job::Outbox.sql.sub("concurrency_key   TEXT,", "").sub("payload           TEXT    NOT NULL", "payload BLOB NOT NULL")
    problems = Punch::CLI::Commands::PunchTables.drift(Punch::CLI::Commands::PunchTables.columns(old))
    problems.size.should eq(2)
    problems.join.should contain("punch_outbox.concurrency_key is missing")
    problems.join.should contain("punch_outbox.payload is BLOB, Punch needs TEXT")
    problems.join.should contain("punch db:migration --punch outbox")
  end
end

describe "punch db:migrate" do
  it "applies pending migrations and writes db/schema.sql, which db:schema --check accepts" do
    in_app do
      write_migration("20261001000000_create_customers.sql", "CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT NOT NULL) STRICT;")
      result = json("db:migrate", "storage/primary.db")
      result["applied"].as_a.map(&.["name"].as_s).should eq(%w[create_customers])
      File.read("db/schema.sql").should contain("CREATE TABLE customers")
      punch("db:schema", "--check").code.should eq(0)

      write_migration("20261002000000_create_invoices.sql", "CREATE TABLE invoices (id INTEGER PRIMARY KEY) STRICT;")
      drift = json("db:schema", "--check")
      drift["error"]["code"].should eq("schema_drift")
      json("db:status", "storage/primary.db")["migrations"].as_a.map(&.["state"].as_s).should eq(%w[applied pending])

      punch("db:migrate", "storage/primary.db").stdout.should eq("Applied 20261002000000_create_invoices.sql\nWrote db/schema.sql\n")
      punch("db:schema", "--check").stdout.should eq("db/schema.sql matches the migrations.\n")
      punch("db:migrate", "storage/primary.db").stdout.should start_with("storage/primary.db is up to date.")
    end
  end

  it "reports a failing migration with file and line, as JSON" do
    in_app do
      write_migration("20261001000000_broken.sql", "CREATE TABLE a (id INTEGER PRIMARY KEY);\nCREATE TABLE b (id INTEGER PRIMARY KEY,);")
      run = punch("db:migrate", "storage/primary.db", "--json")
      run.code.should eq(1)
      error = JSON.parse(run.stdout)["error"]
      error["code"].should eq("migration_failed")
      error["message"].as_s.should start_with("db/migrations/20261001000000_broken.sql:2:")
    end
  end

  it "refuses a database on a refused filesystem" do
    verdict = Punch::Database::Filesystem.check("#{__DIR__}/x.db")
    next unless verdict.refused
    in_app do
      json("db:migrate", "#{__DIR__}/x.db")["error"]["code"].should eq("filesystem_refused")
    end
  end
end

describe "punch db:status" do
  it "lists every migration as pending for a missing database, without creating it" do
    in_app do
      write_migration("20261001000000_a.sql", "CREATE TABLE a (id INTEGER PRIMARY KEY);")
      punch("db:status", "storage/none.db").stdout.should eq("pending  20261001000000_a\n")
      File.exists?("storage/none.db").should be_false
    end
  end
end

describe "punch db:schema" do
  it "prints the schema the migrations produce" do
    in_app do
      write_migration("20261001000000_a.sql", "CREATE TABLE a (id INTEGER PRIMARY KEY);")
      punch("db:schema").stdout.should contain("CREATE TABLE a (id INTEGER PRIMARY KEY);\n")
      File.exists?("db/schema.sql").should be_false
    end
  end
end

describe "punch db:cost" do
  rebuild = <<-SQL
    CREATE TABLE customers_new (id INTEGER PRIMARY KEY, name TEXT NOT NULL COLLATE de) STRICT;
    INSERT INTO customers_new (id, name) SELECT id, name FROM customers;
    DROP TABLE customers;
    ALTER TABLE customers_new RENAME TO customers;
    SQL

  it "shows each migration's cost and fails --check on an unacknowledged rebuild" do
    in_app do
      write_migration("20261001000000_create_customers.sql", "CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT NOT NULL) STRICT;")
      write_migration("20261002000000_index_names.sql", "CREATE INDEX customers_by_name ON customers (name);")
      tool("db:cost").stdout.should start_with("2 migrations: 1 instant, 1 scan, 0 rebuild\ninstant  20261001000000_create_customers.sql\n" \
                                               "scan     20261002000000_index_names.sql\n  scan       1  CREATE INDEX customers_by_name ON customers (name)\n")
      tool("db:cost", "--check").code.should eq(0)

      write_migration("20261003000000_sort_names.sql", rebuild)
      run = tool("db:cost", "--check", "--json")
      run.code.should eq(1)
      error = JSON.parse(run.stdout)["error"]
      error["code"].should eq("unacknowledged_rebuild")
      error["message"].as_s.should start_with("db/migrations/20261003000000_sort_names.sql:2: rebuilds customers: copies every row of customers into its new table.")
      migration = error["details"]["migrations"].as_a.last
      migration["cost"].should eq("rebuild")
      migration["statements"].as_a.map(&.["cost"].as_s).should eq(%w[instant rebuild rebuild rebuild])

      write_migration("20261003000000_sort_names.sql", "-- rebuild: customers\n#{rebuild}")
      tool("db:cost", "--check").code.should eq(0)
    end
  end

  it "checks only the migrations --base does not have" do
    in_app do
      write_migration("20261001000000_create_customers.sql", "CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT NOT NULL) STRICT;")
      write_migration("20261002000000_sort_names.sql", rebuild)
      git("init", "-q")
      git("add", ".")
      git("-c", "user.name=Spec", "-c", "user.email=spec@example.com", "commit", "-q", "-m", "shipped")
      tool("db:cost", "--check", "--base", "HEAD").code.should eq(0)

      write_migration("20261003000000_drop_name.sql", "ALTER TABLE customers DROP COLUMN name;")
      run = tool("db:cost", "--check", "--base", "HEAD")
      run.code.should eq(1)
      run.stderr.should contain("20261003000000_drop_name.sql:1: rebuilds customers: DROP COLUMN rewrites every row")
      run.stderr.should_not contain("sort_names")
      tool("db:cost", "--base", "HEAD").stdout.should start_with("3 migrations: 1 instant, 0 scan, 2 rebuild; 1 new since HEAD\n")
      tool("db:cost", "--base", "nope").code.should eq(2)
    end
  end
end
