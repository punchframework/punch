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

private def customer(client, name = "Ada Lovelace", email = "ada@example.org") : Billing::Customers::ID
  raw = client.post(Billing::Customers::Create.path, json: {name: name, email: email}).json["customer"]["id"].as_s
  InvoicingSpec.parse(Billing::Customers::ID, raw)
end

private def draft(client, customer : Billing::Customers::ID, lines = [{description: "Consulting", quantity: 3, unit_price: 12_500}]) : Billing::Invoices::ID
  raw = client.post(Billing::Invoices::Create.path, json: {customer_id: customer, currency: "EUR", lines: lines}).json["invoice"]["id"].as_s
  InvoicingSpec.parse(Billing::Invoices::ID, raw)
end

describe "invoices API" do
  it "deletes a draft but not a sent invoice" do
    client = AccountsSpec.client
    customer = customer_id(client)
    id = draft(client, customer)
    client.delete(Billing::Invoices::Destroy.path(invoice_id: id)).status.should eq(HTTP::Status::NO_CONTENT)
    client.get(Billing::Invoices::Show.path(invoice_id: id)).status.should eq(HTTP::Status::NOT_FOUND)

    sent = draft(client, customer)
    client.post(Billing::Invoices::Send.path(invoice_id: sent), headers: Punch::Spec.idempotency_key)
    client.delete(Billing::Invoices::Destroy.path(invoice_id: sent)).status.should eq(HTTP::Status::CONFLICT)
  end
end

describe "invoice forms" do
  it "deletes a draft and leads to the list" do
    client = AccountsSpec.client
    id = draft(client, customer(client))
    client.submit(Billing::Invoices::Destroy.action(invoice_id: id)).should redirect_to(Billing::Invoices::IndexPage.href)
    client.visit(Billing::Invoices::ShowPage.href(invoice_id: id)).status.should eq(HTTP::Status::NOT_FOUND)
  end
end
