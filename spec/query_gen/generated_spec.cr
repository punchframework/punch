require "../spec_helper"
require "./fixture/app/ledger/types"
require "./fixture/app/ledger/customers/record"
require "./fixture/app/ledger/columns"
require "./fixture/app/ledger/records.gen"
require "./fixture/app/ledger/composites.gen"
require "./fixture/app/ledger/geo"
require "./fixture/app/ledger/orders/columns"
require "./fixture/app/ledger/orders/records.gen"
require "./fixture/app/ledger/orders/billed_to"
require "./fixture/app/ledger/sites/columns"
require "./fixture/app/ledger/sites/records.gen"
require "./fixture/app/ledger/queries.gen"
require "../../src/punch/cli"

# Columns may have the names of the macro's own parameters: this compiles.
Punch.table "people", GeneratedSpec::People, name: Punch::NonEmptyString, mod: Punch::NonEmptyString

# Runs every generated method against seeded data, on Punch's handles.
# Typed reads are strict, so a wrong type or an
# unexpected NULL raises. The seed covers the NULL cases: an invoice without
# payments, a customer without invoices, aggregates over no rows.
module GeneratedSpec
  alias Q = Ledger::Queries
  SCHEMA = "#{__DIR__}/fixture/db/schema.sql"
  NOW    = Time.utc(2026, 10, 7, 10, 0, 0, nanosecond: 123_456_789)

  def self.id(type : T.class, value : Int) : T forall T
    type.parse(value).as(T)
  end

  def self.number(value : String) : Ledger::InvoiceNumber
    Ledger::InvoiceNumber.parse(value).as(Ledger::InvoiceNumber)
  end

  def self.email(value : String) : Punch::Email
    Punch::Email.parse(value).as(Punch::Email)
  end

  def self.text(value : String) : Punch::LikeText
    Punch::LikeText.parse(value).as(Punch::LikeText)
  end

  ACME  = id(Ledger::Accounts::ID, 1)
  EMPTY = id(Ledger::Accounts::ID, 2)

  def self.seeded(& : Punch::Database ->) : Nil
    Punch::Spec.database(schema: SCHEMA) do |db|
      db.write do |writer|
        Ledger::Accounts::Table.insert(writer, name: "Acme", plan: "pro", created_at: NOW)
        Ledger::Accounts::Table.insert(writer, name: "Empty", created_at: NOW)
        ada = Punch.cannot_violate(Ledger::Customers::Table.insert(writer, account_id: ACME, name: "Ada", email: email("ada@example.com")))
        bob = Punch.cannot_violate(Ledger::Customers::Table.insert(writer, account_id: ACME, name: "Bob", email: email("bob@example.com"), company_name: "Bob GmbH", vat_id: "DE123"))
        Ledger::Customers::Table.insert(writer, account_id: ACME, name: "Cy", email: email("cy@example.com"))
        writer.exec(<<-SQL, ada.id.value, bob.id.value)
          INSERT INTO invoices (id, account_id, customer_id, number, status, issued_on, due_on, sent_at, total_cents, created_at) VALUES
            (1, 1, ?1, 'INV-0001', 'sent',  '2026-09-01', '2026-09-15', '2026-09-01T09:00:00Z', 1000, '2026-09-01T00:00:00Z'),
            (2, 1, ?1, 'INV-0002', 'draft', NULL,         NULL,         NULL,                     0,    '2026-09-02T00:00:00Z'),
            (3, 1, ?2, 'INV-0003', 'sent',  '2026-10-01', '2026-10-31', '2026-10-01T09:00:00Z', 2500, '2026-10-01T00:00:00Z')
          SQL
        writer.exec("INSERT INTO invoice_lines (id, invoice_id, position, description, quantity, unit_price_cents) VALUES (1, 1, 1, 'Work', 2.5, 300), (2, 1, 2, 'Travel', 1.0, 250)")
        writer.exec("INSERT INTO payments (invoice_id, amount_cents, paid_at, raw) VALUES (1, 1000, '2026-09-10', x'00ff')")
      end
      yield db
    end
  end
end

private alias Q = GeneratedSpec::Q

describe "generated queries" do
  it "run with their derived types" do
    GeneratedSpec.seeded do |db|
      acme, empty = GeneratedSpec::ACME, GeneratedSpec::EMPTY
      invoice = ->(value : Int32) { GeneratedSpec.id(Ledger::Invoices::ID, value) }
      customer = ->(value : Int32) { GeneratedSpec.id(Ledger::Customers::ID, value) }
      db.read do |reader|
        record = Q.invoice_by_id(reader, id: invoice.call(1)).should_not be_nil
        record.should be_a(Ledger::Invoices::Record)
        record.number.to_s.should eq("INV-0001")
        record.sent_at.should eq(Time.utc(2026, 9, 1, 9, 0, 0))
        Q.invoice_by_id(reader, id: invoice.call(99)).should be_nil
        Q.invoices_for_customer(reader, customer_id: customer.call(1), limit: 10, offset: 0).map(&.sent_at).should eq([nil, Time.utc(2026, 9, 1, 9, 0, 0)])
        Q.customer_by_email(reader, account_id: acme, email: GeneratedSpec.email("BOB@example.com")).try(&.company_name).should eq("Bob GmbH")
        Q.overdue_invoices(reader, account_id: acme, today: "2026-10-07").map(&.number.to_s).should eq(["INV-0001"])
        Q.customers_matching(reader, account_id: acme, q: GeneratedSpec.text("o")).map(&.name).should eq(["Bob"])
        Q.literals(reader).try(&.text).should eq("\\n\#{total}")
        Q.invoices_with_customer(reader, account_id: acme).map(&.email.to_s).should eq(["ada@example.com", "ada@example.com", "bob@example.com"])
        Q.lines_for_account(reader, account_id: acme).map(&.quantity).should eq([2.5, 1.0])
        with_account = Q.invoice_with_account(reader, id: invoice.call(2)).should_not be_nil
        {with_account.account_name, with_account.issued_on, with_account.customer_id}.should eq({"Acme", nil, customer.call(1)})
        Q.invoices_with_last_payment(reader, account_id: acme).map(&.amount_cents).should eq([1000, nil, nil])
        Q.customers_with_invoice_count(reader, account_id: acme).map(&.invoice_count).should eq([2, 1, 0])
        Q.count_invoices(reader, account_id: empty).try(&.n).should eq(0)
        Q.open_amount(reader, account_id: acme).try(&.open_cents).should eq(3500)
        Q.open_amount(reader, account_id: empty).try(&.open_cents).should be_nil
        Q.paid_total(reader, invoice_id: 2).try(&.paid).should eq(0.0)
        Q.revenue_by_status(reader, account_id: acme, min_count: 0).map { |row| {row.status, row.cents} }.should eq([{"draft", 0}, {"sent", 3500}])
        Q.invoice_date_range(reader, account_id: empty).try { |row| {row.first_issued, row.last_issued} }.should eq({nil, nil})
        Q.line_totals(reader, invoice_id: invoice.call(1)).map(&.line_cents).should eq([750.0, 250.0])
        Q.customer_display_names(reader, account_id: acme).map { |row| {row.display_name, row.vat} }.should eq([{"Ada", ""}, {"Bob GmbH", "DE123"}, {"Cy", ""}])
        Q.invoice_badges(reader, account_id: acme).map(&.badge).should eq(["sent", "draft", "sent"])
        Q.invoices_issued_since(reader, since: "2026-09-15", account_id: acme).map(&.issued).should eq(["2026-10-01"])
        Q.customers_with_unpaid(reader, account_id: acme).map(&.name).should eq(["Ada", "Bob"])
        Q.invoice_with_paid(reader, id: invoice.call(2)).try(&.paid_cents).should be_nil
        Q.top_customers(reader, account_id: acme, limit: 5).map { |row| {row.name, row.cents} }.should eq([{"Bob", 2500}, {"Ada", 1000}])
        Q.running_totals(reader, customer_id: customer.call(1)).map(&.running_cents).should eq([0, 1000])
        Q.invoices_by_ids(reader, ids: "[1,3]").map(&.number.to_s).should eq(["INV-0001", "INV-0003"])
        Q.invoices_in(reader, ids: [invoice.call(1), invoice.call(3)]).as(Array).map(&.number.to_s).should eq(["INV-0001", "INV-0003"])
        Q.invoices_in(reader, ids: [] of Ledger::Invoices::ID).should eq([] of Q::InvoicesIn::Row)
        too_many = Q.invoices_in(reader, ids: Array.new(Punch::Stored::ARRAY_MAX + 1) { invoice.call(1) })
        too_many.as(Punch::Invalid).code.should eq("too_many")
        too_many.as(Punch::Invalid).params.should eq({"max" => 10_000})
        Q.invoice_lines_json(reader, id: invoice.call(1)).try(&.lines_json).should eq(%([{"d":"Work","q":2.5},{"d":"Travel","q":1.0}]))
        Q.invoice_lines_json(reader, id: invoice.call(2)).should be_nil
      end

      db.write do |writer|
        now = GeneratedSpec::NOW
        inserted = Punch.cannot_violate(Q.insert_invoice(writer, account_id: acme, customer_id: customer.call(3), number: GeneratedSpec.number("INV-0004"), created_at: now)).should_not be_nil
        {inserted.number.to_s, inserted.status, inserted.total_cents, inserted.sent_at, inserted.created_at}.should eq({"INV-0004", "draft", 0, nil, now})
        Punch.cannot_violate(Q.insert_customer(writer, account_id: acme, name: "Dee", email: GeneratedSpec.email("dee@example.com"), company_name: nil)).try(&.email.to_s).should eq("dee@example.com")
        Q.mark_sent(writer, now: now, id: inserted.id).try(&.sent_at).should eq(now)
        Q.mark_sent(writer, now: now, id: inserted.id).should be_nil
        Q.add_to_total(writer, delta_cents: 500, id: inserted.id).should eq(1)
        Q.delete_line(writer, id: GeneratedSpec.id(Ledger::InvoiceLines::ID, 2), invoice_id: invoice.call(1)).should be_nil
        Punch.cannot_violate(Q.upsert_account_plan(writer, id: empty, name: "Empty", plan: "pro", created_at: now)).try(&.plan).should eq("pro")
      end
    end
  end

  it "narrow and sort by declared clauses" do
    GeneratedSpec.seeded do |db|
      acme = GeneratedSpec::ACME
      ada = GeneratedSpec.id(Ledger::Customers::ID, 1)
      db.read do |reader|
        numbers = ->(filter : Q::Search::Filter, order : Q::Search::Order) do
          Q.search(reader, account_id: acme, limit: 10, offset: 0, filter: filter, order: order, direction: :desc).map(&.number.to_s)
        end
        # Issued first, as written: no date (NULL) first; backwards, last.
        Q.search(reader, account_id: acme, limit: 10, offset: 0).map(&.number.to_s).should eq(%w[INV-0002 INV-0001 INV-0003])
        numbers.call(Q::Search::Filter.new, Q::Search::Order::Amount).should eq(%w[INV-0003 INV-0001 INV-0002])
        numbers.call(Q::Search::Filter.new(status: "sent"), Q::Search::Order::Issued).should eq(%w[INV-0003 INV-0001])
        numbers.call(Q::Search::Filter.new(customer_id: ada, issued_from: "2026-08-01"), Q::Search::Order::Amount).should eq(%w[INV-0001])
        numbers.call(Q::Search::Filter.new(q: GeneratedSpec.text("Bo"), status: "sent", customer_id: ada), Q::Search::Order::Issued).should be_empty
        numbers.call(Q::Search::Filter.new(q: GeneratedSpec.text("%")), Q::Search::Order::Issued).should be_empty        # typed text matches itself
        numbers.call(Q::Search::Filter.new(q: Punch::LikeText.pattern("%")), Q::Search::Order::Issued).size.should eq(3) # the opt-out
        Q.search(reader, account_id: GeneratedSpec::EMPTY, limit: 10, offset: 0, filter: Q::Search::Filter.new(status: "sent")).should be_empty
        Q.search(reader, account_id: acme, limit: 1, offset: 1, order: :amount).map(&.number.to_s).should eq(%w[INV-0001])

        Q.count_filtered(reader, account_id: acme).try(&.invoices).should eq(3)
        Q.count_filtered(reader, account_id: acme, filter: Q::CountFiltered::Filter.new(unsent: true)).try(&.invoices).should eq(1)
        Q.count_filtered(reader, account_id: acme, filter: Q::CountFiltered::Filter.new(unsent: true, customer_id: ada)).try(&.invoices).should eq(1)
        Q.count_filtered(reader, account_id: acme, filter: Q::CountFiltered::Filter.new(customer_id: ada)).try(&.invoices).should eq(2)

        in_state = ->(filter : Q::InvoicesInState::Filter) { Q.invoices_in_state(reader, account_id: acme, filter: filter).map(&.number.to_s) }
        in_state.call(Q::InvoicesInState::Filter.new).should eq(%w[INV-0001 INV-0002 INV-0003])
        in_state.call(Q::InvoicesInState::Filter.new(state: :draft)).should eq(%w[INV-0002])
        in_state.call(Q::InvoicesInState::Filter.new(state: :sent)).should eq(%w[INV-0003])
        in_state.call(Q::InvoicesInState::Filter.new(state: :paid)).should eq(%w[INV-0001])
        in_state.call(Q::InvoicesInState::Filter.new(state: :paid, customer_id: GeneratedSpec.id(Ledger::Customers::ID, 2))).should be_empty
      end
    end
  end

  it "page through every order by cursor, without skipping or repeating a row" do
    GeneratedSpec.seeded do |db|
      acme = GeneratedSpec::ACME
      db.write do |writer|
        # Ties in every sort value but the ID: equal totals, equal times, and
        # customers with the same name.
        writer.exec("INSERT INTO customers (id, account_id, name, email) VALUES (4, 1, 'Ada', 'ada2@example.com')")
        (4..23).each do |id|
          writer.exec("INSERT INTO invoices (id, account_id, customer_id, number, status, total_cents, created_at) VALUES (?, 1, ?, ?, ?, ?, ?)",
            id.to_i64, (id.even? ? 4 : 2).to_i64, "INV-#{id.to_s.rjust(4, '0')}", id % 3 == 0 ? "sent" : "draft", (id % 4 * 500).to_i64, "2026-09-0#{id % 5 + 1}T00:00:00.000000000Z")
        end
        # Stored as Punch writes times: the seed's short form sorts apart
        # from it, and a cursor holds the form Punch writes.
        writer.exec("UPDATE invoices SET created_at = replace(created_at, ':00Z', ':00.000000000Z') WHERE id <= 3")
      end
      db.read do |reader|
        Q::InvoicePage::Order.values.each_cartesian(Punch::Database::Direction.values) do |order, direction|
          everything = Q.invoice_page(reader, account_id: acme, order: order, direction: direction, limit: 100)
          everything.last_page?.should be_true

          sorted = case order
                   in .created?  then everything.rows.sort_by { |row| {row.created_at.to_unix, row.id.value} }
                   in .amount?   then everything.rows.sort_by { |row| {row.total_cents, -row.id.value} }
                   in .customer? then everything.rows.sort_by { |row| {row.customer_name, row.id.value} }
                   end
          sorted.reverse! if direction.desc?
          everything.rows.map(&.id).should eq(sorted.map(&.id))

          seen = [] of Ledger::Invoices::ID
          after = nil
          pages = 0
          loop do
            page = Q.invoice_page(reader, account_id: acme, order: order, direction: direction, after: after, limit: 4)
            seen.concat(page.map(&.id))
            pages += 1
            # A cursor travels as text: through a query string and back.
            after = page.next_after.try { |cursor| Q::InvoicePage::Cursor.parse(cursor.to_s).as(Q::InvoicePage::Cursor) } || break
          end

          seen.should eq(everything.rows.map(&.id))
          pages.should eq(6) # 23 rows: five full pages and three rows, no empty page after
        end

        # With a filter, and the order and direction taken from the cursor.
        sent = Q::InvoicePage::Filter.new(status: "sent")
        first = Q.invoice_page(reader, account_id: acme, order: :amount, direction: :desc, filter: sent, limit: 2)
        cursor = first.next_after.should_not be_nil
        {cursor.order, cursor.direction}.should eq({Q::InvoicePage::Order::Amount, Punch::Database::Direction::Desc})
        rest = Q.invoice_page(reader, account_id: acme, order: :created, filter: sent, after: cursor, limit: 100)
        all_sent = Q.invoice_page(reader, account_id: acme, order: :amount, direction: :desc, filter: sent, limit: 100)
        (first.rows + rest.rows).map(&.id).should eq(all_sent.rows.map(&.id))

        # The same page's one row by key: its statement and clauses, never a copy.
        in_page = ->(filter : Q::InvoicePage::Filter) { Q.invoice_page(reader, account_id: acme, filter: filter, limit: 100).map(&.id) }
        in_page.call(Q::InvoicePage::Filter.new).each do |id|
          [Q::InvoicePage::Filter.new, sent].each do |filter|
            Q.invoice_page_by_key(reader, account_id: acme, key: id, filter: filter).try(&.id).should eq(in_page.call(filter).find(&.==(id)))
          end
        end
        Q.invoice_page_by_key(reader, account_id: GeneratedSpec::EMPTY, key: in_page.call(Q::InvoicePage::Filter.new).first).should be_nil

        # A page that ends exactly on the last row has no cursor.
        Q.invoice_page(reader, account_id: acme, limit: 23).next_after.should be_nil
        Q.invoice_page(reader, account_id: acme, limit: 22).next_after.should_not be_nil
        expect_raises(ArgumentError, "a page holds at least one row, not 0") { Q.invoice_page(reader, account_id: acme, limit: 0) }

        # The statement's own order.
        names = [] of {String, Int64}
        after = nil
        loop do
          page = Q.customer_page(reader, account_id: acme, after: after, limit: 1)
          names.concat(page.map { |record| {record.name, record.id.value} })
          after = page.next_after || break
        end
        names.should eq([{"Ada", 1_i64}, {"Ada", 4_i64}, {"Bob", 2_i64}, {"Cy", 3_i64}])
      end
    end
  end

  it "refuse a token that is not a cursor of the query" do
    good = Q::InvoicePage::Cursor.parse(Punch::Paged::Cursor.encode("amount", [500_i64, 7_i64] of Punch::Database::Value)).as(Q::InvoicePage::Cursor)
    {good.order, good.direction, good.values}.should eq({Q::InvoicePage::Order::Amount, Punch::Database::Direction::Asc, [500_i64, 7_i64]})
    backwards = Q::InvoicePage::Cursor.parse(Punch::Paged::Cursor.encode("amount", [500_i64, 7_i64] of Punch::Database::Value, :desc)).as(Q::InvoicePage::Cursor)
    backwards.direction.should eq(Punch::Database::Direction::Desc)
    [
      "", "not base64!", "x" * 2000, Base64.urlsafe_encode("{}"), Base64.urlsafe_encode("not json"),
      Punch::Paged::Cursor.encode("oldest", [7_i64] of Punch::Database::Value),        # no such order
      Punch::Paged::Cursor.encode("amount", [7_i64] of Punch::Database::Value),        # too few values
      Punch::Paged::Cursor.encode("amount", ["500", 7_i64] of Punch::Database::Value), # text where a number goes
      Punch::Paged::Cursor.encode(nil, ["Ada", 1_i64] of Punch::Database::Value),      # no order
    ].each do |raw|
      Q::InvoicePage::Cursor.parse(raw).should eq(Punch::Invalid.new("invalid_cursor"))
    end
    Q::CustomerPage::Cursor.parse(Punch::Paged::Cursor.encode(nil, ["Ada", 1_i64] of Punch::Database::Value)).should be_a(Q::CustomerPage::Cursor)
    Q::CustomerPage::Cursor.parse(Punch::Paged::Cursor.encode("name", ["Ada", 1_i64] of Punch::Database::Value)).should be_a(Punch::Invalid)
  end

  it "parse a filter from query parameters, as any input" do
    filter = Q::Search::Filter.from_query(URI::Params.parse("status=sent&customer_id=2&q=")).as(Q::Search::Filter)
    {filter.status, filter.customer_id.try(&.value), filter.q}.should eq({"sent", 2, nil})
    Q::Search::Filter.from_query(URI::Params.parse("customer_id=x")).should be_rejected("customer_id", code: "expected_integer")
    Q::CountFiltered::Filter.from_query(URI::Params.parse("unsent=true")).as(Q::CountFiltered::Filter).unsent?.should be_true
    Q::CountFiltered::Filter.from_query(URI::Params.new).as(Q::CountFiltered::Filter).unsent?.should be_false
    Q::Search::Order.parse("amount").should eq(Q::Search::Order::Amount)
    Q::InvoicesInState::Filter.from_query(URI::Params.parse("state=paid")).as(Q::InvoicesInState::Filter).state.should eq(Ledger::InvoiceState::Paid)
    Q::InvoicesInState::Filter.from_query(URI::Params.parse("state=void")).should be_rejected("state", code: "invalid_choice")
  end

  it "share behaviour between a record and a query row" do
    GeneratedSpec.seeded do |db|
      db.read do |reader|
        Q.invoices_with_customer(reader, account_id: GeneratedSpec::ACME).map(&.email_domain).uniq!.should eq(["example.com"])
        bob = Ledger::Customers::Table.find(reader, GeneratedSpec.id(Ledger::Customers::ID, 2)).should_not be_nil
        {bob.email_domain, bob.display_name}.should eq({"example.com", "Bob GmbH"})
      end
    end
  end

  it "find, insert, update, and delete records by primary key" do
    GeneratedSpec.seeded do |db|
      db.write do |writer|
        customer = Punch.cannot_violate(Ledger::Customers::Table.insert(writer, account_id: GeneratedSpec::ACME, name: "Eve", email: GeneratedSpec.email("eve@example.com")))
        customer.active.should be_true # the column default
        customer.archived_at.should be_nil
        archived = customer.copy_with(active: false, archived_at: GeneratedSpec::NOW, vat_id: "AT1")
        Ledger::Customers::Table.update(writer, archived).should eq(archived)
        Ledger::Customers::Table.find(writer, customer.id).should eq(archived)
        Ledger::Customers::Table.delete(writer, customer.id).should be_true
        Ledger::Customers::Table.delete(writer, customer.id).should be_false
        Ledger::Customers::Table.find(writer, customer.id).should be_nil
        Ledger::Customers::Table.update(writer, archived).should be_nil
      end
    end
  end

  it "handle composite keys and quoted column names" do
    GeneratedSpec.seeded do |db|
      db.write do |writer|
        setting = Punch.cannot_violate(Ledger::Settings::Table.insert(writer, account_id: GeneratedSpec::ACME, key: "theme", value: "dark"))
        Ledger::Settings::Table.find(writer, account_id: GeneratedSpec::ACME, key: "theme").should eq(setting)
        Ledger::Settings::Table.update(writer, setting.copy_with(value: "light")).try(&.value).should eq("light")
        Ledger::Settings::Table.delete(writer, account_id: GeneratedSpec::ACME, key: "theme").should be_true
      end
    end
  end

  describe "violations" do
    it "returns a unique violation from insert and update, and the transaction goes on" do
      GeneratedSpec.seeded do |db|
        db.write do |writer|
          taken = Ledger::Customers::Table.insert(writer, account_id: GeneratedSpec::ACME, name: "Ada 2", email: GeneratedSpec.email("ada@example.com"))
          taken.should be_a(Ledger::Customers::EmailTaken)
          taken.should be_rejected("email", code: "taken")
          # Only the statement was undone; the writer still works.
          other = Punch.cannot_violate(Ledger::Customers::Table.insert(writer, account_id: GeneratedSpec::EMPTY, name: "Ada", email: GeneratedSpec.email("ada@example.com")))
          Ledger::Customers::Table.update(writer, other.copy_with(account_id: GeneratedSpec::ACME)).should be_a(Ledger::Customers::EmailTaken)
          Ledger::Customers::Table.find(writer, other.id).try(&.account_id).should eq(GeneratedSpec::EMPTY)
        end
        db.read { |reader| Q.customer_by_email(reader, account_id: GeneratedSpec::EMPTY, email: GeneratedSpec.email("ada@example.com")).should_not be_nil }
      end
    end

    it "returns them from named writes, by the constraint SQLite names" do
      GeneratedSpec.seeded do |db|
        db.write do |writer|
          customer = GeneratedSpec.id(Ledger::Customers::ID, 1)
          Q.insert_invoice(writer, account_id: GeneratedSpec::ACME, customer_id: customer, number: GeneratedSpec.number("INV-0001"), created_at: GeneratedSpec::NOW)
            .should be_a(Ledger::Invoices::NumberTaken)
          Q.insert_customer(writer, account_id: GeneratedSpec::ACME, name: "Bob", email: GeneratedSpec.email("bob@example.com"), company_name: nil)
            .should be_a(Ledger::Customers::EmailTaken)
          # The same number in another account is no violation.
          Q.insert_invoice(writer, account_id: GeneratedSpec::EMPTY, customer_id: customer, number: GeneratedSpec.number("INV-0001"), created_at: GeneratedSpec::NOW)
            .should be_a(Ledger::Invoices::Record)
        end
      end
    end

    it "still raises for constraints that are not values: foreign keys" do
      GeneratedSpec.seeded do |db|
        db.write do |writer|
          expect_raises(Punch::Database::ConstraintError, /FOREIGN KEY/) do
            Ledger::Customers::Table.insert(writer, account_id: GeneratedSpec.id(Ledger::Accounts::ID, 99), name: "X", email: GeneratedSpec.email("x@example.com"))
          end
          nil
        end
      end
    end

    it "raises from cannot_violate when the write did violate" do
      GeneratedSpec.seeded do |db|
        db.write do |writer|
          expect_raises(Punch::Database::ConstraintError, "customers.account_id, customers.email was violated by a write that cannot violate it") do
            Punch.cannot_violate(Ledger::Customers::Table.insert(writer, account_id: GeneratedSpec::ACME, name: "Ada", email: GeneratedSpec.email("ada@example.com")))
          end
          nil
        end
      end
    end

    it "carries its constraint and field" do
      taken = Ledger::Invoices::NumberTaken.new
      {taken.constraint, taken.field}.should eq({"invoices.account_id, invoices.number", "number"})
      taken.rejection("invoice", "number").should be_rejected("invoice", "number", code: "taken")
    end
  end

  it "stores Time as fixed-width UTC text that sorts in time order" do
    GeneratedSpec.seeded do |db|
      zoned = Time.local(2026, 10, 7, 12, 0, 0, location: Time::Location.fixed(7200))
      db.write { |writer| Ledger::Accounts::Table.insert(writer, name: "Zoned", created_at: zoned) }
      stored = db.read(&.query_one?("SELECT created_at FROM accounts WHERE name = 'Zoned'", &.read(String)))
      stored.should eq("2026-10-07T10:00:00.000000000Z")
      Punch::Stored.dump(GeneratedSpec::NOW).should eq("2026-10-07T10:00:00.123456789Z")
    end
  end

  it "reads SQLite's own datetime() text as UTC" do
    GeneratedSpec.seeded do |db|
      db.write(&.exec("UPDATE accounts SET created_at = '2026-10-07 08:30:00' WHERE id = 1"))
      account = db.read { |reader| Ledger::Accounts::Table.find(reader, GeneratedSpec::ACME) }.should_not be_nil
      account.created_at.should eq(Time.utc(2026, 10, 7, 8, 30, 0))
    end
  end

  it "raises with table, column, and row ID when a stored value does not parse" do
    GeneratedSpec.seeded do |db|
      db.write(&.exec("UPDATE customers SET email = 'not an email' WHERE id = 2"))
      error = expect_raises(Punch::Database::RowError, "customers.email in row 2 does not parse as Punch::Email: invalid_email") do
        db.read { |reader| Ledger::Customers::Table.find(reader, GeneratedSpec.id(Ledger::Customers::ID, 2)) }
      end
      {error.table, error.column, error.row_id, error.reason}.should eq({"customers", "email", 2, "invalid_email"})
      error.message.to_s.should_not contain("not an email")

      db.write(&.exec("UPDATE customers SET active = 7 WHERE id = 1"))
      expect_raises(Punch::Database::RowError, "customers.active in row 1 does not parse as Bool: not_boolean") do
        db.read { |reader| Ledger::Customers::Table.find(reader, GeneratedSpec.id(Ledger::Customers::ID, 1)) }
      end

      db.write(&.exec("UPDATE invoices SET number = 'A-1' WHERE id = 1"))
      expect_raises(Punch::Database::RowError, "invoices.number in a row (its ID was not selected) does not parse as Ledger::InvoiceNumber") do
        db.read(&.query_all("SELECT number FROM invoices WHERE id = 1") { |row| Punch::Stored.load(Ledger::InvoiceNumber, row.read(String), "invoices", "number", nil) })
      end
    end
  end
end

describe Punch::Database::Audit do
  it "parses every mapped column through the generated audits, in batches" do
    GeneratedSpec.seeded do |db|
      Punch::Database::Audit.tables.should contain("invoices")
      audit = Punch::Database::Audit.run(db, batch: 2)
      audit.rows["invoices"].should eq(3)
      audit.rows["customers"].should eq(3)
      audit.clean?.should be_true
      # The seed writes times as SQLite text, not in Punch's stored form.
      audit.findings.map { |found| "#{found.table}.#{found.column}" }.should eq(%w[invoices.created_at invoices.sent_at])
      sent = audit.findings.find!(&.column.==("sent_at"))
      {sent.noncanonical, sent.noncanonical_rows, sent.invalid_count}.should eq({2_i64, [1_i64, 3_i64], 0_i64})
    end
  end

  it "reports values that do not parse by reason and row, never the values" do
    GeneratedSpec.seeded do |db|
      db.write do |writer|
        writer.exec("UPDATE customers SET email = 'nope' || id WHERE id IN (2, 3)")
        writer.exec("UPDATE accounts SET created_at = 'soon' WHERE id = 2")
      end
      audit = Punch::Database::Audit.run(db)
      audit.clean?.should be_false
      audit.messages.should eq([
        "accounts.created_at: 1 value does not parse as Time (1 invalid_time); rows 2",
        "customers.email: 2 values do not parse as Punch::Email (2 invalid_email); rows 2, 3",
        "invoices.created_at: 3 values are not in Time's stored form; rows 1, 2, 3",
        "invoices.sent_at: 2 values are not in Time's stored form; rows 1, 3",
      ])
      audit.to_json.should_not contain("nope2")
      audit.to_json.should_not contain("soon")
    end
  end

  it "is punch db:audit in the app's binary, failing on values that do not parse" do
    Punch::Spec.database(file: true, schema: GeneratedSpec::SCHEMA) do |db|
      db.write { |writer| writer.exec("INSERT INTO accounts (id, name, created_at) VALUES (1, 'Acme', '2026-10-01T00:00:00.000000000Z')") }
      stdout, stderr = IO::Memory.new, IO::Memory.new
      Punch::CLI.run(["db:audit", db.path], stdout, stderr, Punch::CLI::APP_COMMANDS).should eq(0)
      stdout.to_s.should eq("#{db.path}: 1 rows in 1 tables, every value parses.\n")

      db.write { |writer| writer.exec("UPDATE accounts SET created_at = 'soon'") }
      stdout = IO::Memory.new
      Punch::CLI.run(["db:audit", db.path, "--json"], stdout, stderr, Punch::CLI::APP_COMMANDS).should eq(1)
      error = JSON.parse(stdout.to_s)["error"]
      error["code"].should eq("values_do_not_parse")
      error["details"]["audit"]["findings"][0]["invalid"].should eq({"invalid_time" => 1})
    end
  end

  it "runs every night at the lowest priority and records each unparseable column as an error" do
    Punch::Job::Queue.tasks.find!(&.type.==("Punch::Database::Audit::Run")).schedule.to_s.should eq("cron 0 3 * * *")
    Punch::Job::Queue::Registry.descriptions.find!(&.type.==("Punch::Database::Audit::Run")).priority.should eq(-100)
    previous = Punch::Spec.schema
    Punch::Spec.schema = GeneratedSpec::SCHEMA
    begin
      Punch::Spec.db.write do |writer|
        writer.exec("INSERT INTO accounts (id, name, created_at) VALUES (1, 'Acme', '2026-10-01T00:00:00.000000000Z')")
        writer.exec("INSERT INTO customers (account_id, name, email) VALUES (1, 'Ada', 'nope')")
      end
      store = Punch::Spec.ops
      Punch::Spec.queue.enqueue(Punch::Database::Audit::Run.new)
      Punch::Spec.perform_jobs.map(&.outcome.to_s).should eq(%w[Done])
      error = store.errors.find!(&.exception.==("Punch::Database::Audit::Unparseable"))
      error.source.should eq("punch.audit customers.email")
      error.message.should eq("customers.email: 1 value does not parse as Punch::Email (1 invalid_email); rows 1")
      fields = JSON.parse(store.records(kind: "job").first.fields)
      fields["punch.audit.invalid"].should eq(1)
    ensure
      Punch::Spec.schema = previous
    end
  end
end

module GeneratedSpec
  def self.with_ring(ring : Punch::KeyRing = Punch::KeyRing.new([Punch::KeyRing::Key.generate(1)]), &) : Nil
    previous = Punch::KeyRing.current?
    Punch::KeyRing.current = ring
    yield
  ensure
    previous.try { |saved| Punch::KeyRing.current = saved }
  end

  def self.raw(db : Punch::Database, column : String, id : Ledger::Contacts::ID) : Bytes?
    db.read { |reader| reader.query_one?("SELECT #{column} FROM contacts WHERE id = ?", id.value) { |row| row.read(Bytes?) } }
  end

  def self.phone(value : String) : Punch::Secret(Punch::NonEmptyString)
    Punch::Secret.new(Punch::NonEmptyString.parse(value).as(Punch::NonEmptyString))
  end

  def self.contact(writer : Punch::Writer, note : Punch::Secret(String)? = nil, born : Punch::Secret(Time)? = nil, vip : Punch::Secret(Bool)? = nil,
                   number : String = "+49 30 1234567", customer : Int32 = 1) : Ledger::Contacts::Record
    case found = Ledger::Contacts::Table.insert(writer, customer_id: id(Ledger::Customers::ID, customer), phone: phone(number), note: note, born: born, vip: vip)
    in Ledger::Contacts::Record     then found
    in Ledger::Contacts::PhoneTaken then fail "#{number} is taken"
    end
  end

  def self.by_phone(db : Punch::Database, number : String, customer : Int32 = 1) : Ledger::Contacts::Record?
    db.read { |reader| Q.contact_by_phone(reader, customer_id: id(Ledger::Customers::ID, customer), phone: phone(number).unwrap) }
  end
end

describe "encrypted columns" do
  it "encrypts on write and decrypts, then parses, on read, as Punch::Secret" do
    GeneratedSpec.with_ring do
      GeneratedSpec.seeded do |db|
        born = Time.utc(1990, 5, 17)
        contact = db.write { |writer| GeneratedSpec.contact(writer, note: Punch::Secret.new("prefers mail"), born: Punch::Secret.new(born), vip: Punch::Secret.new(true)) }
        found = db.read { |reader| Ledger::Contacts::Table.find(reader, contact.id) } || fail "no contact"
        found.phone.unwrap.value.should eq("+49 30 1234567")
        found.note.try(&.unwrap).should eq("prefers mail")
        found.born.try(&.unwrap).should eq(born)
        found.vip.try(&.unwrap).should be_true
        found.inspect.should_not contain("1234567")
        found.inspect.should contain("[REDACTED]")

        raw = GeneratedSpec.raw(db, "phone", contact.id) || fail "no phone"
        raw.should be_encrypted_for("contacts", "phone")
        raw.should_not be_encrypted_for("contacts", "note")
        String.new(raw).should_not contain("1234567")
        {raw[0], raw.size}.should eq({1_u8, Punch::KeyRing::Encryptor::OVERHEAD + "+49 30 1234567".bytesize})
        # A fresh nonce each time: equal values never look equal.
        again = db.write { |writer| GeneratedSpec.contact(writer, customer: 2) }
        GeneratedSpec.raw(db, "phone", again.id).should_not eq(raw)
        GeneratedSpec.raw(db, "note", again.id).should be_nil
      end
    end
  end

  it "encrypts parameters written to an encrypted column and decrypts selected ones; expressions are ciphertext" do
    GeneratedSpec.with_ring do
      GeneratedSpec.seeded do |db|
        contact = db.write { |writer| GeneratedSpec.contact(writer) }
        db.write { |writer| GeneratedSpec::Q.set_contact_note(writer, note: Punch::Secret.new("call after 5"), id: contact.id) }
        GeneratedSpec.raw(db, "note", contact.id).should be_encrypted_for("contacts", "note")
        row = db.read { |reader| GeneratedSpec::Q.contact_phones(reader, customer_id: contact.customer_id) }.first
        row.note.try(&.unwrap).should eq("call after 5")
        row.either.should eq(GeneratedSpec.raw(db, "note", contact.id))

        db.write { |writer| GeneratedSpec::Q.set_contact_note(writer, note: nil, id: contact.id) }
        GeneratedSpec.raw(db, "note", contact.id).should be_nil
      end
    end
  end

  it "refuses ciphertext moved to another column, and values under a key the ring no longer has, without showing them" do
    GeneratedSpec.with_ring do
      GeneratedSpec.seeded do |db|
        contact = db.write { |writer| GeneratedSpec.contact(writer, note: Punch::Secret.new("x")) }
        db.write { |writer| writer.exec("UPDATE contacts SET note = phone WHERE id = ?", contact.id.value) }
        error = expect_raises(Punch::Database::RowError) { db.read { |reader| Ledger::Contacts::Table.find(reader, contact.id) } }
        error.message.should eq("contacts.note in row #{contact.id.value} does not parse as Punch::Encrypted(String): not_decrypting")

        db.write { |writer| writer.exec("UPDATE contacts SET note = NULL WHERE id = ?", contact.id.value) }
        GeneratedSpec.with_ring do # another root key
          error = expect_raises(Punch::Database::RowError) { db.read { |reader| Ledger::Contacts::Table.find(reader, contact.id) } }
          error.reason.should eq("not_decrypting")
        end
      end
    end
  end

  it "decrypts under every key of the ring and re-encrypts under the signing key on update" do
    old = Punch::KeyRing::Key.generate(1)
    GeneratedSpec.with_ring(Punch::KeyRing.new([old])) do
      GeneratedSpec.seeded do |db|
        contact = db.write { |writer| GeneratedSpec.contact(writer) }
        GeneratedSpec.with_ring(Punch::KeyRing.new([Punch::KeyRing::Key.generate(2), old])) do
          found = db.read { |reader| Ledger::Contacts::Table.find(reader, contact.id) } || fail "no contact"
          found.phone.unwrap.value.should eq("+49 30 1234567")
          Punch::KeyRing.current.uses[1].should eq(1)
          db.write { |writer| Ledger::Contacts::Table.update(writer, found) }
          (GeneratedSpec.raw(db, "phone", contact.id) || fail "no phone")[1, 4].should eq(Bytes[0, 0, 0, 2])
        end
      end
    end
  end

  it "is audited: values that do not decrypt by row, and how many values each key encrypted" do
    GeneratedSpec.with_ring(Punch::KeyRing.new([Punch::KeyRing::Key.generate(1)])) do
      GeneratedSpec.seeded do |db|
        first = db.write { |writer| GeneratedSpec.contact(writer, note: Punch::Secret.new("a")) }
        GeneratedSpec.with_ring(Punch::KeyRing.new([Punch::KeyRing::Key.generate(2), Punch::KeyRing.current.keys.first])) do
          db.write { |writer| GeneratedSpec.contact(writer, number: "+49 30 7654321") }
          audit = Punch::Database::Audit.run(db)
          audit.clean?.should be_true
          audit.key_lines.should eq([
            "contacts.born: encrypted, no values",
            "contacts.note: encrypted, 1 under key 1",
            "contacts.phone: encrypted, 1 under key 2, 1 under key 1",
            "contacts.phone_index: blind index, 1 under key 2, 1 under key 1",
            "contacts.vip: encrypted, no values",
          ])
          JSON.parse(audit.to_json)["encrypted"][2]["keys"].should eq({"2" => 1, "1" => 1})

          db.write { |writer| writer.exec("UPDATE contacts SET note = phone WHERE id = ?", first.id.value) }
          audit = Punch::Database::Audit.run(db)
          audit.messages.first.should eq("contacts.note: 1 value does not parse as Punch::Encrypted(String) (1 not_decrypting); rows #{first.id.value}")
        end
      end
    end
  end
end

describe "blind indexes" do
  it "is written by every Table write, left out of the record, and finds the row by its value" do
    GeneratedSpec.with_ring do
      GeneratedSpec.seeded do |db|
        contact = db.write { |writer| GeneratedSpec.contact(writer) }
        raw = GeneratedSpec.raw(db, "phone_index", contact.id) || fail "no index"
        raw.should eq(Punch::Stored.blind_index(GeneratedSpec.phone("+49 30 1234567"), "contacts", "phone_index"))
        {raw[0, 5], raw.size}.should eq({Bytes[1, 0, 0, 0, 1], 37})
        contact.responds_to?(:phone_index).should be_false

        GeneratedSpec.by_phone(db, "+49 30 1234567").try(&.id).should eq(contact.id)
        GeneratedSpec.by_phone(db, "+49 30 1234568").should be_nil
        GeneratedSpec.by_phone(db, "+49 30 1234567", customer: 2).should be_nil
        db.read { |reader| Q.contact_ids(reader, customer_id: contact.customer_id, filter: Q::ContactIds::Filter.new(phone: GeneratedSpec.phone("+49 30 1234567").unwrap)) }.map(&.id).should eq([contact.id])
        db.read { |reader| Q.contact_ids(reader, customer_id: contact.customer_id, filter: Q::ContactIds::Filter.new(phone: GeneratedSpec.phone("+49 30 0").unwrap)) }.should be_empty

        changed = contact.copy_with(phone: GeneratedSpec.phone("+49 30 999"))
        db.write { |writer| Ledger::Contacts::Table.update(writer, changed) }
        GeneratedSpec.by_phone(db, "+49 30 1234567").should be_nil
        GeneratedSpec.by_phone(db, "+49 30 999").try(&.id).should eq(contact.id)
      end
    end
  end

  it "keeps values unique through a unique index on it, as a violation at the encrypted column's field" do
    GeneratedSpec.with_ring do
      GeneratedSpec.seeded do |db|
        first = db.write { |writer| GeneratedSpec.contact(writer) }
        db.write { |writer| GeneratedSpec.contact(writer, customer: 2) }
        second = db.write { |writer| GeneratedSpec.contact(writer, number: "+49 30 2") }
        taken = db.write { |writer| Ledger::Contacts::Table.insert(writer, customer_id: first.customer_id, phone: GeneratedSpec.phone("+49 30 1234567")) }
        taken.should be_a(Ledger::Contacts::PhoneTaken)
        Ledger::Contacts::PhoneTaken::FIELD.should eq("phone")
        db.write { |writer| Ledger::Contacts::Table.update(writer, second.copy_with(phone: first.phone)) }.should be_a(Ledger::Contacts::PhoneTaken)
        db.write { |writer| Q.set_contact_phone(writer, phone: first.phone, phone_index: first.phone.unwrap, id: second.id) }.should be_a(Ledger::Contacts::PhoneTaken)
      end
    end
  end

  it "takes the plain value in hand-written writes and hashes it" do
    GeneratedSpec.with_ring do
      GeneratedSpec.seeded do |db|
        contact = db.write { |writer| GeneratedSpec.contact(writer) }
        phone = GeneratedSpec.phone("+49 30 5")
        db.write { |writer| Q.set_contact_phone(writer, phone: phone, phone_index: phone.unwrap, id: contact.id) }.should be_nil
        GeneratedSpec.by_phone(db, "+49 30 5").try(&.phone.unwrap.value).should eq("+49 30 5")
      end
    end
  end

  it "finds rows hashed under an older key and hashes again under the signing key on update" do
    old = Punch::KeyRing::Key.generate(1)
    GeneratedSpec.with_ring(Punch::KeyRing.new([old])) do
      GeneratedSpec.seeded do |db|
        contact = db.write { |writer| GeneratedSpec.contact(writer) }
        GeneratedSpec.with_ring(Punch::KeyRing.new([Punch::KeyRing::Key.generate(2), old])) do
          lookup = Punch::Stored.blind_lookup(GeneratedSpec.phone("+49 30 1234567").unwrap, "contacts", "phone_index").values.as(Array(Bytes)).map(&.hexstring)
          lookup.size.should eq(2)
          lookup[1].should eq((GeneratedSpec.raw(db, "phone_index", contact.id) || fail "no index").hexstring)
          found = GeneratedSpec.by_phone(db, "+49 30 1234567") || fail "not found under the old key"
          found.id.should eq(contact.id)
          newer = db.write { |writer| GeneratedSpec.contact(writer, number: "+49 30 7", customer: 2) }
          phones = ["+49 30 1234567", "+49 30 7", "+49 30 8"].map { |number| GeneratedSpec.phone(number).unwrap }
          db.read { |reader| GeneratedSpec::Q.contacts_by_phones(reader, phones: phones) }.as(Array).map(&.id).should eq([contact.id, newer.id])
          # Until rows are hashed again, the unique index sees the same
          # value under two keys as two values (docs/queries.md).
          db.write { |writer| Ledger::Contacts::Table.insert(writer, customer_id: contact.customer_id, phone: GeneratedSpec.phone("+49 30 1234567")) }.should be_a(Ledger::Contacts::Record)
          db.write { |writer| Ledger::Contacts::Table.update(writer, found) }.should be_a(Ledger::Contacts::PhoneTaken)
        end
      end
    end
  end

  it "is audited: hashes per key, and hashes that are missing or do not match the value" do
    GeneratedSpec.with_ring do
      GeneratedSpec.seeded do |db|
        first = db.write { |writer| GeneratedSpec.contact(writer) }
        db.write { |writer| GeneratedSpec.contact(writer, number: "+49 30 2") }
        Punch::Database::Audit.run(db).clean?.should be_true

        other = Punch::Stored.blind_index(GeneratedSpec.phone("+49 30 3"), "contacts", "phone_index")
        db.write { |writer| writer.exec("UPDATE contacts SET phone_index = ? WHERE id = ?", other, first.id.value) }
        audit = Punch::Database::Audit.run(db)
        audit.clean?.should be_false
        audit.messages.select(&.starts_with?("contacts.")).should eq(["contacts.phone_index: 1 value is not the hash of phone (1 index_stale); rows #{first.id.value}"])
        audit.messages.join.should_not contain("1234567")
      end
    end
  end
end

describe "punch db:audit on encrypted columns" do
  it "lists each encrypted column's values per key" do
    GeneratedSpec.with_ring(Punch::KeyRing.new([Punch::KeyRing::Key.generate(3)])) do
      Punch::Spec.database(file: true, schema: GeneratedSpec::SCHEMA) do |db|
        db.write do |writer|
          writer.exec("INSERT INTO accounts (id, name, created_at) VALUES (1, 'Acme', '2026-10-01T00:00:00.000000000Z')")
          writer.exec("INSERT INTO customers (id, account_id, name, email) VALUES (1, 1, 'Ada', 'ada@example.com')")
          GeneratedSpec.contact(writer)
        end
        stdout, stderr = IO::Memory.new, IO::Memory.new
        Punch::CLI.run(["db:audit", db.path], stdout, stderr, Punch::CLI::APP_COMMANDS).should eq(0)
        stdout.to_s.should contain("\n  contacts.phone: encrypted, 1 under key 3\n")
      end
    end
  end
end

module GeneratedSpec
  def self.email_secret(text : String) : Punch::Secret(Punch::Email)
    Punch::Secret.new(email(text))
  end

  def self.lead(writer : Punch::Writer, text : String) : Ledger::Leads::Record
    Punch.cannot_violate(Ledger::Leads::Table.insert(writer, email_encrypted: email_secret(text)))
  end

  def self.leads_raw(db : Punch::Database) : Array({Int64, String?, Bytes?, Bytes?})
    db.read { |reader| reader.query_all("SELECT id, email, email_encrypted, email_index FROM leads ORDER BY id") { |row| {row.read(Int64), row.read(String?), row.read(Bytes?), row.read(Bytes?)} } }
  end
end

describe "converting a plaintext column" do
  it "reads the plaintext until the encrypted column has its value, and writes both in the first release" do
    GeneratedSpec.with_ring do
      GeneratedSpec.seeded do |db|
        db.write { |writer| writer.exec("INSERT INTO leads (id, email) VALUES (1, 'old@example.org')") }
        old = db.read { |reader| Ledger::Leads::Table.find(reader, GeneratedSpec.id(Ledger::Leads::ID, 1)) } || fail "no lead"
        old.email_encrypted.unwrap.to_s.should eq("old@example.org")

        fresh = db.write { |writer| GeneratedSpec.lead(writer, "new@example.org") }
        _, email, encrypted, index = GeneratedSpec.leads_raw(db).last
        email.should eq("new@example.org")
        encrypted.should be_encrypted_for("leads", "email_encrypted")
        index.should eq(Punch::Stored.blind_index(GeneratedSpec.email("new@example.org"), "leads", "email_index"))
        db.read { |reader| GeneratedSpec::Q.lead_by_email(reader, email: GeneratedSpec.email("new@example.org")) }.try(&.id).should eq(fresh.id)
        # Old rows are found by their hash once converted, by the plaintext until then.
        db.read { |reader| GeneratedSpec::Q.lead_by_email(reader, email: GeneratedSpec.email("old@example.org")) }.should be_nil
        db.read { |reader| GeneratedSpec::Q.old_lead_by_email(reader, email: GeneratedSpec.email("old@example.org")) }.try(&.id).should eq(old.id)

        audit = Punch::Database::Audit.run(db)
        audit.conversion_lines.should eq(["leads.email_encrypted: converting from email, 1 only in plaintext, 2 plaintext copies left"])
      end
    end
  end

  it "converts old rows in batches, finds them by their blind index, and keeps the plaintext until the second release" do
    GeneratedSpec.with_ring do
      GeneratedSpec.seeded do |db|
        db.write { |writer| writer.exec("INSERT INTO leads (id, email) VALUES (1, 'a@example.org'), (2, 'b@example.org'), (3, 'c@example.org')") }
        run = Punch::Database::Encryption.run(db, batch: 2)
        run.clean?.should be_true
        run.rows["leads"].should eq(3)
        run.written["leads"].should eq(3)
        run.messages.should eq(["leads.email_encrypted: 3 converted", "leads.email_index: 3 hashed again"])
        GeneratedSpec.leads_raw(db).map(&.[1]).should eq(["a@example.org", "b@example.org", "c@example.org"])
        db.read { |reader| GeneratedSpec::Q.lead_by_email(reader, email: GeneratedSpec.email("b@example.org")) }.try(&.id.value).should eq(2)
        Punch::Database::Audit.run(db).conversion_lines.first.should eq("leads.email_encrypted: converting from email, 0 only in plaintext, 3 plaintext copies left")

        Punch::Database::Encryption.run(db).written.should be_empty
      end
    end
  end

  it "converts every night in steps, a batch per save, resuming where a deploy stopped it" do
    GeneratedSpec.with_ring do
      GeneratedSpec.seeded do |db|
        Punch::Migrations::Schema.load(db, Punch::Job::Steps::Progress.sql, "steps")
        db.write { |writer| writer.exec("INSERT INTO leads (id, email) VALUES (1, 'a@example.org'), (2, 'b@example.org'), (3, 'c@example.org')") }
        queue = Punch::Spec.queue
        id = queue.enqueue(Punch::Database::Encryption::Run.new) || fail "not enqueued"
        Punch::Database::Encryption::Run.batch_size = 2
        outcomes = [] of Punch::Job::Queue::Outcome
        begin
          while claimed = queue.claim("spec", 1, {"Punch::Database::Encryption::Run" => 1}).first?
            outcomes << Punch::Job::Queue.perform(claimed, queue, db, "spec", Punch::Trace::Tracer.off, interrupt_every: 1)
          end
        ensure
          Punch::Database::Encryption::Run.batch_size = Punch::Database::Encryption::BATCH
        end
        outcomes.last.should eq(Punch::Job::Queue::Outcome::Done)
        outcomes.count(Punch::Job::Queue::Outcome::Paused).should be >= 2
        GeneratedSpec.leads_raw(db).each { |row| row[2].should be_encrypted_for("leads", "email_encrypted") }
        Punch::Database::Encryption.run(db).written.should be_empty
        key = queue.find(id).try(&.unique_key) || fail "no key"
        db.read { |reader| Punch::Job::Steps::Progress.load(reader, key) }.try(&.finished?).should be_true
      end
    end
  end

  it "clears the plaintext in the second release, and generated code leaves it out" do
    GeneratedSpec.with_ring do
      GeneratedSpec.seeded do |db|
        db.write { |writer| writer.exec("INSERT INTO prospects (id, name, email) VALUES (1, 'Ada', 'ada@example.org'), (2, 'Bob', NULL)") }
        db.read { |reader| GeneratedSpec::Q.prospect_names(reader) }.map(&.email_encrypted).should eq([nil, nil])
        Ledger::Prospects::Table::FIND.should_not contain("email,")

        run = Punch::Database::Encryption.run(db)
        run.messages.should eq(["prospects.email: 1 plaintext cleared", "prospects.email_encrypted: 1 converted"])
        db.read { |reader| reader.query_all("SELECT email FROM prospects ORDER BY id") { |row| row.read(String?) } }.should eq([nil, nil])
        db.read { |reader| GeneratedSpec::Q.prospect_names(reader) }.map(&.email_encrypted.try(&.unwrap.to_s)).should eq(["ada@example.org", nil])
        Punch::Database::Audit.run(db).conversion_lines.last.should eq("prospects.email_encrypted: converting from email, 0 only in plaintext, 0 plaintext copies left")
      end
    end
  end

  it "keeps the plaintext where the ciphertext does not hold it, and reports the row" do
    GeneratedSpec.with_ring do
      GeneratedSpec.seeded do |db|
        stale = Punch::Stored.encrypt(Punch::Secret.new(GeneratedSpec.email("old@example.org")), "prospects", "email_encrypted")
        foreign = Punch::KeyRing.new([Punch::KeyRing::Key.generate(9)]).encryptor("column:prospects.email_encrypted").encrypt("x".to_slice)
        db.write do |writer|
          writer.exec("INSERT INTO prospects (id, name, email, email_encrypted) VALUES (1, 'Ada', 'new@example.org', ?)", stale)
          writer.exec("INSERT INTO prospects (id, name, email, email_encrypted) VALUES (2, 'Bob', 'bob@example.org', ?)", foreign)
        end
        run = Punch::Database::Encryption.run(db)
        run.clean?.should be_false
        run.messages.should eq(["prospects.email_encrypted: 2 left as they are (1 plaintext_differs, 1 not_decrypting); rows 1, 2"])
        db.read { |reader| reader.query_all("SELECT email FROM prospects ORDER BY id") { |row| row.read(String?) } }.should eq(["new@example.org", "bob@example.org"])
      end
    end
  end

  it "reports plaintext that does not parse, and leaves it" do
    GeneratedSpec.with_ring do
      GeneratedSpec.seeded do |db|
        db.write { |writer| writer.exec("INSERT INTO leads (id, email) VALUES (7, 'not an address')") }
        run = Punch::Database::Encryption.run(db)
        run.clean?.should be_false
        run.messages.should eq(["leads.email_encrypted: 1 left as they are (1 invalid_email); rows 7"])
        GeneratedSpec.leads_raw(db).first[2].should be_nil
      end
    end
  end
end

describe "re-encrypting after a key rotation" do
  it "encrypts and hashes again under the signing key what an older key wrote, so the older key can retire" do
    old = Punch::KeyRing::Key.generate(1)
    GeneratedSpec.with_ring(Punch::KeyRing.new([old])) do
      GeneratedSpec.seeded do |db|
        contact = db.write { |writer| GeneratedSpec.contact(writer, note: Punch::Secret.new("a note")) }
        GeneratedSpec.with_ring(Punch::KeyRing.new([Punch::KeyRing::Key.generate(2), old])) do
          run = Punch::Database::Encryption.run(db)
          run.messages.should eq(["contacts.note: 1 encrypted again", "contacts.phone: 1 encrypted again", "contacts.phone_index: 1 hashed again"])
          Punch::Database::Audit.run(db).key_lines.select(&.includes?("under key")).should eq([
            "contacts.note: encrypted, 1 under key 2",
            "contacts.phone: encrypted, 1 under key 2",
            "contacts.phone_index: blind index, 1 under key 2",
          ])
          Punch::Database::Encryption.run(db).written.should be_empty
          # Key 1 retired: everything still opens.
          retired = Punch::KeyRing.new([Punch::KeyRing.current.keys.first])
          GeneratedSpec.with_ring(retired) do
            found = db.read { |reader| Ledger::Contacts::Table.find(reader, contact.id) } || fail "no contact"
            found.note.try(&.unwrap).should eq("a note")
            GeneratedSpec.by_phone(db, "+49 30 1234567").try(&.id).should eq(contact.id)
          end
        end
      end
    end
  end

  it "leaves values that do not decrypt and rows whose new hash another row has, and reports them" do
    old = Punch::KeyRing::Key.generate(1)
    GeneratedSpec.with_ring(Punch::KeyRing.new([old])) do
      GeneratedSpec.seeded do |db|
        first = db.write { |writer| GeneratedSpec.lead(writer, "same@example.org") }
        GeneratedSpec.with_ring(Punch::KeyRing.new([Punch::KeyRing::Key.generate(2), old])) do
          # Under two keys the same value is two hashes, so the unique index lets it in.
          second = db.write { |writer| GeneratedSpec.lead(writer, "same@example.org") }
          broken = db.write { |writer| GeneratedSpec.contact(writer) }
          db.write { |writer| writer.exec("UPDATE contacts SET note = phone WHERE id = ?", broken.id.value) }
          db.write { |writer| writer.exec("UPDATE contacts SET note = ? WHERE id = ?", Punch::KeyRing.new([Punch::KeyRing::Key.generate(9)]).encryptor("column:contacts.note").encrypt("x".to_slice), broken.id.value) }

          run = Punch::Database::Encryption.run(db)
          run.clean?.should be_false
          run.messages.should contain("contacts.note: 1 left as they are (1 not_decrypting); rows #{broken.id.value}")
          # The row whose write failed counts as left, not as done.
          run.messages.should contain("leads.email_index: 1 left as they are (1 taken); rows #{first.id.value}")
          run.messages.none?(&.starts_with?("leads.email_encrypted")).should be_true
          second.id.should_not eq(first.id)
        end
      end
    end
  end
end

describe "punch db:encrypt" do
  it "brings the database to the signing key and says what it did" do
    GeneratedSpec.with_ring(Punch::KeyRing.new([Punch::KeyRing::Key.generate(3)])) do
      Punch::Spec.database(file: true, schema: GeneratedSpec::SCHEMA) do |db|
        db.write { |writer| writer.exec("INSERT INTO leads (id, email) VALUES (1, 'a@example.org')") }
        stdout, stderr = IO::Memory.new, IO::Memory.new
        Punch::CLI.run(["db:encrypt", db.path], stdout, stderr, Punch::CLI::APP_COMMANDS).should eq(0)
        stdout.to_s.should eq("#{db.path}: 1 rows read, 1 written, under key 3.\n  leads.email_encrypted: 1 converted\n  leads.email_index: 1 hashed again\n")
      end
    end
  end
end

describe "rules raised by triggers" do
  it "returns the declared value from the writes that fire the trigger, and leaves the row" do
    GeneratedSpec.seeded do |db|
      db.write do |writer|
        acme = Ledger::Accounts::Table.find(writer, GeneratedSpec::ACME) || fail "no account"
        empty = Ledger::Accounts::Table.find(writer, GeneratedSpec::EMPTY) || fail "no account"
        locked = Ledger::Accounts::Table.update(writer, acme.copy_with(plan: "free"))
        locked.should be_a(Ledger::Accounts::PlanLocked)
        locked.as(Ledger::Accounts::PlanLocked).code.should eq("plan_locked")
        locked.as(Ledger::Accounts::PlanLocked).constraint.should eq("accounts: trigger accounts_plan_locked")
        Ledger::Accounts::Table.update(writer, empty.copy_with(plan: "pro")).should be_a(Ledger::Accounts::Record)
        Ledger::Accounts::Table.find(writer, acme.id).try(&.plan).should eq("pro")
        expect_raises(Punch::Database::ConstraintError, /was violated by a write that cannot violate it/) { Punch.cannot_violate(locked) }

        blank = Ledger::Accounts::Table.insert(writer, name: "", created_at: GeneratedSpec::NOW)
        blank.should be_a(Ledger::Accounts::NameBlank)
        rejection = blank.as(Ledger::Accounts::NameBlank).rejection
        rejection.errors.map { |error| {error.path.to_a, error.code} }.should eq([{["name"], "name_blank"}])
      end
    end
  end
end
