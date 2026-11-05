require "../../spec_helper"

private def sent_invoice(client) : String
  customer = client.post(Billing::Customers::Create.path, json: {name: "Ada Lovelace", email: "ada-#{Random.new.hex(4)}@example.org"}).json["customer"]["id"].as_s
  id = client.post(Billing::Invoices::Create.path, json: {customer_id: customer, currency: "EUR", lines: [{description: "Work", quantity: 1, unit_price: 1_000}]}).json["invoice"]["id"].as_s
  client.post(Billing::Invoices::Send.path(invoice_id: InvoicingSpec.parse(Billing::Invoices::ID, id)), headers: Punch::Spec.idempotency_key)
  id
end

describe "sharing an invoice" do
  it "links a sent invoice for 30 days, without signing in" do
    client = AccountsSpec.client
    id = InvoicingSpec.parse(Billing::Invoices::ID, sent_invoice(client))
    link = client.get(Billing::Invoices::Link.path(invoice_id: id))
    link.status.should eq(HTTP::Status::OK)
    (Time.parse_rfc3339(link.json["expires_at"].as_s) - Time.utc).should be_close(30.days, 5.seconds)
    shown = Punch::Spec.client.get(link.json["path"].as_s)
    shown.status.should eq(HTTP::Status::OK)
    shown.json["number"].should eq(client.get(Billing::Invoices::Show.path(invoice_id: id)).json["number"])
  end

  it "does not link a draft or an unknown invoice" do
    client = AccountsSpec.client
    customer = client.post(Billing::Customers::Create.path, json: {name: "Bo", email: "bo@example.org"}).json["customer"]["id"].as_s
    draft = client.post(Billing::Invoices::Create.path, json: {customer_id: customer, currency: "EUR"}).json["invoice"]["id"].as_s
    client.get(Billing::Invoices::Link.path(invoice_id: InvoicingSpec.parse(Billing::Invoices::ID, draft))).json["code"].should eq("not_sent")
    client.get(Billing::Invoices::Link.path(invoice_id: InvoicingSpec.parse(Billing::Invoices::ID, 999))).status.should eq(HTTP::Status::NOT_FOUND)
  end
end
