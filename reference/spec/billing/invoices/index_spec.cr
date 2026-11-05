require "../../spec_helper"

private LINES = [
  {description: "Consulting", quantity: 3, unit_price: 12_500},
  {description: "Travel", quantity: 1, unit_price: 4_990},
]

private def customer_id(client, email = "ada@example.org") : String
  client.post(Billing::Customers::Create.path, json: {name: "Ada Lovelace", email: email}).json["customer"]["id"].as_s
end

private def invoice_id(raw) : Billing::Invoices::ID
  InvoicingSpec.parse(Billing::Invoices::ID, raw.as_s)
end

private def draft(client, customer : String, lines = LINES) : Billing::Invoices::ID
  response = client.post(Billing::Invoices::Create.path, json: {customer_id: customer, currency: "EUR", lines: lines})
  response.status.should eq(HTTP::Status::CREATED)
  invoice_id(response.json["invoice"]["id"])
end

describe "invoices API" do
  it "lists invoices with their customer and total, optionally of one customer" do
    client = AccountsSpec.client
    ada, grace = customer_id(client), customer_id(client, "grace@example.org")
    draft(client, ada)
    sent = draft(client, grace, [LINES[1]])
    draft(client, ada, [] of NamedTuple(description: String, quantity: Int32, unit_price: Int32))
    client.post(Billing::Invoices::Send.path(invoice_id: sent), headers: Punch::Spec.idempotency_key)

    all = client.get(Billing::Invoices::Index.path).json["invoices"].as_a
    all.map { |invoice| {invoice["status"].as_s, invoice["total"].as_i} }.should eq([{"draft", 42_490}, {"sent", 4_990}, {"draft", 0}])
    all[1]["number"].should eq("INV-000001")

    adas = client.get(Billing::Invoices::Index.path, query: {filter: {customer_id: ada}, limit: 1}).json
    adas["invoices"].as_a.map(&.["customer_id"].as_s).should eq([ada])
    rest = client.get(Billing::Invoices::Index.path, query: {filter: {customer_id: ada}, after: adas["next_after"].as_s}).json
    rest["invoices"].as_a.map(&.["total"].as_i).should eq([0])

    client.get(Billing::Invoices::Index.path, query: {filter: {status: "sent"}}).json["invoices"].as_a.map(&.["number"]).should eq(["INV-000001"])
    client.get(Billing::Invoices::Index.path, query: {filter: {status: "draft", customer_id: ada}}).json["invoices"].as_a.size.should eq(2)
    void = client.get(Billing::Invoices::Index.path, query: {filter: {status: "void"}})
    {void.status, void.json["errors"][0]["code"]}.should eq({HTTP::Status::UNPROCESSABLE_ENTITY, "invalid_choice"})
  end

  it "searches by the start of the number or part of the customer's name, typed text matching itself" do
    client = AccountsSpec.client
    ada = customer_id(client)
    grace = client.post(Billing::Customers::Create.path, json: {name: "Grace 100% Hopper", email: "grace@example.org"}).json["customer"]["id"].as_s
    sent = draft(client, ada)
    client.post(Billing::Invoices::Send.path(invoice_id: sent), headers: Punch::Spec.idempotency_key)
    graces = draft(client, grace)
    search = ->(q : String) do
      client.get(Billing::Invoices::Index.path, query: {filter: {q: q}}).json["invoices"].as_a.map(&.["id"].as_s)
    end

    search.call("INV-0000").should eq([sent.to_s])
    search.call("000001").should be_empty # a number is found by its start
    search.call("love").should eq([sent.to_s])
    search.call("GRACE").should eq([graces.to_s])
    search.call("100%").should eq([graces.to_s])
    search.call("%").should eq([graces.to_s]) # only the name with a percent sign
    search.call("_").should be_empty
    client.get(Billing::Invoices::Index.path, query: {filter: {q: "o", status: "draft"}}).json["invoices"].as_a.map(&.["id"].as_s).should eq([graces.to_s])

    page = client.visit(Billing::Invoices::IndexPage.href(filter: Billing::Invoices::Queries::Page::Filter.new(q: Punch::LikeText.new("grace"))))
    page.should have_element("input[name='filter[q]'][value=grace]")
    page.should have_element("table.invoices tbody tr", count: 1)
  end

  it "marks overdue invoices in lists by the same rule as the invoice itself" do
    client = AccountsSpec.client
    customer = customer_id(client)
    open, late = draft(client, customer), draft(client, customer)
    draft(client, customer)
    client.post(Billing::Invoices::Send.path(invoice_id: open), headers: Punch::Spec.idempotency_key)
    client.post(Billing::Invoices::Send.path(invoice_id: late), headers: Punch::Spec.idempotency_key)
    # No injectable clock yet: move one due date into the past.
    Punch::Spec.db.write { |db| db.exec("UPDATE invoices SET due_at = ? WHERE id = ?", Punch::Stored.dump(Time.utc(2026, 1, 1)), late.value) }

    client.get(Billing::Invoices::Index.path).json["invoices"].as_a.map(&.["overdue"].as_bool).should eq([false, true, false])
    client.get(Billing::Invoices::Show.path(invoice_id: late)).json["overdue"].should be_true
  end
end
