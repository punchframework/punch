require "../spec_helper"

# A directory of migrations for one example, from name => SQL pairs.
private def with_migrations(files : Hash(String, String), & : String ->)
  directory = File.tempname("punch-migrations")
  Dir.mkdir(directory)
  files.each { |name, sql| File.write(File.join(directory, name), sql) }
  begin
    yield directory
  ensure
    FileUtils.rm_rf(directory)
  end
end

private def tables(db : Punch::Database) : Array(String)
  db.read(&.query_all("SELECT name FROM sqlite_schema WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name", &.read(String)))
end

private FIXTURES = "#{__DIR__}/fixtures/migrations"

describe Punch::Migrations do
  it "reads a directory in version order" do
    migrations = Punch::Migrations.from_directory(FIXTURES)
    migrations.map(&.file_name).should eq(%w[20261001120000_create_customers.sql 20261002090000_create_invoices.sql])
    migrations.first.version.should eq(20261001120000)
    migrations.first.checksum.should eq(Digest::SHA256.hexdigest(File.read("#{FIXTURES}/20261001120000_create_customers.sql")))
  end

  it "embeds a directory at compile time, the same as reading it" do
    embedded = Punch::Migrations.embed("fixtures/migrations")
    embedded.map(&.checksum).should eq(Punch::Migrations.from_directory(FIXTURES).map(&.checksum))
    embedded.first.source.should eq("fixtures/migrations/20261001120000_create_customers.sql")
  end

  it "refuses files that are not named like migrations, and duplicate versions" do
    with_migrations({"create_customers.sql" => ""}) do |directory|
      expect_raises(Punch::Migrations::Error, /create_customers.sql: migration files are named/) { Punch::Migrations.from_directory(directory) }
    end
    with_migrations({"20261001120000_a.sql" => "", "20261001120000_b.sql" => "", "README.md" => "notes"}) do |directory|
      expect_raises(Punch::Migrations::Error, /have the same version 20261001120000/) { Punch::Migrations.from_directory(directory) }
    end
  end

  it "names new files by UTC time" do
    time = Time.local(2026, 10, 8, 17, 30, 5, location: Time::Location.fixed(7200))
    Punch::Migrations.file_name("Create Invoices", time).should eq("20261008153005_create_invoices.sql")
    Punch::Migrations.file_name("AddSentAt", time).should eq("20261008153005_add_sent_at.sql")
    expect_raises(Punch::Migrations::Error) { Punch::Migrations.file_name("--", time) }
  end
end

describe Punch::Migrations::Migrator do
  it "applies pending migrations in order, once" do
    Punch::Spec.database do |db|
      migrator = Punch::Migrations::Migrator.new(db, Punch::Migrations.from_directory(FIXTURES))
      migrator.status.map(&.state).should eq([Punch::Migrations::Migrator::State::Pending] * 2)
      migrator.migrate.map(&.name).should eq(%w[create_customers create_invoices])
      tables(db).should eq(%w[customers invoices punch_schema_migrations])
      migrator.status.map(&.state).should eq([Punch::Migrations::Migrator::State::Applied] * 2)
      migrator.status.all?(&.applied_at).should be_true
      migrator.migrate.should be_empty
    end
  end

  it "rolls back a failing migration, keeps the ones before it, and names file, line, and column" do
    with_migrations({
      "20261001000000_ok.sql"     => "CREATE TABLE a (id INTEGER PRIMARY KEY) STRICT;",
      "20261002000000_broken.sql" => "CREATE TABLE b (id INTEGER PRIMARY KEY) STRICT;\n\nCREATE TABLE c (id INTEGER PRIMARY KEY,\n  name TEXT NOT NULL REFERENCES) STRICT;",
    }) do |directory|
      Punch::Spec.database do |db|
        migrator = Punch::Migrations::Migrator.new(db, Punch::Migrations.from_directory(directory))
        error = expect_raises(Punch::Migrations::Failed, /20261002000000_broken.sql:4:\d+: near "\)": syntax error/) { migrator.migrate }
        error.migration.name.should eq("broken")
        error.line.should eq(4)
        tables(db).should eq(%w[a punch_schema_migrations])
        migrator.status.map(&.state.to_s).should eq(%w[Applied Pending])
      end
    end
  end

  it "rolls back a migration that fails while running" do
    with_migrations({"20261001000000_bad_data.sql" => "CREATE TABLE a (id INTEGER PRIMARY KEY, n INTEGER NOT NULL) STRICT;\nINSERT INTO a (n) VALUES (NULL);"}) do |directory|
      Punch::Spec.database do |db|
        expect_raises(Punch::Migrations::Failed, /bad_data.sql:2:1: NOT NULL constraint failed: a.n/) do
          Punch::Migrations::Migrator.new(db, Punch::Migrations.from_directory(directory)).migrate
        end
        tables(db).should be_empty
      end
    end
  end

  it "refuses a migration that ends its own transaction" do
    with_migrations({"20261001000000_commits.sql" => "CREATE TABLE a (id INTEGER PRIMARY KEY);\nCOMMIT;\nCREATE TABLE b (id INTEGER PRIMARY KEY);"}) do |directory|
      Punch::Spec.database do |db|
        expect_raises(Punch::Migrations::Failed, /commits.sql:2:1: a migration must not end its transaction/) do
          Punch::Migrations::Migrator.new(db, Punch::Migrations.from_directory(directory)).migrate
        end
      end
    end
  end

  it "refuses to migrate after an applied migration was edited, and reports unknown ones" do
    with_migrations({"20261001000000_a.sql" => "CREATE TABLE a (id INTEGER PRIMARY KEY);"}) do |directory|
      Punch::Spec.database do |db|
        Punch::Migrations::Migrator.new(db, Punch::Migrations.from_directory(directory)).migrate
        File.write(File.join(directory, "20261001000000_a.sql"), "CREATE TABLE a (id INTEGER PRIMARY KEY, x TEXT);")
        File.write(File.join(directory, "20261002000000_b.sql"), "CREATE TABLE b (id INTEGER PRIMARY KEY);")
        edited = Punch::Migrations::Migrator.new(db, Punch::Migrations.from_directory(directory))
        edited.status.map(&.state.to_s).should eq(%w[Changed Pending])
        expect_raises(Punch::Migrations::Error, /applied migrations were changed afterwards: 20261001000000_a/) { edited.migrate }

        older = Punch::Migrations::Migrator.new(db, [] of Punch::Migrations::Migration)
        older.status.map(&.state.to_s).should eq(%w[Unknown])
        older.migrate.should be_empty
      end
    end
  end

  it "rebuilds a referenced table without cascading, and refuses one that breaks a foreign key" do
    Punch::Spec.database(file: true) do |db|
      Punch::Migrations::Migrator.new(db, Punch::Migrations.from_directory(FIXTURES)).migrate
      db.write do |writer|
        writer.exec("INSERT INTO customers (id, name) VALUES (1, 'Ada')")
        writer.exec("INSERT INTO invoices (customer_id, total_cents) VALUES (1, 500)")
      end
      rebuild = Punch::Migrations::Migration.from_file("20261003000000_rebuild_customers.sql", <<-SQL)
        CREATE TABLE customers_new (id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT) STRICT;
        INSERT INTO customers_new (id, name) SELECT id, name FROM customers;
        DROP TABLE customers;
        ALTER TABLE customers_new RENAME TO customers;
        SQL
      orphan = Punch::Migrations::Migration.from_file("20261004000000_orphan.sql", "DELETE FROM customers;")
      migrator = Punch::Migrations::Migrator.new(db, Punch::Migrations.from_directory(FIXTURES) + [rebuild, orphan])
      expect_raises(Punch::Migrations::Failed, /orphan.sql: foreign key violations: invoices row 1 references customers/) { migrator.migrate }
      db.read(&.query_one?("SELECT count(*) FROM invoices", &.read(Int64))).should eq(1)
      db.read(&.query_one?("SELECT count(*) FROM customers", &.read(Int64))).should eq(1)
      migrator.status.map(&.state.to_s).should eq(%w[Applied Applied Applied Pending])
      db.read(&.query_one?("PRAGMA foreign_keys", &.read(Int64))).should eq(1)
      db.write(&.query_one?("PRAGMA foreign_keys", &.read(Int64))).should eq(1)
    end
  end

  it "applies each migration once when two writers migrate one file at the same time" do
    Punch::Spec.database(file: true) do |db|
      other = Punch::Database.open(db.path)
      begin
        migrations = Punch::Migrations.from_directory(FIXTURES)
        applied = Channel(Int32).new(2)
        [db, other].each { |target| spawn { applied.send(Punch::Migrations::Migrator.new(target, migrations).migrate.size) } }
        (applied.receive + applied.receive).should eq(2)
        db.read(&.query_one?("SELECT count(*) FROM punch_schema_migrations", &.read(Int64))).should eq(2)
      ensure
        other.close
      end
    end
  end
end

describe Punch::Migrations::Schema do
  it "dumps tables, indexes, views, and triggers in a stable order, then the applied versions" do
    with_migrations({"20261001000000_all.sql" => <<-SQL}) do |directory|
      CREATE TABLE zebras (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL) STRICT;
      CREATE TABLE apples (id INTEGER PRIMARY KEY, name TEXT NOT NULL) STRICT;
      CREATE VIEW named AS SELECT name FROM zebras UNION ALL SELECT name FROM apples;
      CREATE VIEW counted AS SELECT count(*) AS n FROM named;
      CREATE INDEX apples_by_name ON apples (name);
      CREATE TRIGGER zebras_touch AFTER INSERT ON zebras BEGIN SELECT 1; END;
      CREATE VIRTUAL TABLE notes USING fts5(body);
      SQL
      Punch::Spec.database do |db|
        migrator = Punch::Migrations::Migrator.new(db, Punch::Migrations.from_directory(directory))
        migrator.migrate
        schema = Punch::Migrations::Schema.dump(db)
        statements = schema.lines.select(&.starts_with?("CREATE"))
        statements.map(&.split(/[ (]/)[0, 3].join(" ")).should eq([
          "CREATE TABLE apples", "CREATE VIRTUAL TABLE", "CREATE TABLE punch_schema_migrations",
          "CREATE TABLE zebras", "CREATE INDEX apples_by_name", "CREATE VIEW named", "CREATE VIEW counted",
          "CREATE TRIGGER zebras_touch",
        ])
        schema.should_not contain("sqlite_sequence")
        schema.should_not contain("notes_data")
        schema.should end_with("INSERT INTO punch_schema_migrations (version, name, checksum) VALUES\n  (20261001000000, 'all', '#{migrator.status.first.state.applied? && Punch::Migrations.from_directory(directory).first.checksum}');\n")

        Punch::Spec.database do |copy|
          Punch::Migrations::Schema.load(copy, schema)
          Punch::Migrations::Schema.dump(copy).should eq(schema)
          Punch::Migrations::Migrator.new(copy, Punch::Migrations.from_directory(directory)).status.map(&.state.to_s).should eq(%w[Applied])
        end
      end
    end
  end

  it "gives specs a database that starts from a schema file" do
    directory = File.tempname("punch-schema")
    Dir.mkdir(directory)
    path = File.join(directory, "schema.sql")
    Punch::Spec.database do |db|
      Punch::Migrations::Migrator.new(db, Punch::Migrations.from_directory(FIXTURES)).migrate
      File.write(path, Punch::Migrations::Schema.dump(db))
    end
    Punch::Spec.database(schema: path) do |db|
      tables(db).should eq(%w[customers invoices punch_schema_migrations])
      Punch::Migrations::Migrator.new(db, Punch::Migrations.from_directory(FIXTURES)).pending.should be_empty
    end
  ensure
    FileUtils.rm_rf(directory) if directory
  end

  it "names the line of an error when loading" do
    Punch::Spec.database do |db|
      expect_raises(Punch::Migrations::Error, /db\/schema.sql:2:1: no such table: main.missing/) do
        Punch::Migrations::Schema.load(db, "CREATE TABLE a (id INTEGER PRIMARY KEY);\nCREATE INDEX x ON missing (id);")
      end
      tables(db).should be_empty
    end
  end
end

private def open_unchecked(path : String) : Punch::Database
  Punch::Database.open(path, config: Punch::Database::Config.new(readers: 1, check_collations: false))
end

describe Punch::Database::CollationVersions do
  latin = Punch::Text::Collation::Latin::VERSION
  create = {"20261009090000_create_people.sql" => "CREATE TABLE people (name TEXT NOT NULL COLLATE de);\nCREATE INDEX people_by_name ON people (name COLLATE \"en\");\n"}

  it "records the versions of the collations the schema uses, also in schema.sql" do
    with_migrations(create) do |directory|
      Punch::Spec.database(file: true) do |db|
        Punch::Migrations::Migrator.new(db, Punch::Migrations.from_directory(directory)).migrate
        db.read { |reader| reader.query_all("SELECT name, version FROM punch_collations ORDER BY name") { |row| {row.read(String), row.read(String)} } }.should eq(
          [{"de", latin}, {"en", latin}])
        Punch::Migrations::Schema.dump(db).should end_with("INSERT INTO punch_collations (name, version) VALUES\n  ('de', '#{latin}'),\n  ('en', '#{latin}');\n")
      end
    end
  end

  it "refuses to open a database whose indexes were built with another version, until a migration reindexes" do
    with_migrations(create) do |directory|
      path = File.tempname("punch-collations", ".db")
      begin
        db = open_unchecked(path)
        Punch::Migrations::Migrator.new(db, Punch::Migrations.from_directory(directory)).migrate
        db.write(&.exec("UPDATE punch_collations SET version = 'old' WHERE name = 'de'"))
        db.close

        error = expect_raises(Punch::Database::CollationVersions::Changed) { Punch::Database.open(path) }
        error.message.to_s.should contain("de was old, is #{latin}")
        error.message.to_s.should contain("`REINDEX de;`")

        db = open_unchecked(path)
        expect_raises(Punch::Database::CollationVersions::Changed) { Punch::Migrations::Migrator.new(db, Punch::Migrations.from_directory(directory)).migrate }
        File.write(File.join(directory, "20261009100000_reindex.sql"), "REINDEX de;\n")
        Punch::Migrations::Migrator.new(db, Punch::Migrations.from_directory(directory)).migrate.map(&.name).should eq(["reindex"])
        db.close
        Punch::Database.open(path).close
      ensure
        File.delete?(path)
        File.delete?("#{path}-wal")
        File.delete?("#{path}-shm")
      end
    end
  end

  it "versions Punch's lower, upper, and like in indexes, until a migration rebuilds expression indexes" do
    functions = Punch::Database::CollationVersions::FUNCTION_VERSION
    indexed = {"20261101090000_create_tags.sql" => "CREATE TABLE tags (name TEXT NOT NULL, note TEXT) STRICT;\n" \
                                                   "CREATE UNIQUE INDEX tags_name ON tags (lower(name));\nCREATE INDEX tags_noted ON tags (name) WHERE note LIKE 'x%';\n" \
                                                   "CREATE INDEX tags_note ON tags (note);\n"}
    with_migrations(indexed) do |directory|
      path = File.tempname("punch-functions", ".db")
      begin
        db = open_unchecked(path)
        Punch::Migrations::Migrator.new(db, Punch::Migrations.from_directory(directory)).migrate
        db.read { |reader| reader.query_all("SELECT name, version FROM punch_collations ORDER BY name") { |row| {row.read(String), row.read(String)} } }.should eq(
          [{"like()", functions}, {"lower()", functions}])
        db.write(&.exec("UPDATE punch_collations SET version = 'old' WHERE name = 'lower()'"))
        db.close

        error = expect_raises(Punch::Database::CollationVersions::Changed) { Punch::Database.open(path) }
        error.message.to_s.should contain("lower() was old, is #{functions}")
        error.message.to_s.should contain("`REINDEX EXPRESSIONS;`")

        db = open_unchecked(path)
        File.write(File.join(directory, "20261101100000_reindex.sql"), "REINDEX EXPRESSIONS;\n")
        Punch::Migrations::Migrator.new(db, Punch::Migrations.from_directory(directory)).migrate.map(&.name).should eq(["reindex"])
        db.close
        Punch::Database.open(path).close
      ensure
        File.delete?(path)
        File.delete?("#{path}-wal")
        File.delete?("#{path}-shm")
      end
    end
  end

  it "takes a bare REINDEX as rebuilding everything" do
    Punch::Database::CollationVersions.reindexed("REINDEX;").should contain("lower()")
    Punch::Database::CollationVersions.reindexed("REINDEX;").should contain(Punch::Database::CollationVersions::ALL)
    Punch::Database::CollationVersions.reindexed("REINDEX de;").should eq(Set{"de"})
    Punch::Database::CollationVersions.reindexed("REINDEX expressions;").should contain("upper()")
  end
end
