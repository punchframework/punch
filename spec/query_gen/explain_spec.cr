require "../spec_helper"
require "../../src/punch/query_gen"

private SCHEMA = <<-SQL
  CREATE TABLE customers (id INTEGER PRIMARY KEY, owner_id INTEGER NOT NULL, name TEXT NOT NULL, email TEXT NOT NULL) STRICT;
  CREATE INDEX customers_by_owner ON customers (owner_id, name);
  CREATE TABLE lines (id INTEGER PRIMARY KEY, customer_id INTEGER NOT NULL, amount INTEGER NOT NULL) STRICT;
  SQL

# The plan reports of *queries*, one query file, against SCHEMA. Examples
# run one at a time, so changing the working directory is safe here.
private def explain(queries : String) : Array(Punch::QueryGen::Explain::Report)
  directory = File.tempname("punch-explain")
  begin
    Dir.mkdir_p(File.join(directory, "db"))
    Dir.mkdir_p(File.join(directory, "app/shop"))
    File.write(File.join(directory, "db/schema.sql"), SCHEMA)
    File.write(File.join(directory, "app/shop/queries.sql"), queries)
    Dir.cd(directory) do
      Punch::QueryGen.run(Punch::QueryGen::Config.new(queries: Punch::QueryGen.query_files, explain: true)).plans
    end
  ensure
    FileUtils.rm_rf(directory)
  end
end

private def kinds(report : Punch::QueryGen::Explain::Report) : Array(String)
  report.findings.map(&.[0].kind)
end

describe Punch::QueryGen::Explain do
  it "finds nothing in a query an index serves, filter and order alike" do
    report = explain(<<-SQL).first
      -- name: Names :many
      SELECT id, name FROM customers WHERE owner_id = :owner_id ORDER BY name;
      SQL
    report.plans.map(&.label).should eq(["as written"])
    report.plans.first.steps.first.detail.should start_with("SEARCH customers USING")
    report.findings.should be_empty
    report.problems.should be_empty
  end

  it "finds a full scan, also through an index, and a sort, with a way out" do
    reports = explain(<<-SQL)
      -- name: ByEmail :one
      SELECT id FROM customers WHERE email = :email;

      -- name: AllNames :many
      SELECT name FROM customers ORDER BY owner_id, name;

      -- name: Totals :many
      SELECT customer_id, sum(amount) AS total FROM lines GROUP BY customer_id ORDER BY total;
      SQL
    by_email, all_names, totals = reports
    by_email.findings.map(&.[0].text).should eq(["reads every row of customers"])
    by_email.problems.should eq(["app/shop/queries.sql:1:1: query ByEmail reads every row of customers. " \
                                 "Add an index that serves it, or say why it is fine in the header: `-- scan: <reason>`."])
    all_names.findings.map(&.[0].text).should eq(["reads every row of customers (through customers_by_owner)"])
    kinds(totals).should eq(%w[scan sort sort])
  end

  it "accepts a finding whose kind the header names with a reason, and refuses a stale acceptance" do
    accepted = explain(<<-SQL).first
      -- name: Totals :many
      -- Every customer's total, for the nightly export.
      -- scan: the export reads every line once a night
      -- sort: as above
      SELECT customer_id, sum(amount) AS total FROM lines GROUP BY customer_id;
      SQL
    accepted.query.accepted.transform_values(&.[0]).should eq({"scan" => "the export reads every line once a night", "sort" => "as above"})
    accepted.query.doc.should eq(["Every customer's total, for the nightly export."])
    accepted.problems.should be_empty

    stale = explain(<<-SQL).first
      -- name: Names :many
      -- sort: a few rows
      SELECT name FROM customers WHERE owner_id = :owner_id ORDER BY name;
      SQL
    stale.problems.should eq(["app/shop/queries.sql:2:1: query Names: no statement of it has a sort; remove `-- sort:`."])
  end

  it "explains each order with no filter and with each when, and names the statement that sorts" do
    report = explain(<<-SQL).first
      -- name: Search :many
      SELECT id, name FROM customers
      WHERE owner_id = :owner_id
      -- when email: AND email = :email
      -- when named: AND name = :named
      -- order name: ORDER BY name
      -- order email: ORDER BY email
      SQL
    labels = report.plans.map(&.label)
    labels.should contain("no filter, order email")
    labels.should contain("only when email, order name")
    report.findings.should eq([{Punch::QueryGen::Explain::Finding.new("sort", "sorts every row it reads for ORDER BY"), "no filter, order email"}])
    report.plans.reject(&.findings.empty?).map(&.label).should eq(["no filter, order email", "only when named, order email"])
  end

  it "explains a page after a cursor with each order" do
    report = explain(<<-SQL).first
      -- name: Page :page
      SELECT * FROM customers
      WHERE owner_id = :owner_id
      -- when named: AND name = :named
      -- order name: ORDER BY name, id
      SQL
    report.plans.map(&.label).should contain("no filter, order name, after a cursor")
    report.findings.should be_empty
  end

  it "does not count a scan of a subquery or CTE" do
    explain(<<-SQL).first.findings.should be_empty
      -- name: Recent :many
      WITH mine AS (SELECT id, name FROM customers WHERE owner_id = :owner_id ORDER BY name LIMIT 10)
      SELECT id FROM mine;
      SQL
  end

  it "needs a reason for an acceptance" do
    error = expect_raises(Punch::QueryGen::Errors) { explain("-- name: A :many\n-- scan:\nSELECT id FROM customers;\n") }
    error.errors.map(&.to_s).should eq(["app/shop/queries.sql:2:1: query A: scan: say why the full scan is fine, such as `-- scan: a few rows per customer`"])
  end
end
