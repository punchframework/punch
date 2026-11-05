require "../spec_helper"
require "../../src/punch/query_gen"

private FIXTURE = "#{__DIR__}/fixture"

# Runs the generator in *directory*. Examples run one at a time, so changing
# the working directory is safe here.
private def generate(directory : String = FIXTURE) : Punch::QueryGen::Result
  Dir.cd(directory) do
    Punch::QueryGen.run(Punch::QueryGen::Config.new(queries: Punch::QueryGen.query_files))
  end
end

# A throwaway app with the fixture's schema, and *files* on top.
private def with_app(files : Hash(String, String), & : String ->) : Nil
  directory = File.tempname("punch-gen")
  begin
    Dir.mkdir_p(File.join(directory, "db"))
    File.copy(File.join(FIXTURE, "db/schema.sql"), File.join(directory, "db/schema.sql"))
    files.each do |path, content|
      Dir.mkdir_p(File.dirname(File.join(directory, path)))
      File.write(File.join(directory, path), content)
    end
    yield directory
  ensure
    FileUtils.rm_rf(directory)
  end
end

# The error lines of a run that must fail.
private def errors_for(files : Hash(String, String)) : Array(String)
  lines = [] of String
  with_app(files) do |directory|
    error = expect_raises(Punch::QueryGen::Errors) { generate(directory) }
    lines = error.errors.map(&.to_s)
  end
  lines
end

private def query_errors(sql : String) : Array(String)
  errors_for({"app/shop/queries.sql" => sql})
end

# Errors of *sql* in an app that encrypts `contacts.phone`.
private def encrypted_query_errors(sql : String) : Array(String)
  errors_for({"app/shop/queries.sql" => sql, "app/shop/columns.cr" => %(Punch.table "contacts", Shop::Contacts, phone: Punch::Encrypted(Punch::NonEmptyString)\n)})
end

# Errors of *sql* in an app that encrypts `contacts.phone` and `note`,
# with the blind index `phone_index`.
private def blind_query_errors(sql : String) : Array(String)
  errors_for({"app/shop/queries.sql" => sql, "app/shop/columns.cr" => <<-CRYSTAL})
    Punch.table "contacts", Shop::Contacts,
      phone: Punch::Encrypted(Punch::NonEmptyString),
      note: Punch::Encrypted(String),
      phone_index: Punch::BlindIndex.of(:phone)
    CRYSTAL
end

private def mapping_errors(mapping : String) : Array(String)
  errors_for({"app/shop/columns.cr" => mapping})
end

private def analysis(result : Punch::QueryGen::Result, name : String) : Punch::QueryGen::Analysis
  result.analyses.find(&.query.name.==(name)) || fail "no query #{name}"
end

private def types(analysis : Punch::QueryGen::Analysis) : Hash(String, String)
  analysis.columns.to_h { |column| {column.name, column.type.crystal} }
end

private def param_types(analysis : Punch::QueryGen::Analysis) : Hash(String, String)
  analysis.params.to_h { |param| {param.name, param.type.crystal} }
end

describe Punch::QueryGen do
  it "writes exactly the committed fixture files, formatted" do
    result = generate
    result.outputs.map(&.path).should eq(%w[app/ledger/composites.gen.cr app/ledger/records.gen.cr app/ledger/orders/records.gen.cr app/ledger/sites/records.gen.cr app/ledger/queries.gen.cr])
    result.outputs.each do |output|
      output.content.should eq(File.read(File.join(FIXTURE, output.path)))
      Crystal.format(output.content).should eq(output.content)
    end
  end

  # 32 plain queries; the fixture adds Literals (escaping in the
  # generated heredoc), CountFiltered (a clause without a parameter), two
  # pages (keyset pagination), InvoicesInState (an enum filter field), two
  # queries of encrypted columns, three of a blind index, three of
  # columns being converted, two with array parameters, and six of
  # composites.
  it "derives 165 of 167 types of the plain queries without annotations" do
    result = generate
    plain = result.analyses.reject(&.query.name.in?("Literals", "CountFiltered", "InvoicePage", "CustomerPage", "InvoicesInState", "ContactPhones", "SetContactNote", "ContactByPhone", "ContactIds", "SetContactPhone", "LeadByEmail", "OldLeadByEmail", "ProspectNames", "InvoicesIn", "ContactsByPhones",
      "SitesInCity", "SiteCities", "SiteById", "OrdersIn", "OrdersToCountry", "SetPayment"))
    plain.size.should eq(32)
    columns = plain.flat_map(&.columns)
    params = plain.flat_map(&.params)
    annotated = columns.count(&.source.annotation?) + params.count(&.source.annotation?)
    {columns.size + params.size, annotated}.should eq({167, 2})
    plain.count { |item| item.columns.none?(&.source.annotation?) && item.params.none?(&.source.annotation?) }.should eq(30)
  end

  describe "declared clauses" do
    it "gives each when clause a filter field typed from its parameter, and each order a choice" do
      search = analysis(generate, "Search")
      filtered = search.filtered || fail "Search has no clauses"
      filtered.fields.map { |field| {field.clause.key, field.param.try(&.type.nilable.crystal)} }.should eq(
        [{"status", "String?"}, {"customer_id", "Ledger::Customers::ID?"}, {"issued_from", "String?"}, {"q", "Punch::LikeText?"}])
      filtered.orders.map(&.key).should eq(%w[issued amount])
      search.params.map(&.name).should eq(%w[account_id status customer_id issued_from q limit offset])
      toggle = analysis(generate, "CountFiltered").filtered.try(&.fields.first) || fail "no field"
      {toggle.clause.key, toggle.param}.should eq({"unsent", nil})
    end

    it "prepares the query as written, each clause alone, and every clause with each order" do
      filtered = analysis(generate, "Search").filtered || fail "Search has no clauses"
      filtered.variants.map(&.[0]).should eq([
        "as written", "with every when and order issued", "with only when status", "with only when customer_id",
        "with only when issued_from", "with only when q", "with every when and order amount",
        # Each order read backwards (`direction: :desc`).
        "with every when and order issued desc", "with every when and order amount desc",
      ])
      written = filtered.variants.first[1]
      written.should contain("-- when status:       AND i.status = :status")
      filtered.variants[1][1].should contain("\n                      AND i.status = :status\n")
      filtered.variants[1][1].should contain("ORDER BY i.issued_on, i.id")
      filtered.variants[1][1].should contain("\n-- order amount:      ORDER BY i.total_cents")
      filtered.variants.last[1].should contain("ORDER BY i.total_cents DESC, i.id DESC")
    end

    it "splits the statement into fixed pieces and clauses with positional parameters" do
      filtered = analysis(generate, "Search").filtered || fail "Search has no clauses"
      filtered.pieces.map { |piece| {piece.clause.try(&.key), piece.sql, piece.params} }.should eq([
        {nil, "SELECT i.id, i.number, i.total_cents, i.status, c.name AS customer_name\nFROM invoices i\nJOIN customers c ON c.id = i.customer_id\nWHERE i.account_id = ?", ["account_id"]},
        {"status", "AND i.status = ?", ["status"]},
        {"customer_id", "AND i.customer_id = ?", ["customer_id"]},
        {"issued_from", "AND i.issued_on >= ?", ["issued_from"]},
        {"q", %q(AND c.name LIKE '%' || ? || '%' ESCAPE '\'), ["q"]},
        {"issued", "ORDER BY i.issued_on, i.id", [] of String},
        {"amount", "ORDER BY i.total_cents, i.id", [] of String},
        {nil, "LIMIT ? OFFSET ?", ["limit", "offset"]},
      ])
    end

    it "points at the column inside a clause" do
      query_errors("-- name: Bad :many\nSELECT id FROM invoices\nWHERE account_id = :account_id\n-- when status:  AND stauts = :status\n").should eq(
        ["app/shop/queries.sql:4:22: query Bad: no such column: stauts"])
      query_errors("-- name: Bad :many\nSELECT id FROM invoices\nWHERE account_id = :account_id\n-- order newest: ORDER BY created\n-- order old: ORDER BY id\n").should eq(
        ["app/shop/queries.sql:4:27: query Bad: no such column: created"])
      query_errors("-- name: Bad :many\nSELECT id FROM invoices\nWHERE account_id = :account_id\n-- order newest: ORDER BY id\n-- order old: ORDER BY created\n").should eq(
        ["app/shop/queries.sql:5:24: query Bad: with every when and order old: no such column: created"])
    end

    it "refuses clauses that could widen the query rather than narrow it" do
      base = "-- name: Wide :many\nSELECT id FROM invoices\nWHERE account_id = :account_id\n"
      query_errors(base + "-- when status: OR status = :status\n").should eq(
        ["app/shop/queries.sql:4:17: query Wide: when status: a clause narrows the condition before it, so it starts with AND"])
      query_errors(base + "-- when status: AND status = :status OR 1\n").should eq(
        ["app/shop/queries.sql:4:38: query Wide: when status: an OR outside parentheses would let in rows the rest of the condition excludes; write AND (… OR …)"])
      query_errors("-- name: Wide :many\nSELECT id FROM invoices\nWHERE account_id = :account_id OR note IS NULL\n-- when status: AND status = :status\n").should eq(
        ["app/shop/queries.sql:3:32: query Wide: when status: the condition it extends has an OR outside parentheses, so the clause would not narrow all of it; put that OR in parentheses"])
      query_errors(base + "-- when status: AND status = :status\n  OR note IS NULL\n").first.should contain("the condition it extends has an OR outside parentheses")
      query_errors("-- name: Wide :many\nSELECT id FROM invoices\n-- when status: AND status = :status\n").should eq(
        ["app/shop/queries.sql:3:17: query Wide: when status: a clause extends a WHERE, HAVING, or ON condition; write one before it, `WHERE true` if nothing else"])
      # Parentheses keep an OR inside, and CASE … END counts as parentheses.
      errors_for({"app/shop/queries.sql" => base.sub("WHERE", "WHERE (status = 'a' OR status = 'b') AND") +
                                            %q(-- when q: AND (note LIKE :q ESCAPE '\' OR number LIKE :q ESCAPE '\')) + "\n-- when due: AND CASE WHEN due_on IS NULL OR 1 THEN 1 END\n" +
                                            "-- when bad: AND numbr = 1\n"}).should eq(["app/shop/queries.sql:6:18: query Wide: no such column: numbr"])
    end

    it "refuses clauses on writes, and orders that are not plain ORDER BY" do
      query_errors("-- name: Purge :exec\nDELETE FROM payments WHERE invoice_id = :invoice_id\n-- when big: AND amount_cents > 100\n").should eq(
        ["app/shop/queries.sql:3:14: query Purge: declared clauses narrow reads; a write states its conditions as parameters"])
      base = "-- name: Sorted :many\nSELECT id FROM invoices WHERE true\n"
      query_errors(base + "-- order by: id\n").first.should contain("order by: an order clause is `ORDER BY …`")
      query_errors(base + "-- order by: ORDER BY :column\n").first.should contain("order by: an order takes no parameters (:column)")
      query_errors(base + "-- order a: ORDER BY id\nLIMIT 5\n-- order b: ORDER BY number\n").first.should contain("order clauses go on consecutive lines")
      query_errors(base + "-- order newest: ORDER BY created_at DESC, id DESC\n").should eq(["app/shop/queries.sql:3:18: query Sorted: order newest: write an order " +
                                                                                             "ascending in its first term, and `direction: :desc` reads it backwards, so that asc and desc say what they mean"])
    end

    it "ties each clause to one parameter of its own name" do
      base = "-- name: Fields :many\nSELECT id FROM invoices\nWHERE account_id = :account_id\n"
      query_errors(base + "-- when issued: AND issued_on BETWEEN :from AND :to\n").first.should contain(
        "when issued: one parameter per clause (it has :from, :to); split it into clauses")
      query_errors(base + "-- when state: AND status = :status\n").first.should contain(
        "when state: name the clause after its parameter, `-- when status:`")
      query_errors(base + "-- when account_id: AND customer_id = :account_id\n").first.should contain(
        "when account_id: :account_id is used outside this clause too")
      query_errors("-- name: Fields :many\nSELECT id FROM payments\nWHERE true\n-- when raw: AND raw = :raw\n").first.should contain(
        "when raw: :raw is Bytes, which a filter cannot read from a query string")
      query_errors("-- name: Fields :many\nSELECT id FROM invoices WHERE customer_id = :order\n-- when status: AND status = :status\n").first.should contain(
        "parameter :order: the method of a query with clauses uses this name")
      query_errors(base + "-- when status: AND status = :status\n-- when status: AND note = :status\n").first.should contain(
        "when status is declared twice")
      query_errors(base + "-- when Status: AND status = :status\n").first.should contain("when Status: name the clause in snake_case")
      query_errors("-- name: Fields :many\n-- when status: AND status = :status\nSELECT id FROM invoices WHERE true;\n").first.should contain(
        "a clause goes inside the statement, where it applies, not in the header")
      query_errors("-- name: Fields :many\nSELECT id FROM invoices WHERE true\n-- when status: , number\n").first.should contain("starts with AND")
    end
  end

  describe "enum filter fields" do
    it "makes one field of an enum's member clauses, each clause its own piece" do
      filtered = analysis(generate, "InvoicesInState").filtered || fail "InvoicesInState has no clauses"
      filtered.fields.map { |field| {field.key, field.type, field.members.map(&.member)} }.should eq(
        [{"state", "Ledger::InvoiceState?", ["draft", "sent", "paid"]}, {"customer_id", "Ledger::Customers::ID?", [] of String?}])
      filtered.pieces.compact_map(&.clause).map(&.label).should eq(["state = draft", "state = sent", "state = paid", "customer_id"])
      filtered.variants.map(&.[0]).should contain("with only when state = paid")
    end

    it "emits a case over the enum, so the compiler checks every member has a clause" do
      source = File.read("#{FIXTURE}/app/ledger/queries.gen.cr")
      source.should contain(%(WHEN_STATE_PAID  = "AND EXISTS (SELECT 1 FROM payments p WHERE p.invoice_id = i.id)"))
      source.should contain("getter state : Ledger::InvoiceState?")
      lines = source.lines.map(&.strip)
      at = lines.index("case value") || fail "no case over the enum"
      lines[at + 1, 4].should eq([
        "in .draft? then io << InvoicesInState::WHEN_STATE_DRAFT << '\\n'",
        "in .sent?  then io << InvoicesInState::WHEN_STATE_SENT << '\\n'",
        "in .paid?  then io << InvoicesInState::WHEN_STATE_PAID << '\\n'",
        "end",
      ])
      lines[at - 2].should eq("# One clause per member of Ledger::InvoiceState (app/ledger/queries.sql:232).")
    end

    it "refuses member clauses without their enum, with a parameter, or mixed with a field's own clause" do
      base = "-- name: States :many\nSELECT id FROM invoices\nWHERE account_id = :account_id\n"
      query_errors(base + "-- when state = draft: AND status = 'draft'\n").should eq(["app/shop/queries.sql:4:24: query States: when state = draft: " +
                                                                                      "name the enum whose members the clauses stand for in the header, `-- param state: Billing::Invoice::Status`"])
      typed = base.sub("SELECT", "-- param state: Ledger::InvoiceState\nSELECT")
      query_errors(typed + "-- when state = draft: AND status = :state\n").first.should contain(
        "when state: a member's clause takes no parameter (it has :state); the member chooses the clause")
      query_errors(typed + "-- when state = draft: AND status = 'draft'\n-- when state: AND status = :state\n").first.should contain(
        "when state: `state` is either one clause with a parameter or one clause per member (`-- when state = draft:`), not both; the other is at line 5")
      query_errors(typed + "-- when state = draft: AND status = 'draft'\n-- when state = draft: AND 1\n").first.should contain("when state = draft is declared twice")
      query_errors(typed + "-- when state = Draft: AND status = 'draft'\n").first.should contain("when state = Draft: write the member in snake_case")
      query_errors(typed + "-- when state = draft: AND status = 'draft'\n-- when customer_id: AND customer_id = :customer_id\n-- when state = sent: AND 1\n").first.should contain(
        "when state: the clauses of one field's members go on consecutive lines")
      query_errors(typed + "-- when status: AND status = :status\n").should eq(["app/shop/queries.sql:2:1: query States: param state: annotate with Int64, Float64, String, Bytes, " +
                                                                                "Bool, or Time, nilable with `?`. Domain types come from columns.cr. An enum such as Ledger::InvoiceState " +
                                                                                "names a filter field with one clause per member (`-- when state = draft: AND …`)"])
      query_errors(base.sub("SELECT id FROM invoices\nWHERE account_id = :account_id\n", "SELECT id FROM invoices WHERE true\n") + "-- order by = x: ORDER BY id\n").first.should contain(
        "order by = x: an order has a name, not a member")
    end
  end

  describe "pages" do
    it "derives each order's condition after a cursor from its sort terms" do
      keyset = analysis(generate, "InvoicePage").filtered.try(&.keyset) || fail "InvoicePage has no keyset"
      keyset.keys.map { |key| {key.order.try(&.key), key.reversed?, key.sql, key.indexes} }.should eq([
        {"created", false, "AND (i.created_at, i.id) > (?, ?)", [0, 1]},
        {"created", true, "AND (i.created_at, i.id) < (?, ?)", [0, 1]},
        # A mixed order, both ways.
        {"amount", false, "AND (i.total_cents > ? OR (i.total_cents = ? AND i.id < ?))", [0, 0, 1]},
        {"amount", true, "AND (i.total_cents < ? OR (i.total_cents = ? AND i.id > ?))", [0, 0, 1]},
        # An alias compares the expression behind it.
        {"customer", false, "AND (c.name, i.id) > (?, ?)", [0, 1]},
        {"customer", true, "AND (c.name, i.id) < (?, ?)", [0, 1]},
      ])
      keyset.keys.last.terms.map(&.column.name).should eq(%w[customer_name id])
    end

    it "places the condition after the WHERE condition and its clauses, and prepares a page after a cursor in each order" do
      filtered = analysis(generate, "InvoicePage").filtered || fail "InvoicePage has no keyset"
      filtered.pieces.map { |piece| piece.after ? "after" : piece.clause.try(&.key) || "sql" }.should eq(
        %w[sql status after created amount customer])
      filtered.variants.map(&.[0]).last(7).first(6).should eq([
        "with every when, order created, after a cursor", "with every when, order created desc, after a cursor",
        "with every when, order amount, after a cursor", "with every when, order amount desc, after a cursor",
        "with every when, order customer, after a cursor", "with every when, order customer desc, after a cursor",
      ])
      filtered.variants.last[0].should eq("by key, with every when")
      filtered.variants.last[1].should contain("AND i.status = :status\nAND i.id = ?\n-- order created")
      filtered.variants[-2][1].should end_with("WHERE i.account_id = :account_id\n                AND i.status = :status\nAND (c.name, i.id) < (?, ?)\n" +
                                               "-- order created: ORDER BY i.created_at, i.id\n-- order amount: ORDER BY i.total_cents, i.id DESC\n" +
                                               "                   ORDER BY customer_name DESC, i.id DESC\nLIMIT ?")
      # The statement's own order, on the WHERE's line: the line is split.
      own = analysis(generate, "CustomerPage").filtered || fail "CustomerPage has no keyset"
      own.pieces.map { |piece| piece.after ? "after" : piece.sql }.should eq(["SELECT * FROM customers WHERE account_id = ?", "after", "ORDER BY name, id"])
      own.variants.map(&.[0]).should eq(["as written", "with every when after a cursor", "by key, with every when"])
      own.variants[1][1].should eq("SELECT * FROM customers WHERE account_id = :account_id\nAND (customers.name, customers.id) > (?, ?)\n ORDER BY name, id\nLIMIT ?")
    end

    it "refuses an order a cursor cannot continue" do
      page = "-- name: P :page\nSELECT id, number, note, total_cents * 2 AS double FROM invoices\n"
      query_errors(page + "WHERE true ORDER BY id LIMIT 5\n").should eq(
        ["app/shop/queries.sql:3:24: query P: a page takes its size from the method's `limit:`, and continues by cursor; remove LIMIT"])
      query_errors(page + "ORDER BY id\n").should eq(
        ["app/shop/queries.sql:1:1: query P: a page continues by a condition in WHERE; write one, `WHERE true` if nothing else"])
      query_errors(page + "WHERE true\n").should eq(
        ["app/shop/queries.sql:1:1: query P: a page needs an order, ORDER BY … or `-- order` lines, that ends with a key"])
      query_errors(page + "WHERE true ORDER BY status, id\n").first.should contain(
        "the order: sorts by status; a page continues after the last row's sort values, so sort by selected columns of a table")
      query_errors(page + "WHERE true ORDER BY note, id\n").first.should contain("the order: sorts by note, which can be NULL")
      query_errors(page + "WHERE true ORDER BY double, id\n").first.should contain("the order: sorts by double, which is computed")
      query_errors(page + "WHERE true ORDER BY id, number\n").first.should contain(
        "the order: ends with number, which does not tell rows apart; end it with a key, such as the table's id")
      query_errors(page + "WHERE true\n-- order newest: ORDER BY id\n-- order odd: ORDER BY note\n").should eq(
        ["app/shop/queries.sql:5:15: query P: order odd: sorts by note, which can be NULL; a page cannot continue after a NULL, so sort by a NOT NULL column"])
      query_errors("-- name: P :page\nSELECT id FROM invoices WHERE true UNION SELECT id FROM customers ORDER BY id\n").first.should contain(
        "a page continues one SELECT; UNION joins several")
      query_errors("-- name: P :page\nUPDATE invoices SET note = 'x' WHERE true RETURNING id\n").first.should contain(
        "changes rows; a page reads, and a write returns its rows with :many")
      query_errors("-- name: P :page\nSELECT id FROM invoices WHERE id > :after ORDER BY id\n").first.should contain(
        "parameter :after: the method of a query with pages uses this name")
      query_errors(page + "WHERE true\n-- when limit: AND total_cents < :limit\nORDER BY id\n").should eq(
        ["app/shop/queries.sql:1:1: query P: parameter :limit: the method of a query with pages uses this name; rename it"])
      query_errors(page + "WHERE true\n-- when after: AND total_cents > 0\nORDER BY id\n").should eq(
        ["app/shop/queries.sql:4:16: query P: when after: the method of a page query uses this name; rename the clause"])
      query_errors("-- name: P :pages\nSELECT id FROM invoices\n").first.should contain("use :one, :many, :page, :exec, or :execrows")
      schema = "CREATE TABLE notes (id INTEGER PRIMARY KEY, created_at TEXT NOT NULL DEFAULT (datetime('now'))) STRICT;\n"
      errors_for({"db/schema.sql" => schema, "app/shop/columns.cr" => %(Punch.table "notes", Shop::Notes, created_at: Time\n),
                  "app/shop/queries.sql" => "-- name: P :page\nSELECT * FROM notes WHERE true ORDER BY created_at, id\n"}).first.should contain(
        "sorts by created_at, whose default writes SQLite's datetime() text")
    end
  end

  it "maps columns and parameters to their domain types" do
    result = generate
    by_email = analysis(result, "CustomerByEmail")
    param_types(by_email).should eq({"account_id" => "Ledger::Accounts::ID", "email" => "Punch::Email"})
    types(by_email).should eq({"id" => "Ledger::Customers::ID", "name" => "String", "company_name" => "String?"})
    # A LEFT JOIN makes the right side nilable; payments are unmapped.
    types(analysis(result, "InvoicesWithLastPayment")).should eq({"id" => "Ledger::Invoices::ID", "number" => "Ledger::InvoiceNumber", "amount_cents" => "Int64?", "paid_at" => "String?"})
    # Values computed from a column are no longer of its domain type.
    types(analysis(result, "LineTotals"))["line_cents"].should eq("Float64")
    param_types(analysis(result, "AddToTotal")).should eq({"delta_cents" => "Int64", "id" => "Ledger::Invoices::ID"})
    # SET of a nullable column takes a nilable value.
    param_types(analysis(result, "MarkSent")).should eq({"now" => "Time?", "id" => "Ledger::Invoices::ID"})
    param_types(analysis(result, "InsertInvoice"))["created_at"].should eq("Time")
  end

  it "types an optional parameter inside coalesce by what the call is compared with" do
    sql = <<-SQL
      -- name: After :many
      SELECT id FROM invoices WHERE id > coalesce(:after, 0) AND ifnull(:customer_id, customer_id) = customer_id LIMIT :limit;
      SQL
    with_app({"app/shop/queries.sql" => sql, "app/ledger/columns.cr" => File.read(File.join(FIXTURE, "app/ledger/columns.cr"))}) do |directory|
      param_types(analysis(generate(directory), "After")).should eq({"after" => "Ledger::Invoices::ID?", "customer_id" => "Ledger::Customers::ID?", "limit" => "Int64"})
    end
  end

  it "types newer functions and parameters compared with IS [NOT] DISTINCT FROM" do
    sql = <<-SQL
      -- name: Newer :many
      SELECT concat(name, company_name) AS joined, concat_ws(' ', name, company_name) AS spaced, concat_ws(company_name, name) AS by_company,
        iif(active, name, email) AS shown, if(active, name) AS active_name, iif(active, name, vat_id IS NULL, company_name, 'none') AS label,
        octet_length(name) AS bytes, octet_length(company_name) AS company_bytes, timediff(archived_at, '2026-01-01') AS since, unistr(name) AS plain
      FROM customers
      WHERE account_id IS NOT DISTINCT FROM :account AND :archived IS DISTINCT FROM archived_at;
      SQL
    with_app({"app/shop/queries.sql" => sql, "app/ledger/columns.cr" => File.read(File.join(FIXTURE, "app/ledger/columns.cr"))}) do |directory|
      analysis = analysis(generate(directory), "Newer")
      types(analysis).should eq({
        "joined" => "String", "spaced" => "String", "by_company" => "String?",
        "shown" => "String", "active_name" => "String?", "label" => "String?",
        "bytes" => "Int64", "company_bytes" => "Int64?", "since" => "String?", "plain" => "String",
      })
      param_types(analysis).should eq({"account" => "Ledger::Accounts::ID?", "archived" => "Time?"})
    end
  end

  it "types an array parameter bound to carray by the column it is compared with" do
    sql = <<-SQL
      -- name: ByIds :many
      SELECT id, name FROM customers WHERE id IN carray(:ids) AND account_id NOT IN carray(:accounts) AND name IN carray(:names);
      SQL
    with_app({"app/shop/queries.sql" => sql, "app/ledger/columns.cr" => File.read(File.join(FIXTURE, "app/ledger/columns.cr"))}) do |directory|
      result = generate(directory)
      param_types(analysis(result, "ByIds")).should eq({"ids" => "Array(Ledger::Customers::ID)", "accounts" => "Array(Ledger::Accounts::ID)", "names" => "Array(String)"})
      code = result.outputs.find!(&.path.ends_with?("app/shop/queries.gen.cr")).content
      code.should contain("def self.by_ids(db : Punch::Reader | Punch::Writer, *, ids : Array(Ledger::Customers::ID), accounts : Array(Ledger::Accounts::ID), names : Array(String)) : Array(ByIds::Row) | Punch::Invalid")
      code.should contain(%(return Punch::Invalid.new("too_many", max: Punch::Stored::ARRAY_MAX) if ids.size > Punch::Stored::ARRAY_MAX))
      code.should contain("Punch::Stored.array(ids)")
    end
  end

  it "refuses carray against an encrypted column, outside IN, and in declared clauses" do
    encrypted_query_errors("-- name: Phones :many\nSELECT id FROM contacts WHERE phone IN carray(:phones);\n").first.should contain("param phones: compared with contacts.phone, which is encrypted")
    query_errors("-- name: Rows :many\nSELECT id FROM invoices WHERE id IN (SELECT value FROM carray(:ids));\n").first.should contain("param ids: an array parameter takes its type from the column it is compared with")
    query_errors("-- name: Some :many\nSELECT id FROM invoices WHERE id IN carray(:ids)\n-- when q: AND number = :q\n;\n").first.should contain("array parameters are not supported yet")
  end

  it "types the percentile functions" do
    sql = <<-SQL
      -- name: Spread :one
      SELECT percentile(total_cents, 95) AS p95, median(total_cents) AS middle, percentile_cont(total_cents, 0.5) AS cont,
        percentile_disc(total_cents, 0.5) AS disc, percentile_disc(sent_at, 0.5) AS sent
      FROM invoices WHERE account_id = :account_id;
      SQL
    with_app({"app/shop/queries.sql" => sql, "app/ledger/columns.cr" => File.read(File.join(FIXTURE, "app/ledger/columns.cr"))}) do |directory|
      types(analysis(generate(directory), "Spread")).should eq({"p95" => "Float64?", "middle" => "Float64?", "cont" => "Float64?", "disc" => "Int64?", "sent" => "Time?"})
    end
  end

  it "refuses IS DISTINCT FROM an encrypted column, as it refuses =" do
    encrypted_query_errors("-- name: Same :many\nSELECT id FROM contacts WHERE phone IS NOT DISTINCT FROM :phone;\n").first.should contain("param phone: compared with")
  end

  it "reuses one record per table for queries that return whole rows" do
    result = generate
    analysis(result, "InvoiceById").record.try(&.name).should eq("invoices")
    analysis(result, "InsertInvoice").record.try(&.name).should eq("invoices")
    analysis(result, "InvoiceWithAccount").record.should be_nil
    analysis(result, "PaidTotal").record.should be_nil
  end

  it "binds named parameters by number, so a parameter used twice is passed once" do
    with_app({"app/shop/queries.sql" => "-- name: Twice :many\nSELECT id FROM invoices WHERE customer_id = :customer AND account_id = (SELECT account_id FROM customers WHERE id = :customer);\n"}) do |directory|
      result = generate(directory)
      analysis(result, "Twice").positional_sql.should eq("SELECT id FROM invoices WHERE customer_id = ?1 AND account_id = (SELECT account_id FROM customers WHERE id = ?1)")
      analysis(result, "Twice").params.size.should eq(1)
    end
  end

  it "marks a table whose rowid SQLite reuses, so a public ID type on it does not compile" do
    schema = <<-SQL
      CREATE TABLE plans (id INTEGER PRIMARY KEY, name TEXT NOT NULL) STRICT;
      CREATE TABLE seats (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL) STRICT;
      CREATE TABLE plan_notes (plan_id INTEGER PRIMARY KEY REFERENCES plans (id), note TEXT NOT NULL) STRICT;
      SQL
    files = {
      "db/schema.sql"              => schema,
      "app/plans/columns.cr"       => %(Punch.table "plans", Plans, id: Plans::ID\n),
      "app/plans/notes/columns.cr" => %(Punch.table "plan_notes", Plans::Notes, plan_id: Plans::ID\n),
      "app/seats/columns.cr"       => %(Punch.table "seats", Seats, id: Seats::ID\n),
    }
    with_app(files) do |directory|
      records = generate(directory).outputs.select(&.path.ends_with?("records.gen.cr")).join(&.content)
      records.should contain(%(Punch::TypedID.reusing_rowids ::Plans::ID, "plans"))
      records.should_not contain("::Seats::ID, \"seats\"")
      records.should_not contain(%(::Plans::ID, "plan_notes"))
    end
  end

  it "derives the module from the path and writes next to the query file" do
    with_app({"app/billing/invoices/queries.sql" => "-- name: Count :one\nSELECT count(*) AS n FROM invoices;\n"}) do |directory|
      output = generate(directory).outputs.last
      output.path.should eq("app/billing/invoices/queries.gen.cr")
      output.content.should contain("module Billing::Invoices::Queries\n")
    end
  end

  it "names each record's behaviour file in its comment, like any Crystal type's file" do
    result = generate
    result.schema.table("invoice_lines").try(&.behaviour).should eq("app/ledger/invoice_lines/record.cr")
    result.outputs.find!(&.path.==("app/ledger/records.gen.cr")).content.should contain(
      "  # Its behaviour goes in `app/ledger/customers/record.cr`, which reopens this struct.\n  record Record,\n")
    Punch::QueryGen.behaviour_file("Billing::Customers", "src").should eq("src/billing/customers/record.cr")
    with_app({"src/shop/queries.sql" => "-- name: One :one\nSELECT 1 AS one;\n"}) do |directory|
      Punch::QueryGen.app_dir(directory).should eq("src")
      Dir.mkdir(File.join(directory, "app"))
      Punch::QueryGen.app_dir(directory).should eq("app")
    end
  end

  it "includes behaviour modules in a query's row" do
    sql = "-- name: Mail :many\n-- Customers to write to.\n-- include Shop::Mailable\n-- include ::Shop::Named\nSELECT name, email FROM customers;\n"
    with_app({"app/shop/queries.sql" => sql}) do |directory|
      result = generate(directory)
      analysis(result, "Mail").query.includes.map(&.[0]).should eq(%w[Shop::Mailable ::Shop::Named])
      analysis(result, "Mail").query.doc.should eq(["Customers to write to."])
      result.outputs.last.content.should contain("email : String do\n      include Shop::Mailable\n      include ::Shop::Named\n\n      def self.read")
    end
  end

  it "prepares queries on collated columns with Punch's collations, and ignores Punch's tables" do
    with_app({"app/shop/queries.sql" => "-- name: People :many\nSELECT name FROM people WHERE name LIKE :prefix ESCAPE '\\' ORDER BY name COLLATE fr;\n"}) do |directory|
      File.write(File.join(directory, "db/schema.sql"), <<-SQL, mode: "a")
        CREATE TABLE people (name TEXT NOT NULL COLLATE de) STRICT;
        CREATE TABLE punch_collations (name TEXT PRIMARY KEY, version TEXT NOT NULL) STRICT;
        SQL
      result = generate(directory)
      types(analysis(result, "People")).should eq({"name" => "String"})
      result.schema.table("punch_collations").should be_nil
    end
  end

  describe "violations" do
    schema = <<-SQL
      CREATE TABLE teams (id INTEGER PRIMARY KEY, slug TEXT NOT NULL UNIQUE) STRICT;
      CREATE TABLE members (
        id      INTEGER PRIMARY KEY,
        team_id INTEGER NOT NULL REFERENCES teams (id),
        email   TEXT    NOT NULL,
        handle  TEXT,
        seat    INTEGER NOT NULL DEFAULT 0,
        active  INTEGER NOT NULL DEFAULT 1,
        UNIQUE (team_id, email)
      ) STRICT;
      CREATE UNIQUE INDEX members_handle ON members (lower(handle));
      CREATE UNIQUE INDEX members_seat ON members (team_id, seat) WHERE active = 1;
      CREATE TABLE tags (
        team_id   INTEGER NOT NULL REFERENCES teams (id),
        member_id INTEGER NOT NULL REFERENCES members (id),
        PRIMARY KEY (team_id, member_id)
      ) STRICT, WITHOUT ROWID;
      CREATE TABLE logs (id INTEGER PRIMARY KEY, key TEXT NOT NULL UNIQUE) STRICT;
      SQL
    mapping = %(Punch.table "teams", Shop::Teams\nPunch.table "members", Shop::Members\nPunch.table "tags", Shop::Tags\n)
    queries = {
      "Insert"       => "INSERT INTO members (team_id, email) VALUES (:team_id, :email)",
      "InsertWithId" => "INSERT INTO members (id, team_id, email) VALUES (:id, :team_id, :email)",
      "InsertAll"    => "-- param id: Int64\n-- param team_id: Int64\n-- param email: String\n-- param handle: String?\n-- param seat: Int64\n-- param active: Int64\n" \
                     "INSERT INTO members VALUES (:id, :team_id, :email, :handle, :seat, :active)",
      "WithInsert" => "-- param email: String\nWITH t AS (SELECT id FROM teams WHERE slug = :slug) INSERT INTO members (team_id, email) SELECT id, :email FROM t",
      "Ignore"     => "INSERT OR IGNORE INTO members (team_id, email) VALUES (:team_id, :email)",
      "Replace"    => "REPLACE INTO members (team_id, email) VALUES (:team_id, :email)",
      "Fail"       => "INSERT OR FAIL INTO members (team_id, email) VALUES (:team_id, :email)",
      "Upsert"     => "INSERT INTO members (team_id, email) VALUES (:team_id, :email) ON CONFLICT (team_id, email) DO UPDATE SET handle = excluded.handle",
      "UpsertAny"  => "INSERT INTO members (team_id, email) VALUES (:team_id, :email) ON CONFLICT DO NOTHING",
      "SetHandle"  => "UPDATE members SET handle = :handle WHERE id = :id",
      "Activate"   => "UPDATE members AS m SET active = 1 WHERE m.id = :id",
      "SetBoth"    => "-- param email: String\n-- param seat: Int64\nUPDATE members SET (email, seat) = (:email, :seat), handle = coalesce(:handle, handle) WHERE id = :id",
      "Remove"     => "DELETE FROM members WHERE id = :id",
      "Tag"        => "INSERT INTO tags (team_id, member_id) VALUES (:team_id, :member_id)",
      "Log"        => "INSERT INTO logs (key) VALUES (:key)",
    }
    sql = queries.join { |name, statement| "-- name: #{name} :exec\n#{statement};\n\n" }

    it "names a type per unique constraint after its own columns, with its field" do
      with_app({"db/schema.sql" => schema, "app/shop/columns.cr" => mapping, "app/shop/queries.sql" => sql}) do |directory|
        result = generate(directory)
        members = result.schema.table("members").should_not be_nil
        members.uniques.map { |unique| {unique.type_name, unique.field, unique.constraint("members")} }.should eq([
          {"IdTaken", "id", "members.id"},
          {"HandleTaken", "handle", "members: members_handle"},
          {"SeatTaken", "seat", "members.team_id, members.seat"},
          {"EmailTaken", "email", "members.team_id, members.email"},
        ])
        result.schema.table("tags").try(&.uniques.map { |unique| {unique.type_name, unique.field} }).should eq([{"TeamIdMemberIdTaken", nil}])
        records = result.outputs.first.content
        records.should contain(%(  struct HandleTaken\n    include Punch::Database::Violation\n\n    CONSTRAINT = "members: members_handle"\n    FIELD      = "handle"\n    MESSAGE    = "UNIQUE constraint failed: index 'members_handle'"\n))
        # A rowid's type exists only where a query sets the ID.
        records.should contain("module Shop::Members\n")
        records.scan(/struct IdTaken/).size.should eq(1)
        records.should contain("def self.insert(db : Punch::Writer, *, team_id : Int64, email : String, handle : String? = nil, seat : Int64? = nil, active : Int64? = nil) : Record | HandleTaken | SeatTaken | EmailTaken\n")
        records.should contain("def self.update(db : Punch::Writer, record : Record) : Record | HandleTaken | SeatTaken | EmailTaken?\n")
      end
    end

    it "leaves out keys that contain a smaller full key, which cannot be violated" do
      places = <<-SQL
        CREATE TABLE seats (
          id     INTEGER PRIMARY KEY,
          room   INTEGER NOT NULL,
          row    INTEGER NOT NULL,
          active INTEGER NOT NULL,
          UNIQUE (room, id)
        ) STRICT;
        CREATE UNIQUE INDEX seats_active ON seats (room) WHERE active = 1;
        CREATE UNIQUE INDEX seats_place ON seats (room, row);
        CREATE UNIQUE INDEX seats_place_again ON seats (row, active, room);
        SQL
      with_app({"db/schema.sql" => places, "app/shop/columns.cr" => %(Punch.table "seats", Shop::Seats\n)}) do |directory|
        seats = generate(directory).schema.table("seats").should_not be_nil
        # (room, id) holds the rowid, (row, active, room) holds (room, row);
        # (room, row) stays, since the key inside it is partial.
        seats.uniques.map(&.type_name).should eq(%w[IdTaken RoomTaken RoomRowTaken])
      end
    end

    it "finds what each write can violate" do
      with_app({"db/schema.sql" => schema, "app/shop/columns.cr" => mapping, "app/shop/queries.sql" => sql}) do |directory|
        result = generate(directory)
        found = queries.keys.to_h { |name| {name, analysis(result, name).violations.map(&.type_name)} }
        found.should eq({
          "Insert"       => %w[SeatTaken EmailTaken], # no handle (NULL), a default seat
          "InsertWithId" => %w[IdTaken SeatTaken EmailTaken],
          "InsertAll"    => %w[IdTaken HandleTaken SeatTaken EmailTaken],
          "WithInsert"   => %w[SeatTaken EmailTaken],
          "Ignore"       => [] of String,
          "Replace"      => [] of String,
          "Fail"         => [] of String,
          "Upsert"       => %w[SeatTaken HandleTaken],
          "UpsertAny"    => [] of String,
          "SetHandle"    => %w[HandleTaken],
          "Activate"     => %w[SeatTaken], # the partial index's WHERE
          "SetBoth"      => %w[HandleTaken SeatTaken EmailTaken],
          "Remove"       => [] of String,
          "Tag"          => %w[TeamIdMemberIdTaken],
          "Log"          => [] of String, # unmapped: stays an exception
        })
        queries_file = result.outputs.last.content
        queries_file.should contain("def self.set_handle(db : Punch::Writer, *, handle : String?, id : Int64) : Shop::Members::HandleTaken?\n")
        queries_file.should contain("when Shop::Members::HandleTaken::MESSAGE then Shop::Members::HandleTaken.new\n")
      end
    end

    triggers = schema + <<-SQL
      CREATE TRIGGER members_seat_kept BEFORE UPDATE OF seat ON members WHEN OLD.active = 1
      BEGIN SELECT RAISE(ABORT, 'punch:seat_kept'); END;
      CREATE TRIGGER members_last BEFORE DELETE ON members WHEN (SELECT count(*) FROM members WHERE team_id = OLD.team_id) = 1
      BEGIN SELECT RAISE(ABORT, 'punch:last_member'); END;
      CREATE TRIGGER members_named BEFORE INSERT ON members WHEN NEW.handle = ''
      BEGIN SELECT RAISE(ABORT, 'punch:handle_empty'); END;
      SQL
    declared = mapping + %(Punch.violation "seat_kept", Shop::Members::SeatKept, status: 409\n) +
               %(Punch.violation "last_member", Shop::Members::LastMember, status: 409\n) +
               %(Punch.violation "handle_empty", Shop::Members::HandleEmpty, status: 422, field: "handle"\n)

    it "makes a rule a trigger raises a value of the writes that fire it (Punch.violation)" do
      with_app({"db/schema.sql" => triggers, "app/shop/columns.cr" => declared, "app/shop/queries.sql" => sql}) do |directory|
        result = generate(directory)
        found = %w[Insert SetHandle SetBoth Remove Upsert].to_h { |name| {name, analysis(result, name).violations.map(&.type_name)} }
        found.should eq({
          "Insert"    => %w[HandleEmpty SeatTaken EmailTaken],
          "SetHandle" => %w[HandleTaken], # not `UPDATE OF seat`
          "SetBoth"   => %w[HandleTaken SeatTaken EmailTaken SeatKept],
          "Remove"    => %w[LastMember],
          "Upsert"    => %w[HandleEmpty SeatTaken HandleTaken],
        })
        records = result.outputs.first.content
        records.should contain(%(  @[Punch::Status(409)]\n  struct SeatKept\n    include Punch::Database::Refusal\n\n    CONSTRAINT   = "members: trigger members_seat_kept"\n    MESSAGE      = "punch:seat_kept"\n    PROBLEM_CODE = "seat_kept"\n  end\n))
        records.should contain(%(  struct HandleEmpty\n    include Punch::Database::Violation\n\n    CONSTRAINT   = "members: trigger members_named"\n    FIELD        = "handle"\n))
        records.should contain(") : Bool | LastMember\n")
        records.should contain("def self.update(db : Punch::Writer, record : Record) : Record | HandleTaken | SeatTaken | EmailTaken | SeatKept?\n")
      end
    end

    it "refuses an undeclared Punch code, a declaration without its trigger, and codes that cannot be values" do
      undeclared = errors_for({"db/schema.sql" => triggers, "app/shop/columns.cr" => mapping})
      undeclared.size.should eq(3)
      undeclared.first.should contain("db/schema.sql:")
      undeclared.should contain("db/schema.sql:#{triggers.lines.index!(&.includes?("members_last")) + 1}: trigger members_last raises 'punch:last_member', which no Punch.violation declares; declare it in the columns.cr that maps members: Punch.violation \"last_member\", Type, status: 409")
      errors_for({"db/schema.sql" => schema, "app/shop/columns.cr" => mapping + %(Punch.violation "gone", Shop::Members::Gone, status: 409\n)}).first
        .should contain("no trigger in the schema raises 'punch:gone'; raise it with RAISE(ABORT, 'punch:gone')")
      errors_for({"db/schema.sql" => triggers, "app/shop/columns.cr" => declared.sub("Shop::Members::SeatKept", "Shop::Teams::SeatKept")}).first
        .should contain("seat_kept belongs to members, so its type is Shop::Members::SeatKept")
      errors_for({"db/schema.sql" => triggers, "app/shop/columns.cr" => declared.sub("status: 409\n", "status: 400\n")}).first
        .should contain("Punch.violation answers 409 or 422, not 400")
      rollback = schema + "CREATE TRIGGER members_stop BEFORE DELETE ON members BEGIN SELECT RAISE(ROLLBACK, 'punch:stop'); END;\n"
      errors_for({"db/schema.sql" => rollback, "app/shop/columns.cr" => mapping}).first
        .should contain("trigger members_stop raises 'punch:stop' with ROLLBACK, FAIL, or IGNORE")
    end
  end

  describe "errors" do
    it "refuses includes where there is no row of the query's own" do
      mapping = File.read(File.join(FIXTURE, "app/ledger/columns.cr"))
      errors_for({"app/shop/queries.sql" => "-- name: Whole :one\n-- include Shop::Due\nSELECT * FROM invoices WHERE id = :id;\n", "app/ledger/columns.cr" => mapping}).should eq(
        ["app/shop/queries.sql:2:1: query Whole: include Shop::Due: the query returns whole Ledger::Invoices::Record rows; include it in app/ledger/invoices/record.cr, which every whole-row query shares"])
      query_errors("-- name: Gone :exec\n-- include Shop::Due\nDELETE FROM payments;\n").should eq(
        ["app/shop/queries.sql:2:1: query Gone: include Shop::Due: the query returns no rows to include it in"])
      query_errors("-- name: Lower :many\n-- include shop::due\nSELECT id FROM invoices;\n").should eq(
        ["app/shop/queries.sql:2:1: query Lower: include takes a module name, such as Billing::Invoice::Due"])
      query_errors("-- name: Twice :many\n-- include Shop::Due\n-- include Shop::Due\nSELECT id FROM invoices;\n").should eq(
        ["app/shop/queries.sql:3:1: query Twice includes Shop::Due twice"])
    end

    it "points at the line and column SQLite reports" do
      query_errors("-- name: Wrong :many\nSELECT id,\n       numbr FROM invoices;\n").should eq(["app/shop/queries.sql:3:8: query Wrong: no such column: numbr"])
      query_errors("-- name: Syntax :one\nSELECT id FROM invoices WHERE id = :id id;\n").first.should start_with("app/shop/queries.sql:2:40: query Syntax: near \"id\": syntax error")
      query_errors("-- name: Ambiguous :many\nSELECT id FROM invoices JOIN customers ON customers.id = invoices.customer_id;\n").should eq(["app/shop/queries.sql:2:8: query Ambiguous: ambiguous column name: id"])
    end

    it "names the query when SQLite gives no position" do
      query_errors("-- name: NoTable :many\nSELECT id FROM invoice;\n").should eq(["app/shop/queries.sql:1:1: query NoTable: no such table: invoice"])
    end

    it "asks for an annotation where a type cannot be derived" do
      query_errors("-- name: Ids :many\nSELECT id FROM invoices WHERE id IN (SELECT value FROM json_each(:ids));\n").should eq(
        ["app/shop/queries.sql:2:66: query Ids: param ids: type unknown, add `-- param ids: Type`"])
      query_errors("-- name: Odd :one\nSELECT json_extract(note, '$.a') AS a FROM invoices;\n").should eq(
        ["app/shop/queries.sql:1:1: query Odd: column a: type unknown, add `-- column a: Type`"])
      query_errors("-- name: Right :many\nSELECT i.id, c.name FROM invoices i RIGHT JOIN customers c ON c.id = i.customer_id;\n").first.should contain(
        "RIGHT or FULL JOIN: nullability is not derived; annotate every column (missing: id, name)")
    end

    it "rejects what a named query cannot be" do
      query_errors("-- name: Two :exec\nDELETE FROM payments; DELETE FROM invoices;\n").should eq(["app/shop/queries.sql:2:21: query Two: one statement per query"])
      query_errors("-- name: Positional :one\nSELECT id FROM invoices WHERE id = ?;\n").should eq(["app/shop/queries.sql:2:36: query Positional: use named parameters, such as :customer_id, not ?"])
      query_errors("-- name: Returning :exec\nDELETE FROM payments RETURNING id;\n").should eq(["app/shop/queries.sql:1:1: query Returning: returns columns; use :one or :many"])
      query_errors("-- name: NoRows :one\nDELETE FROM payments;\n").should eq(["app/shop/queries.sql:1:1: query NoRows: returns no columns; use :exec or :execrows, or add RETURNING"])
      query_errors("-- name: Begin :exec\nBEGIN;\n").first.should contain("transactions belong to the handle")
      query_errors("-- name: Same :many\nSELECT id, id FROM invoices;\n").first.should contain("two columns are named id; alias one of them")
      query_errors("-- name: Spaced :many\nSELECT id AS \"the id\" FROM invoices;\n").first.should contain("column \"the id\" is not a Crystal name")
      query_errors("-- name: Unused :many\n-- column nope: Int64\nSELECT id FROM invoices;\n").first.should contain("annotation for column nope, which the query does not have")
    end

    it "checks query headers" do
      query_errors("SELECT 1;\n-- name: Late :one\nSELECT 1 AS one;\n").should eq(
        ["app/shop/queries.sql:1:1: SQL outside a named query; start each query with `-- name: Name :many` (or :one, :exec, :execrows)"])
      query_errors("-- name: lower :one\nSELECT 1 AS one;\n").first.should contain("query name lower must be CamelCase")
      query_errors("-- name: Some :all\nSELECT 1 AS one;\n").first.should contain("unknown kind :all")
      query_errors("-- name: Same :one\nSELECT 1 AS one;\n-- name: Same :one\nSELECT 2 AS two;\n").first.should eq(
        "app/shop/queries.sql:3:1: query Same is defined twice; the first is at line 1")
      query_errors("-- name: Typed :one\n-- param x: Money\nSELECT :x AS x;\n").first.should contain("param x: annotate with Int64, Float64, String, Bytes, Bool, or Time")
    end

    it "asks for ESCAPE '\\' on a LIKE whose pattern holds a parameter" do
      message = %q(LIKE with a parameter in its pattern needs ESCAPE '\', so `%` and `_` in user text match themselves (the parameter is a Punch::LikeText, which escapes it))
      query_errors("-- name: Bare :many\nSELECT id FROM invoices WHERE note LIKE :q;\n").should eq(["app/shop/queries.sql:2:36: query Bare: #{message}"])
      query_errors("-- name: Wrapped :many\nSELECT id FROM invoices WHERE note LIKE '%' || lower(:q) || '%' AND id > 0;\n").first.should contain(message)
      query_errors("-- name: Other :many\nSELECT id FROM invoices WHERE note LIKE :q ESCAPE '!';\n").first.should contain(message)
      query_errors("-- name: Clause :many\nSELECT id FROM invoices\nWHERE account_id = :account_id\n-- when q: AND note NOT LIKE :q\n").should eq(
        ["app/shop/queries.sql:4:25: query Clause: #{message}"])
      with_app({"app/shop/queries.sql" => "-- name: Fine :many\nSELECT id FROM invoices WHERE note LIKE 'a%' AND (number LIKE :q || '%' ESCAPE '\\') AND note LIKE :p ESCAPE '\\';\n"}) do |directory|
        analysis(generate(directory), "Fine").params.map(&.name).should eq(%w[q p])
      end
    end

    it "refuses a GLOB whose pattern holds a parameter, and keeps a fixed one" do
      query_errors("-- name: Globbed :many\nSELECT id FROM invoices WHERE note GLOB :q;\n").first.should contain("GLOB with a parameter in its pattern")
      with_app({"app/shop/queries.sql" => "-- name: Fixed :many\nSELECT id FROM invoices WHERE note GLOB 'a*' AND id = :id;\n"}) do |directory|
        analysis(generate(directory), "Fixed").params.map(&.name).should eq(%w[id])
      end
    end

    it "types the parameter of a LIKE as Punch::LikeText and of a MATCH as Punch::FtsPhrase" do
      schema = File.read(File.join(FIXTURE, "db/schema.sql")) + "\nCREATE VIRTUAL TABLE notes_fts USING fts5(body);\n"
      queries = "-- name: Like :many\nSELECT id FROM invoices WHERE note LIKE '%' || :q || '%' ESCAPE '\\';\n\n" \
                "-- name: Found :many\nSELECT length(body) AS size FROM notes_fts WHERE notes_fts MATCH :q;\n\n" \
                "-- name: Both :many\nSELECT id FROM invoices WHERE note LIKE :q ESCAPE '\\' AND number = :q;\n"
      messages = errors_for({"db/schema.sql" => schema, "app/shop/queries.sql" => queries})
      messages.size.should eq(1)
      messages.first.should contain("param q: feeds a LIKE pattern and is used elsewhere too, but it is bound as Punch::LikeText")
      with_app({"db/schema.sql" => schema, "app/shop/queries.sql" => queries.split("\n\n").first(2).join("\n\n")}) do |directory|
        result = generate(directory)
        param_types(analysis(result, "Like")).should eq({"q" => "Punch::LikeText"})
        param_types(analysis(result, "Found")).should eq({"q" => "Punch::FtsPhrase"})
      end
    end

    it "reports every mistake of a run at once and writes nothing" do
      with_app({"app/shop/queries.sql" => "-- name: A :many\nSELECT nope FROM invoices;\n\n-- name: B :many\nSELECT id FROM nope;\n"}) do |directory|
        error = expect_raises(Punch::QueryGen::Errors) { generate(directory) }
        error.errors.size.should eq(2)
        File.exists?(File.join(directory, "app/shop/queries.gen.cr")).should be_false
      end
    end

    it "checks the mapping file against the schema, with positions" do
      mapping_errors(%(Punch.table "invoice", Shop::Invoices, id: Shop::ID\n)).should eq(["app/shop/columns.cr:1:13: no table invoice in the schema"])
      mapping_errors(%(Punch.table "invoices", Shop::Invoices,\n  numbr: Shop::Number\n)).should eq(["app/shop/columns.cr:2:3: no column numbr in invoices"])
      mapping_errors(%(Punch.table "invoices", Shop::Invoices, total_cents: Time\n)).should eq(["app/shop/columns.cr:1:54: invoices.total_cents is INTEGER, but Time is stored as TEXT"])
      mapping_errors(%(Punch.table "invoices", Shop::Invoices, note: String\n)).first.should contain("String is a stored type; map columns to domain types only")
      mapping_errors(%(Punch.table "invoices", Shop::Invoices, note: "Email"\n)).first.should contain("the type must be a constant")
      mapping_errors(%(Punch.table "invoices", Shop::Invoices\nPunch.table "invoices", Shop::Other\n)).should eq(["app/shop/columns.cr:2:13: invoices is mapped twice"])
      mapping_errors(%(Punch.table "invoices", Shop::Same\nPunch.table "customers", Shop::Same\n)).first.should contain("Shop::Same is the module of invoices already")
      mapping_errors(%(MAPPING = 1\n)).first.should start_with("app/shop/columns.cr:1:1: app/shop/columns.cr may only contain `Punch.table")
      mapping_errors(%(Punch.table "invoices", Shop::Invoices, id: Shop::ID,\n)).first.should start_with("app/shop/columns.cr:")
    end

    it "encrypts only BLOB columns, by names that can derive a key, without unique keys" do
      mapping_errors(%(Punch.table "invoices", Shop::Invoices, note: Punch::Encrypted(String)\n)).should eq(
        ["app/shop/columns.cr:1:47: invoices.note is TEXT, but an encrypted column holds ciphertext; declare it BLOB"])
      mapping_errors(%(Punch.table "payments", Shop::Payments, raw: Punch::Encrypted(String, Bytes)\n)).first.should contain("Punch::Encrypted takes one type")
      errors_for({"db/schema.sql"       => %(CREATE TABLE "Vault" (id INTEGER PRIMARY KEY, secret BLOB) STRICT;\n),
                  "app/shop/columns.cr" => %(Punch.table "Vault", Shop::Vault, secret: Punch::Encrypted(String)\n)}).first.should contain(
        "Vault.secret: the key of an encrypted column is derived from its name, so the table and column names must be lowercase letters, digits, and _")
      errors_for({"db/schema.sql"       => %(CREATE TABLE vault (id INTEGER PRIMARY KEY, secret BLOB UNIQUE) STRICT;\n),
                  "app/shop/columns.cr" => %(Punch.table "vault", Shop::Vault, secret: Punch::Encrypted(String)\n)}).first.should contain(
        "vault.secret is encrypted, so the unique key on vault.secret compares ciphertext")
    end

    it "refuses comparing a parameter with an encrypted column, and sorting a page by one" do
      encrypted_query_errors(<<-SQL).should eq(["app/shop/queries.sql:2:59: query ByPhone: param phone: compared with contacts.phone, which is encrypted; its stored values are ciphertext, different every time, so they never equal a value"])
        -- name: ByPhone :many
        SELECT id FROM contacts WHERE customer_id = 1 AND phone = :phone;
        SQL
      encrypted_query_errors(<<-SQL).first.should contain("param phone: compared with contacts.phone")
        -- name: ByPhones :many
        SELECT id FROM contacts WHERE phone IN (:phone);
        SQL
      encrypted_query_errors(<<-SQL).first.should contain("order phone: sorts by phone, which is encrypted; ciphertext has no order")
        -- name: ContactPage :page
        SELECT id, phone FROM contacts WHERE true
        -- order phone: ORDER BY phone, id
        SQL
    end

    it "maps a blind index to an encrypted column of its table, on a BLOB column" do
      mapping_errors(%(Punch.table "contacts", Shop::Contacts, phone_index: Punch::BlindIndex.of(:phone)\n)).should eq(
        ["app/shop/columns.cr:1:54: contacts.phone_index: Punch::BlindIndex.of takes an encrypted column of contacts, such as Punch::BlindIndex.of(:email)"])
      mapping_errors(%(Punch.table "contacts", Shop::Contacts, phone: Punch::Encrypted(String), phone_index: Punch::BlindIndex.of("phone")\n)).first.should contain("Punch::BlindIndex.of takes an encrypted column")
      mapping_errors(%(Punch.table "contacts", Shop::Contacts, phone: Punch::Encrypted(String), phone_index: Punch::BlindIndex.of(:nope)\n)).first.should contain("Punch::BlindIndex.of takes an encrypted column")
      errors_for({"db/schema.sql"       => %(CREATE TABLE vault (id INTEGER PRIMARY KEY, secret BLOB, secret_index TEXT) STRICT;\n),
                  "app/shop/columns.cr" => %(Punch.table "vault", Shop::Vault, secret: Punch::Encrypted(String), secret_index: Punch::BlindIndex.of(:secret)\n)}).should eq(
        ["app/shop/columns.cr:1:83: vault.secret_index is TEXT, but a blind index holds hashes; declare it BLOB"])
      errors_for({"db/schema.sql"       => %(CREATE TABLE vault (id INTEGER PRIMARY KEY, secret BLOB, a BLOB, b BLOB) STRICT;\n),
                  "app/shop/columns.cr" => %(Punch.table "vault", Shop::Vault, secret: Punch::Encrypted(String), a: Punch::BlindIndex.of(:secret), b: Punch::BlindIndex.of(:secret)\n)}).first.should contain(
        "vault.b: vault.secret has a blind index already, a")
    end

    it "refuses an index or a CHECK on an encrypted column, and a CHECK on a blind index" do
      errors_for({"db/schema.sql"       => %(CREATE TABLE vault (id INTEGER PRIMARY KEY, secret BLOB) STRICT;\nCREATE INDEX vault_by_secret ON vault (secret);\n),
                  "app/shop/columns.cr" => %(Punch.table "vault", Shop::Vault, secret: Punch::Encrypted(String)\n)}).should eq(
        ["app/shop/columns.cr:1:35: vault.secret is encrypted, so the index vault_by_secret orders ciphertext, which differs for every write; drop it, and index a blind index instead (Punch::BlindIndex.of)"])
      errors_for({"db/schema.sql"       => %(CREATE TABLE vault (id INTEGER PRIMARY KEY, secret BLOB CHECK (length(secret) > 4)) STRICT;\n),
                  "app/shop/columns.cr" => %(Punch.table "vault", Shop::Vault, secret: Punch::Encrypted(String)\n)}).first.should contain(
        "vault.secret is encrypted, so a CHECK on it sees ciphertext, never the value")
      errors_for({"db/schema.sql"       => %(CREATE TABLE vault (id INTEGER PRIMARY KEY, secret BLOB, secret_index BLOB, CHECK (secret_index IS NOT NULL)) STRICT;\n),
                  "app/shop/columns.cr" => %(Punch.table "vault", Shop::Vault, secret: Punch::Encrypted(String), secret_index: Punch::BlindIndex.of(:secret)\n)}).first.should contain(
        "vault.secret_index is a blind index, so a CHECK on it sees a hash")
    end

    it "compares a blind index only as `column = :param`, which takes the encrypted column's type" do
      with_app({"app/shop/queries.sql" => "-- name: ByPhone :one\nSELECT id FROM contacts c WHERE c.phone_index = :phone;\n",
                "app/shop/columns.cr"  => %(Punch.table "contacts", Shop::Contacts, phone: Punch::Encrypted(Punch::NonEmptyString), phone_index: Punch::BlindIndex.of(:phone)\n)}) do |directory|
        found = analysis(generate(directory), "ByPhone")
        param_types(found).should eq({"phone" => "Punch::NonEmptyString"})
        found.positional_sql.should eq("SELECT id FROM contacts c WHERE c.phone_index IN carray(?1)")
      end
      blind_query_errors(<<-SQL).should eq(["app/shop/queries.sql:2:47: query ByPhones: param phone: contacts.phone_index is a blind index, so compare it only as `phone_index = :phone`, or `phone_index IN carray(:phone)` for several, column first; it holds hashes, which have no order and match only the whole value"])
        -- name: ByPhones :many
        SELECT id FROM contacts WHERE phone_index IN (:phone);
        SQL
      blind_query_errors(<<-SQL).first.should contain("param phone: contacts.phone_index is a blind index, so compare it only as `phone_index = :phone`, or `phone_index IN carray(:phone)` for several, column first")
        -- name: Reversed :many
        SELECT id FROM contacts WHERE :phone = phone_index;
        SQL
      blind_query_errors(<<-SQL).first.should contain("param phone: contacts.phone_index is a blind index")
        -- name: After :many
        SELECT id FROM contacts WHERE phone_index > :phone;
        SQL
      blind_query_errors(<<-SQL).first.should contain("param phone: contacts.phone_index is a blind index, so compare it only as `phone_index = :phone`")
        -- name: Joined :many
        SELECT id FROM contacts WHERE phone_index = :phone || x'00';
        SQL
      blind_query_errors(<<-SQL).first.should contain("param phone: compared with contacts.phone_index, a blind index, so it binds hashes; use another parameter for its other places")
        -- name: Twice :many
        SELECT id FROM contacts WHERE phone_index = :phone OR customer_id = :phone;
        SQL
    end

    it "refuses comparing, matching, and sorting ciphertext and blind indexes in SQL" do
      blind_query_errors(<<-SQL).should eq(["app/shop/queries.sql:2:67: query Copies: contacts.note is encrypted, and its ciphertext differs on every write; comparing it with anything else never matches"])
        -- name: Copies :many
        SELECT a.id FROM contacts a JOIN contacts b ON a.id <> b.id AND a.note = b.phone;
        SQL
      blind_query_errors(<<-SQL).first.should contain("contacts.phone is encrypted, and its ciphertext differs on every write; LIKE on it never matches")
        -- name: Like :many
        SELECT id FROM contacts WHERE phone LIKE '+49%';
        SQL
      blind_query_errors(<<-SQL).first.should contain("contacts.phone is encrypted, and its ciphertext differs on every write; IN on it never matches")
        -- name: NotIn :many
        SELECT id FROM contacts WHERE phone NOT IN (x'00');
        SQL
      blind_query_errors(<<-SQL).first.should contain("contacts.phone is encrypted, and its ciphertext differs on every write, so sorting or grouping by it means nothing")
        -- name: Sorted :many
        SELECT id FROM contacts ORDER BY customer_id, phone;
        SQL
      blind_query_errors(<<-SQL).first.should contain("contacts.phone_index is a blind index, whose hashes only `phone_index = :param` and `phone_index IN carray(:param)` find; comparing it with anything else never matches")
        -- name: Duplicates :many
        SELECT a.id FROM contacts a JOIN contacts b ON a.phone_index = b.phone_index AND a.id <> b.id;
        SQL
      blind_query_errors(<<-SQL).first.should contain("contacts.phone_index is a blind index, whose hashes only `phone_index = :param` and `phone_index IN carray(:param)` find, so sorting or grouping by it means nothing")
        -- name: Grouped :many
        SELECT count(*) AS n FROM contacts GROUP BY phone_index;
        SQL
      blind_query_errors(<<-SQL).first.should contain("contacts.phone is encrypted, and its ciphertext differs on every write; it opens only in its own column, so assign it nothing but a parameter")
        -- name: Move :exec
        UPDATE contacts SET note = phone WHERE id = :id;
        SQL
      blind_query_errors(<<-SQL).first.should contain("order phone: contacts.phone is encrypted, so sorting by it means nothing")
        -- name: Listed :many
        SELECT id FROM contacts WHERE true
        -- order id: ORDER BY id
        -- order phone: ORDER BY phone, id
        SQL
      with_app({"app/shop/queries.sql" => <<-SQL, "app/shop/columns.cr" => %(Punch.table "contacts", Shop::Contacts, phone: Punch::Encrypted(Punch::NonEmptyString), phone_index: Punch::BlindIndex.of(:phone)\n)}) do |directory|
        -- name: Upsert :exec
        INSERT INTO contacts (customer_id, phone, phone_index) VALUES (:customer_id, :phone, :phone_index)
        ON CONFLICT (customer_id, phone_index) DO UPDATE SET phone = excluded.phone;

        -- name: WithoutPhone :many
        SELECT id FROM contacts WHERE phone IS NULL OR note IS NOT NULL;
        SQL
        result = generate(directory)
        param_types(analysis(result, "Upsert")).should eq({"customer_id" => "Int64", "phone" => "Punch::Secret(Punch::NonEmptyString)", "phone_index" => "Punch::NonEmptyString"})
      end
    end

    it "converts a plaintext column of the value's stored type, and clears it only once it may be NULL" do
      errors_for({"db/schema.sql"       => %(CREATE TABLE leads (id INTEGER PRIMARY KEY, email TEXT NOT NULL, email_encrypted BLOB) STRICT;\n),
                  "app/shop/columns.cr" => %(Punch.table "leads", Shop::Leads, email_encrypted: Punch::Encrypted(Punch::Email).from(:email, clear: true)\n)}).should eq(
        ["app/shop/columns.cr:1:52: leads.email_encrypted: clearing leads.email writes NULL into it, but it is NOT NULL; make it nullable first, in a migration that rebuilds leads"])
      errors_for({"db/schema.sql"       => %(CREATE TABLE leads (id INTEGER PRIMARY KEY, email TEXT, email_encrypted BLOB) STRICT;\n),
                  "app/shop/columns.cr" => %(Punch.table "leads", Shop::Leads, email: Punch::Email, email_encrypted: Punch::Encrypted(Punch::Email).from(:email)\n)}).first.should contain(
        "leads.email_encrypted: leads.email is mapped by from; leave it out of the mapping")
      errors_for({"db/schema.sql"       => %(CREATE TABLE leads (id INTEGER PRIMARY KEY, email TEXT, email_encrypted BLOB) STRICT;\n),
                  "app/shop/columns.cr" => %(Punch.table "leads", Shop::Leads, email_encrypted: Punch::Encrypted(Punch::Email).from(:mail)\n)}).first.should contain(
        "leads.email_encrypted: from takes the plaintext column it replaces, such as from(:email)")
      errors_for({"db/schema.sql"       => %(CREATE TABLE leads (id INTEGER PRIMARY KEY, email TEXT, email_encrypted BLOB) STRICT;\n),
                  "app/shop/columns.cr" => %(Punch.table "leads", Shop::Leads, email_encrypted: Punch::Encrypted(Punch::Email).from(:email, keep: 1)\n)}).first.should contain(
        "leads.email_encrypted: from takes only clear: true or false")
    end

    it "refuses queries that touch a plaintext column being cleared, by name or through *" do
      clearing = %(Punch.table "prospects", Shop::Prospects, email_encrypted: Punch::Encrypted(Punch::Email).from(:email, clear: true)\n)
      errors_for({"app/shop/columns.cr" => clearing, "app/shop/queries.sql" => <<-SQL}).should eq(["app/shop/queries.sql:2:32: query ByEmail: prospects.email is being cleared (from(..., clear: true)), and the next release drops it; leave it out, and list the columns instead of *, so this release keeps working once it is gone"])
        -- name: ByEmail :many
        SELECT id FROM prospects WHERE email = :email;
        SQL
      errors_for({"app/shop/columns.cr" => clearing, "app/shop/queries.sql" => <<-SQL}).first.should contain("query All: column email: prospects.email is being cleared")
        -- name: All :many
        SELECT * FROM prospects;
        SQL
    end

    it "maps a table only beside its module, and each module once across files" do
      mapping_errors(%(Punch.table "invoices", Ledger::Invoices\n)).should eq(
        ["app/shop/columns.cr:1:25: app/shop/columns.cr maps only tables of Shop; map invoices in app/ledger/invoices/columns.cr, beside Ledger::Invoices"])
      errors_for({"app/shop/columns.cr"           => %(Punch.table "invoices", Shop::Customers::Due\n),
                  "app/shop/customers/columns.cr" => %(Punch.table "customers", Shop::Customers::Due\n)}).first.should contain("Shop::Customers::Due is the module of invoices already")
    end

    it "writes the records of each columns.cr beside it" do
      with_app({"app/shop/columns.cr"           => %(Punch.table "invoices", Shop::Invoices\nPunch.table "invoice_lines", Shop::Invoices::Lines\n),
                "app/shop/customers/columns.cr" => %(Punch.table "customers", Shop::Customers\n)}) do |directory|
        result = generate(directory)
        result.outputs.map(&.path).should eq(%w[app/shop/columns.cr app/shop/customers/columns.cr].map { |path| Punch::QueryGen.records_path(path) })
        result.outputs.first.content.should contain("from db/schema.sql and app/shop/columns.cr")
        result.outputs.first.content.should contain("module Shop::Invoices::Lines")
        result.outputs.first.content.should_not contain("module Shop::Customers")
      end
    end

    it "maps only STRICT tables" do
      with_app({"app/shop/columns.cr" => %(Punch.table "loose", Shop::Loose\n)}) do |directory|
        File.write(File.join(directory, "db/schema.sql"), "CREATE TABLE loose (id INTEGER PRIMARY KEY, name TEXT);\n", mode: "a")
        error = expect_raises(Punch::QueryGen::Errors) { generate(directory) }
        error.message.to_s.should eq("app/shop/columns.cr:1:1: loose is not STRICT, so SQLite does not enforce its column types; only STRICT tables can be mapped")
      end
    end

    it "requires query files under app/ or src/" do
      with_app({"lib/queries.sql" => "-- name: A :one\nSELECT 1 AS a;\n"}) do |directory|
        Dir.cd(directory) do
          config = Punch::QueryGen::Config.new(queries: ["lib/queries.sql"])
          error = expect_raises(Punch::QueryGen::Errors) { Punch::QueryGen.run(config) }
          error.message.to_s.should contain("lib/queries.sql:1: query files live under app/ or src/")
        end
      end
    end
  end
end

describe "Punch::QueryGen::Emitter.heredoc" do
  it "writes SQL that Crystal reads as written, whatever the text holds" do
    interpolation = "#" + "{x}"
    heredoc = ->(sql : String) { IO::Memory.new.tap { |io| Punch::QueryGen::Emitter.heredoc(io, "TEXT", sql) }.to_s }
    # A backslash before an interpolation still makes it a raw heredoc.
    heredoc.call("SELECT 'a\\#{interpolation}'").should eq("    TEXT = <<-'SQL'\n      SELECT 'a\\#{interpolation}'\n      SQL\n")
    # A line that is the terminator gets another one.
    heredoc.call("SELECT 'a\nSQL\nb'").should eq("    TEXT = <<-SQL_END\n      SELECT 'a\n      SQL\n      b'\n      SQL_END\n")
  end
end

# Errors of an app with *composites* in `app/shop/composites.cr`, and
# *mapping* and *queries* beside them.
private def composite_errors(composites : String, mapping : String = "", queries : String? = nil) : Array(String)
  files = {"app/shop/composites.cr" => composites, "app/shop/columns.cr" => mapping}
  queries.try { |sql| files["app/shop/queries.sql"] = sql }
  errors_for(files)
end

private ADDRESS = <<-CRYSTAL
  Punch.composite Shop::Address,
    street: Punch::NonEmptyString,
    city: Punch::NonEmptyString,
    country: {type: Punch::NonEmptyString, default: "DE"},
    geo: Shop::Geo?

  Punch.composite Shop::Geo,
    lat: Float64,
    lng: Float64
  CRYSTAL

describe "composites (docs/composites.md)" do
  it "refuses field types a composite cannot store" do
    errors = composite_errors(<<-CRYSTAL)
      Punch.composite Shop::Bad,
        raw: Bytes,
        lines: Array(Punch::NonEmptyString),
        maybe: String | Int64,
        nested: {type: Array(Array(String)), max: 3},
        keyed: {type: Hash(Int64, String), max: 3},
        flag: {type: Bool?, default: true},
        count: {type: Int64, max: 3},
        huge: {type: Array(String), max: 20000}
      CRYSTAL
    errors.should eq([
      "app/shop/composites.cr:2:8: Shop::Bad.raw: Bytes cannot be a field; use a domain primitive, Time, Bool, Int64, Float64, or String",
      "app/shop/composites.cr:3:10: Shop::Bad.lines: an array is bounded: {type: Array(T), max: N}",
      "app/shop/composites.cr:4:10: Shop::Bad.maybe: the type must be a constant, such as Punch::NonEmptyString",
      "app/shop/composites.cr:5:24: Shop::Bad.nested: an array is bounded: {type: Array(T), max: N}",
      "app/shop/composites.cr:6:17: Shop::Bad.keyed: a map's key is String or a domain primitive stored as String",
      "app/shop/composites.cr:7:32: Shop::Bad.flag: only a field that is a domain primitive, Time, Bool, or a stored type, not nilable, has a default",
      "app/shop/composites.cr:8:17: Shop::Bad.count: max: bounds an Array or a Hash",
      "app/shop/composites.cr:9:36: Shop::Bad.huge: max: is a number from 1 to 10000",
    ])
  end

  it "refuses a composite that contains itself, and mistakes in polymorphic ones" do
    errors = composite_errors(<<-CRYSTAL)
      Punch.composite Shop::Node,
        children: {type: Array(Shop::Node), max: 10}

      Punch.composite Shop::Payment,
        discriminator: "kind",
        one_of: {card: Shop::Card, cash: Shop::Missing}

      Punch.composite Shop::Card,
        kind: String

      Punch.composite Shop::Other,
        one_of: {card: Shop::Card}
      CRYSTAL
    errors.should contain("app/shop/composites.cr:1:1: Shop::Node contains itself (through Shop::Node); a composite has an end")
    errors.should contain("app/shop/composites.cr:4:1: Shop::Payment: its member Shop::Missing is not a composite; declare it with Punch.composite")
    errors.should contain("app/shop/composites.cr:9:3: Shop::Card.kind: Shop::Payment names its members by the key kind, so a member has no field of that name")
    errors.should contain("app/shop/composites.cr:11:1: Shop::Other: one_of: needs discriminator: \"kind\", the key that names the member")
  end

  it "keeps declarations in their namespace and composites.cr to declarations" do
    errors = composite_errors(%(Punch.composite Billing::Address, street: String\nputs "hi"\n))
    errors.should eq([
      "app/shop/composites.cr:1:17: app/shop/composites.cr declares only composites of Shop, such as Shop::Address",
      "app/shop/composites.cr:2:1: app/shop/composites.cr may only contain `Punch.composite Name, field: Type, …` calls",
    ])
  end

  it "maps a group's fields to prefixed columns, checked against the schema" do
    composite_errors(ADDRESS, %(Punch.table "sites", Shop::Sites,\n  address: {type: Shop::Address, columns: "addr_"}\n)).should eq([
      "app/shop/columns.cr:2:3: sites.address: Shop::Address.street goes in the column addr_street, which sites does not have",
      "app/shop/columns.cr:2:3: sites.address: Shop::Address.city goes in the column addr_city, which sites does not have",
      "app/shop/columns.cr:2:3: sites.address: Shop::Address.country goes in the column addr_country, which sites does not have",
      "app/shop/columns.cr:2:3: sites.address: Shop::Geo.lat goes in the column addr_geo_lat, which sites does not have",
      "app/shop/columns.cr:2:3: sites.address: Shop::Geo.lng goes in the column addr_geo_lng, which sites does not have",
    ])
    composite_errors(ADDRESS, %(Punch.table "sites", Shop::Sites,\n  address: {type: Shop::Address, columns: "address_"},\n  address_city: Punch::NonEmptyString\n)).should eq([
      "app/shop/columns.cr:3:17: sites.address_city belongs to the group address; leave it out of the mapping",
    ])
    composite_errors(ADDRESS, %(Punch.table "sites", Shop::Sites, name: {type: Shop::Address, columns: "address_"}\n)).should eq([
      "app/shop/columns.cr:1:41: sites.name: sites.name is a column; give the group's field another name",
    ])
  end

  it "requires NOT NULL and the default where a group always holds a value, and a CHECK where it may be absent" do
    with_app({"app/shop/composites.cr" => ADDRESS, "app/shop/columns.cr" => %(Punch.table "places", Shop::Places,\n  address: {type: Shop::Address?, columns: "a_"},\n  home: {type: Shop::Address, columns: "h_"}\n)}) do |directory|
      File.write(File.join(directory, "db/schema.sql"), <<-SQL, mode: "a")
        CREATE TABLE places (
          id INTEGER PRIMARY KEY,
          a_street TEXT, a_city TEXT, a_country TEXT, a_geo_lat REAL, a_geo_lng REAL,
          h_street TEXT, h_city TEXT NOT NULL, h_country TEXT NOT NULL DEFAULT 'FR', h_geo_lat REAL, h_geo_lng REAL
        ) STRICT;
        SQL
      error = expect_raises(Punch::QueryGen::Errors) { generate(directory) }
      # The group may be absent as a whole, and so may its geo while it is there.
      error.errors.map(&.to_s).should eq([
        "app/shop/columns.cr:2:3: places.address: a row could hold part of Shop::Address; add a CHECK in a migration: ALTER TABLE places ADD " \
        "CHECK (((a_street IS NULL) + (a_city IS NULL) + (a_country IS NULL)) IN (0, 3) AND (a_street IS NOT NULL OR (a_geo_lat IS NULL AND a_geo_lng IS NULL)));",
        "app/shop/columns.cr:2:3: places.address: a row could hold part of Shop::Geo; add a CHECK in a migration: ALTER TABLE places ADD " \
        "CHECK (((a_geo_lat IS NULL) + (a_geo_lng IS NULL)) IN (0, 2));",
        "app/shop/columns.cr:3:3: places.home: places.h_street holds the required field street, so it is NOT NULL",
        "app/shop/columns.cr:3:3: places.home: places.h_country needs DEFAULT 'DE', the default of the field country (\"DE\"); it has DEFAULT 'FR'",
      ])
    end
  end

  it "keeps a document column JSON with a CHECK, and secrets out of plain documents" do
    composites = <<-CRYSTAL
      Punch.composite Shop::Note,
        text: Punch::NonEmptyString,
        secret: Punch::Encrypted(Punch::NonEmptyString)?
      CRYSTAL
    with_app({"app/shop/composites.cr" => composites, "app/shop/columns.cr" => %(Punch.table "docs", Shop::Docs,\n  plain: Shop::Note,\n  loose: Shop::Note,\n  sealed: Punch::Encrypted(Shop::Note)\n)}) do |directory|
      File.write(File.join(directory, "db/schema.sql"), <<-SQL, mode: "a")
        CREATE TABLE docs (
          id INTEGER PRIMARY KEY,
          plain TEXT CHECK (json_valid(plain) AND json_type(plain) = 'object'),
          loose TEXT,
          sealed BLOB
        ) STRICT;
        SQL
      error = expect_raises(Punch::QueryGen::Errors) { generate(directory) }
      error.errors.map(&.to_s).should eq([
        "app/shop/columns.cr:2:10: docs.plain: Shop::Note.secret is encrypted, which a plain document cannot keep; encrypt the whole document, Punch::Encrypted(Shop::Note)",
        "app/shop/columns.cr:3:10: docs.loose: Shop::Note.secret is encrypted, which a plain document cannot keep; encrypt the whole document, Punch::Encrypted(Shop::Note)",
      ])
    end
    with_app({"app/shop/composites.cr" => "Punch.composite Shop::Note, text: Punch::NonEmptyString\n", "app/shop/columns.cr" => %(Punch.table "docs", Shop::Docs, loose: Shop::Note\n)}) do |directory|
      File.write(File.join(directory, "db/schema.sql"), "CREATE TABLE docs (id INTEGER PRIMARY KEY, loose TEXT) STRICT;\n", mode: "a")
      error = expect_raises(Punch::QueryGen::Errors) { generate(directory) }
      error.message.to_s.should eq("app/shop/columns.cr:1:40: docs.loose holds a JSON document, so a CHECK keeps it one; declare the column with: CHECK (loose IS NULL OR (json_valid(loose) AND json_type(loose) = 'object'))")
    end
  end

  it "types paths from the composite and refuses paths it does not declare" do
    mapping = %(Punch.table "orders", Shop::Orders, shipping: Shop::Shipment, billed_to: Punch::Encrypted(Shop::Shipment)\n)
    composites = ADDRESS + "\n\n" + <<-CRYSTAL
      Punch.composite Shop::Shipment,
        address: Shop::Address,
        tags: {type: Array(String), max: 5}
      CRYSTAL
    query_errors = ->(sql : String) { composite_errors(composites, mapping, sql) }
    query_errors.call("-- name: A :many\nSELECT shipping ->> '$.address.town' AS town FROM orders;\n").should eq([
      "app/shop/queries.sql:2:21: query A: '$.address.town': Shop::Address has no field town",
    ])
    query_errors.call("-- name: A :many\nSELECT id FROM orders WHERE shipping ->> '$.tags.first' = 'x';\n").should eq([
      "app/shop/queries.sql:2:42: query A: '$.tags.first': an array is read by [n]",
    ])
    query_errors.call("-- name: A :many\nSELECT billed_to ->> '$.address' AS a FROM orders;\n").should eq([
      "app/shop/queries.sql:2:18: query A: orders.billed_to is an encrypted document, so a path into it reads ciphertext; select the column and read the field in Crystal",
    ])
    with_app({"app/shop/composites.cr" => composites, "app/shop/columns.cr" => mapping, "app/shop/queries.sql" => "-- name: A :many\nSELECT shipping ->> 'tags' AS tags, json_extract(shipping, '$.address.geo.lat') AS lat, shipping ->> '$.tags[0]' AS tag FROM orders;\n"}) do |directory|
      types(analysis(generate(directory), "A")).should eq({"tags" => "String", "lat" => "Float64?", "tag" => "String?"})
    end
  end

  it "types a generated column over a path, and refuses one of another stored type" do
    with_app({"app/shop/composites.cr" => ADDRESS, "app/shop/columns.cr" => %(Punch.table "places", Shop::Places, home: Shop::Address\n)}) do |directory|
      File.write(File.join(directory, "db/schema.sql"), <<-SQL, mode: "a")
        CREATE TABLE places (
          id   INTEGER PRIMARY KEY,
          home TEXT NOT NULL CHECK (json_valid(home) AND json_type(home) = 'object'),
          city TEXT GENERATED ALWAYS AS (home ->> '$.city') VIRTUAL,
          lat  INTEGER GENERATED ALWAYS AS (json_extract(home, '$.geo.lat')) VIRTUAL
        ) STRICT;
        SQL
      error = expect_raises(Punch::QueryGen::Errors) { generate(directory) }
      error.message.to_s.should match(/places\.lat is INTEGER, but the path gives REAL/)
    end
  end
end

describe "composites' nesting bound (docs/composites.md)" do
  it "refuses a max_depth below the depth the declaration needs, and one above the limit" do
    composite_errors(<<-CRYSTAL).should eq(["app/shop/composites.cr:3:1: Shop::Tree: its documents nest 5 deep, more than its max_depth: 3"])
      Punch.composite Shop::Leaf, value: String
      Punch.composite Shop::Branch, leaves: {type: Array(Shop::Leaf), max: 5}
      Punch.composite Shop::Tree, max_depth: 3, branches: {type: Array(Shop::Branch), max: 5}
      CRYSTAL
    composite_errors("Punch.composite Shop::Wide, max_depth: 65, value: String\n").should eq([
      "app/shop/composites.cr:1:40: Shop::Wide: max_depth: is how deep its documents nest, from 1 to 64",
    ])
  end
end

describe Punch::QueryGen::Composites do
  it "knows the composites Punch ships in every app, and reads them from columns" do
    errors = [] of Punch::QueryGen::Error
    composites = Punch::QueryGen::Composites.collect([] of String, errors)
    errors.should be_empty
    composites.keys.sort!.should eq(%w[File ImageFile PrivateFile PrivateImageFile].map { |name| "Punch::Upload::#{name}" })
    composites.each_value(&.grouped?.should(be_true))
    composites["Punch::Upload::PrivateFile"].field("filename").try(&.type.crystal).should eq("Punch::Secret(Punch::Upload::Filename)")
  end

  it "keeps the composites Punch ships current in Punch itself" do
    output = Punch::QueryGen.own_composites.outputs.first
    File.read(output.path).should eq(output.content)
  end
end
