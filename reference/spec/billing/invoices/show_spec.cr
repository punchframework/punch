require "../../spec_helper"

private def customer(client, name = "Ada Lovelace") : String
  client.post(Billing::Customers::Create.path, json: {name: name, email: "#{Random.new.hex(4)}@example.org"}).json["customer"]["id"].as_s
end

private def invoice(client, customer : String, lines = [{description: "Consulting", quantity: 3, unit_price: 12_500}], send = false) : Billing::Invoices::ID
  raw = client.post(Billing::Invoices::Create.path, json: {customer_id: customer, currency: "EUR", lines: lines}).json["invoice"]["id"].as_s
  id = InvoicingSpec.parse(Billing::Invoices::ID, raw)
  client.post(Billing::Invoices::Send.path(invoice_id: id), headers: Punch::Spec.idempotency_key) if send
  id
end

describe "invoice pages" do
  it "keeps JSON for programs on the same paths" do
    client = AccountsSpec.client
    id = invoice(client, customer(client))
    json = client.get(Billing::Invoices::Show.path(invoice_id: id))
    json.content_type.should eq("application/json")
    json.headers["Vary"].should eq("Accept")
    client.visit(Billing::Invoices::Show.path(invoice_id: id)).content_type.should eq("text/html")
  end
end
