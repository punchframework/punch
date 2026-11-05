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
  it "creates a draft with its lines and total" do
    client = AccountsSpec.client
    id = draft(client, customer_id(client))
    invoice = client.get(Billing::Invoices::Show.path(invoice_id: id)).json
    invoice["status"].should eq("draft")
    invoice["issuer"].should eq(JSON.parse(%({"name": "Example Consulting GmbH", "vat_id": "DE123456789"})))
    invoice["lines"].as_a.map(&.["total"].as_i).should eq([37_500, 4_990])
    invoice["total"].should eq(42_490)
    invoice["number"]?.should be_nil
    invoice["overdue"].should be_false
  end

  it "refuses an unknown customer and collects every input error with its path" do
    client = AccountsSpec.client
    unknown = client.post(Billing::Invoices::Create.path, json: {customer_id: InvoicingSpec.parse(Billing::Customers::ID, 99), currency: "EUR"})
    {unknown.status, unknown.json["code"]}.should eq({HTTP::Status::UNPROCESSABLE_ENTITY, "unknown_customer"})

    response = client.post(Billing::Invoices::Create.path, json: {
      customer_id: InvoicingSpec.parse(Billing::Customers::ID, 1), currency: "eur",
      lines: [{description: "Fine", quantity: 1, unit_price: 100}, {description: " ", quantity: 0, unit_price: 1}],
    })
    response.json["errors"].as_a.map { |error| {error["path"].as_a.map(&.raw), error["code"].as_s} }.should eq([
      {["currency"], "invalid_currency"},
      {["lines", 1, "description"], "blank"},
      {["lines", 1, "quantity"], "out_of_range"},
    ])
  end

  it "bounds unit prices and line counts, so totals stay exact" do
    client = AccountsSpec.client
    customer = customer_id(client)
    price = client.post(Billing::Invoices::Create.path, json: {customer_id: customer, currency: "EUR", lines: [{description: "Big", quantity: 1, unit_price: 1_000_000_001}]})
    {price.json["errors"][0]["path"].as_a.map(&.raw), price.json["errors"][0]["code"]}.should eq({["lines", 0, "unit_price"], "out_of_range"})
    many = client.post(Billing::Invoices::Create.path, json: {customer_id: customer, currency: "EUR", lines: Array.new(101, LINES[0])})
    {many.json["errors"][0]["path"].as_a.map(&.raw), many.json["errors"][0]["code"]}.should eq({["lines"], "too_many"})
  end
end
