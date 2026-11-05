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
  it "revises a draft but not a sent invoice" do
    client = AccountsSpec.client
    id = draft(client, customer_id(client))
    path = Billing::Invoices::Update.path(invoice_id: id)
    revised = client.patch(path, json: {currency: "CHF", lines: [LINES[1]]})
    {revised.json["currency"], revised.json["total"]}.should eq({"CHF", 4_990})
    client.patch(path, json: {currency: "EUR"}).json["lines"].as_a.size.should eq(1)

    client.post(Billing::Invoices::Send.path(invoice_id: id), headers: Punch::Spec.idempotency_key)
    client.patch(path, json: {currency: "USD"}).json["code"].should eq("already_sent")
  end
end
