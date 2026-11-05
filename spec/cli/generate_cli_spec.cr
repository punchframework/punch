require "../spec_helper"
require "../../src/punch/cli/tool"

private record Run, code : Int32, stdout : String, stderr : String

private def punch(*args : String) : Run
  stdout, stderr = IO::Memory.new, IO::Memory.new
  code = Punch::CLI.run(args.to_a, stdout, stderr, Punch::CLI::TOOL_COMMANDS)
  Run.new(code, stdout.to_s, stderr.to_s)
end

# Runs the block in a fresh app directory with the generator fixture's
# schema and one query file. Examples run one at a time, so changing the
# working directory is safe here.
private def in_app(& : ->)
  directory = File.tempname("punch-app")
  Dir.mkdir_p(File.join(directory, "db"))
  Dir.mkdir_p(File.join(directory, "app/shop"))
  File.copy("#{__DIR__}/../query_gen/fixture/db/schema.sql", File.join(directory, "db/schema.sql"))
  File.write(File.join(directory, "app/shop/columns.cr"), %(Punch.table "invoices", Shop::Invoices, id: Shop::Invoices::ID\n))
  File.write(File.join(directory, "app/shop/queries.sql"), "-- name: Open :many\nSELECT id, number FROM invoices WHERE status = :status;\n")
  begin
    Dir.cd(directory) { yield }
  ensure
    FileUtils.rm_rf(directory)
  end
end

describe "punch db:generate" do
  it "writes the records and query files, then leaves them alone" do
    in_app do
      run = punch("db:generate")
      run.code.should eq(0)
      run.stdout.should eq("written   app/shop/records.gen.cr\nwritten   app/shop/queries.gen.cr\n1 queries (0 with annotations), 1 mapped tables (0 with behaviour), 1 violation types.\n")
      File.read("app/shop/queries.gen.cr").should contain("def self.open(db : Punch::Reader | Punch::Writer, *, status : String) : Array(Open::Row)")
      punch("db:generate").stdout.should start_with("unchanged app/shop/records.gen.cr\nunchanged app/shop/queries.gen.cr\n")
    end
  end

  it "reports every query with its types as JSON" do
    in_app do
      document = JSON.parse(punch("db:generate", "--json").stdout)
      document["files"].as_a.map(&.["state"].as_s).should eq(%w[written written])
      query = document["queries"][0]
      query["name"].should eq("Open")
      query["location"].should eq("app/shop/queries.sql:1:1")
      query["kind"].should eq("many")
      query["returns"].should eq("Open::Row")
      query["columns"].as_a.map { |column| {column["name"].as_s, column["type"].as_s, column["source"].as_s} }.should eq(
        [{"id", "Shop::Invoices::ID", "metadata"}, {"number", "String", "metadata"}])
      query["params"][0]["source"].should eq("inferred")
      query["includes"].should eq(JSON.parse("[]"))
      query["violations"].should eq(JSON.parse("[]"))
      violation = %({"type": "Shop::Invoices::NumberTaken", "constraint": "invoices.account_id, invoices.number", "index": "sqlite_autoindex_invoices_1", "field": "number"})
      table = %({"name": "invoices", "module": "Shop::Invoices", "behaviour": "app/shop/invoices/record.cr", "behaviour_exists": false, "violations": [#{violation}]})
      document["tables"].should eq(JSON.parse("[#{table}]"))
      Dir.mkdir_p("app/shop/invoices")
      File.write("app/shop/invoices/record.cr", "struct Shop::Invoices::Record\nend\n")
      JSON.parse(punch("db:generate", "--json").stdout)["tables"][0]["behaviour_exists"].should be_true
    end
  end

  it "reports a query's declared clauses as JSON" do
    in_app do
      File.write("app/shop/queries.sql", <<-SQL)
        -- name: Open :many
        SELECT id FROM invoices WHERE account_id = :account_id
        -- when status: AND status = :status
        -- when unsent: AND sent_at IS NULL
        -- order created: ORDER BY id
        -- order number: ORDER BY number, id
        SQL
      query = JSON.parse(punch("db:generate", "--json").stdout)["queries"][0]
      query["filter"].should eq(JSON.parse(<<-JSON))
        [{"name": "status", "type": "String?", "location": "app/shop/queries.sql:3:17"},
         {"name": "unsent", "type": "Bool", "location": "app/shop/queries.sql:4:17"}]
        JSON
      query["orders"].should eq(JSON.parse(%(["created", "number"])))
      # As written, each clause alone, every clause with each order, and
      # with each order read backwards.
      query["variants"].should eq(7)
      query["params"].as_a.map(&.["name"].as_s).should eq(%w[account_id status])
    end
  end

  it "reports an enum filter field with its members as JSON" do
    in_app do
      File.write("app/shop/queries.sql", <<-SQL)
        -- name: InState :many
        -- param state: Shop::Invoice::State
        SELECT id FROM invoices WHERE account_id = :account_id
        -- when state = draft: AND status = 'draft'
        -- when state = sent: AND status = 'sent'
        SQL
      JSON.parse(punch("db:generate", "--json").stdout)["queries"][0]["filter"].should eq(JSON.parse(<<-JSON))
        [{"name": "state", "type": "Shop::Invoice::State?", "members": ["draft", "sent"], "location": "app/shop/queries.sql:4:24"}]
        JSON
    end
  end

  it "reports a page query's cursor per order as JSON" do
    in_app do
      File.write("app/shop/queries.sql", <<-SQL)
        -- name: Listed :page
        SELECT id, number FROM invoices WHERE account_id = :account_id
        -- order created: ORDER BY id
        -- order number: ORDER BY number, id
        SQL
      query = JSON.parse(punch("db:generate", "--json").stdout)["queries"][0]
      query["kind"].should eq("page")
      query["pages"].should eq(JSON.parse(<<-JSON))
        [{"order": "created", "direction": "asc", "cursor": ["id"], "after": "AND id > ?"},
         {"order": "created", "direction": "desc", "cursor": ["id"], "after": "AND id < ?"},
         {"order": "number", "direction": "asc", "cursor": ["number", "id"], "after": "AND (number, id) > (?, ?)"},
         {"order": "number", "direction": "desc", "cursor": ["number", "id"], "after": "AND (number, id) < (?, ?)"}]
        JSON
      # As written, each order both ways, each of those after a cursor, and by key.
      query["variants"].should eq(10)
    end
  end

  it "--check fails on stale files without writing" do
    in_app do
      punch("db:generate", "--check").code.should eq(1)
      File.exists?("app/shop/queries.gen.cr").should be_false
      punch("db:generate")
      punch("db:generate", "--check").stdout.should start_with("current   app/shop/records.gen.cr\n")
      File.write("app/shop/queries.sql", "-- name: Open :many\nSELECT id FROM invoices WHERE status = :status;\n")
      run = punch("db:generate", "--check", "--json")
      run.code.should eq(1)
      error = JSON.parse(run.stdout)["error"]
      error["code"].should eq("stale_generated_files")
      error["message"].as_s.should start_with("app/shop/queries.gen.cr does not match")
    end
  end

  it "reports mistakes with file, line, and column" do
    in_app do
      File.write("app/shop/queries.sql", "-- name: Open :many\nSELECT id, numbr FROM invoices;\n")
      run = punch("db:generate")
      run.code.should eq(1)
      run.stderr.should eq("punch: app/shop/queries.sql:2:12: query Open: no such column: numbr\n")
      File.exists?("app/shop/queries.gen.cr").should be_false
    end
  end

  it "needs the schema file" do
    in_app do
      File.delete("db/schema.sql")
      JSON.parse(punch("db:generate", "--json").stdout)["error"]["code"].should eq("missing_schema")
      punch("db:generate", "--force").code.should eq(2)
    end
  end
end
