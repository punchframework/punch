require "../spec_helper"
require "../../src/punch/migrations/cost"

private BASE = <<-SQL
  CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT NOT NULL) STRICT;
  CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT);
  CREATE TABLE invoices (id INTEGER PRIMARY KEY, customer_id INTEGER NOT NULL REFERENCES customers (id), total INTEGER NOT NULL) STRICT;
  SQL

# The report of the last of *sqls*, each one migration, after BASE.
private def costs(*sqls : String) : Punch::Migrations::Costs::Report
  migrations = ([BASE] + sqls.to_a).map_with_index do |sql, index|
    Punch::Migrations::Migration.new(20261001000000_i64 + index, "m#{index}", sql, "db/migrations/m#{index}.sql")
  end
  Punch::Migrations::Costs.classify(migrations).last
end

private def cost_of(sql : String) : {Punch::Migrations::Cost, String?}
  statement = costs(sql).statements.first
  {statement.cost, statement.table}
end

describe Punch::Migrations::Costs do
  it "counts schema-only statements as instant" do
    cost_of("CREATE TABLE tags (id INTEGER PRIMARY KEY) STRICT;").should eq({Punch::Migrations::Cost::Instant, "tags"})
    cost_of("ALTER TABLE notes ADD COLUMN title TEXT;").should eq({Punch::Migrations::Cost::Instant, "notes"})
    cost_of("ALTER TABLE customers RENAME COLUMN name TO full_name;")[0].instant?.should be_true
    cost_of("ALTER TABLE customers RENAME TO clients;").should eq({Punch::Migrations::Cost::Instant, "clients"})
    cost_of("ALTER TABLE customers ALTER COLUMN name DROP NOT NULL;")[0].instant?.should be_true
    cost_of("CREATE VIEW names AS SELECT name FROM customers;")[0].instant?.should be_true
    cost_of("CREATE TRIGGER t AFTER INSERT ON notes BEGIN SELECT 1; END;")[0].instant?.should be_true
    cost_of("INSERT INTO notes (body) VALUES ('hello');")[0].instant?.should be_true
    cost_of("CREATE TABLE tags (id INTEGER PRIMARY KEY);\nCREATE INDEX tags_by_id ON tags (id);\nDROP INDEX tags_by_id;\nDROP TABLE tags;").should eq({Punch::Migrations::Cost::Instant, "tags"})
    costs("CREATE TABLE tags (id INTEGER PRIMARY KEY);\nCREATE INDEX tags_by_id ON tags (id);\nDROP INDEX tags_by_id;\nDROP TABLE tags;").cost.instant?.should be_true
  end

  it "counts what reads every row of an existing table as a scan" do
    cost_of("CREATE INDEX customers_by_name ON customers (name);").should eq({Punch::Migrations::Cost::Scan, "customers"})
    cost_of("ALTER TABLE customers ALTER COLUMN email SET NOT NULL;")[0].scan?.should be_true
    cost_of("ALTER TABLE invoices ADD CHECK (total >= 0);")[0].scan?.should be_true
    cost_of("UPDATE customers SET name = trim(name);").should eq({Punch::Migrations::Cost::Scan, "customers"})
    cost_of("DELETE FROM notes WHERE body IS NULL;").should eq({Punch::Migrations::Cost::Scan, "notes"})
    cost_of("DROP TABLE notes;").should eq({Punch::Migrations::Cost::Scan, "notes"})
    costs("CREATE INDEX notes_by_body ON notes (body);", "DROP INDEX notes_by_body;").statements.first.cost.scan?.should be_true
    cost_of("REINDEX de;")[0].scan?.should be_true
    cost_of("WITH old AS (SELECT id FROM notes) DELETE FROM notes WHERE id IN (SELECT id FROM old);").should eq({Punch::Migrations::Cost::Scan, "notes"})
  end

  it "knows when SQLite checks every row on ADD COLUMN: STRICT tables, CHECK, generated NOT NULL" do
    statement = costs("ALTER TABLE customers ADD COLUMN locale TEXT;").statements.first
    statement.cost.scan?.should be_true
    statement.reason.should contain("STRICT")
    cost_of("ALTER TABLE notes ADD COLUMN size INTEGER CHECK (size > 0);")[0].scan?.should be_true
    cost_of("ALTER TABLE notes ADD COLUMN size INTEGER GENERATED ALWAYS AS (length(body)) NOT NULL;")[0].scan?.should be_true
    cost_of("ALTER TABLE notes ADD COLUMN size INTEGER GENERATED ALWAYS AS (length(body));")[0].instant?.should be_true
  end

  it "counts statements on a table the migration created as instant, until it is filled from a query" do
    report = costs(<<-SQL)
      CREATE TABLE tags (id INTEGER PRIMARY KEY, name TEXT NOT NULL) STRICT;
      CREATE INDEX tags_by_name ON tags (name);
      ALTER TABLE tags ADD COLUMN color TEXT;
      INSERT INTO tags (name) SELECT DISTINCT name FROM customers;
      CREATE UNIQUE INDEX tags_by_color ON tags (color, name);
      SQL
    report.statements.map(&.cost.to_s).should eq(%w[Instant Instant Instant Scan Scan])
    report.cost.scan?.should be_true
    report.rebuilds.should be_empty
    report.problems.should be_empty
  end

  it "finds a rebuild through the 12-step procedure and requires an acknowledgement naming the table" do
    rebuild = <<-SQL
      CREATE TABLE customers_new (id INTEGER PRIMARY KEY, name TEXT NOT NULL COLLATE de, email TEXT NOT NULL) STRICT;
      INSERT INTO customers_new (id, name, email) SELECT id, name, email FROM customers;
      DROP TABLE customers;
      ALTER TABLE customers_new RENAME TO customers;
      CREATE INDEX customers_by_name ON customers (name);
      SQL
    report = costs(rebuild)
    report.statements.map(&.cost.to_s).should eq(%w[Instant Rebuild Rebuild Rebuild Scan])
    report.statements[1].line.should eq(2)
    report.rebuilds.should eq(%w[customers])
    report.cost.rebuild?.should be_true
    problem = report.problems.first
    problem.should start_with("db/migrations/m1.sql:2: rebuilds customers")
    problem.should contain("-- rebuild: customers")

    acknowledged = costs("-- The collation changes, which SQLite cannot do in place.\n-- rebuild: customers\n#{rebuild}")
    acknowledged.acknowledged.should eq(%w[customers])
    acknowledged.problems.should be_empty
  end

  it "counts DROP COLUMN as a rebuild" do
    report = costs("ALTER TABLE invoices DROP COLUMN total;")
    report.statements.first.cost.rebuild?.should be_true
    report.rebuilds.should eq(%w[invoices])
    costs("-- rebuild: Invoices\nALTER TABLE invoices DROP COLUMN total;").problems.should be_empty
  end

  it "rejects an acknowledgement of a table the migration does not rebuild" do
    report = costs("-- rebuild: customers, notes\nALTER TABLE notes DROP COLUMN body;")
    report.problems.should eq(["db/migrations/m1.sql: '-- rebuild: customers' names a table the migration does not rebuild; remove the line."])
  end

  it "counts a statement it does not know as a scan, saying so" do
    statement = costs("PRAGMA user_version = 3;").statements.first
    statement.cost.scan?.should be_true
    statement.reason.should contain("does not know")
  end

  it "reports a migration that does not run with its file and line" do
    expect_raises(Punch::Migrations::Failed, "db/migrations/m1.sql:2:") do
      costs("CREATE TABLE a (id INTEGER PRIMARY KEY);\nCREATE INDEX b ON missing (id);")
    end
  end
end
