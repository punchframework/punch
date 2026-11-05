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
  it "shows a shared invoice without signing in, and nothing for a bad link" do
    client = AccountsSpec.client
    id = invoice(client, customer(client), send: true)
    path = client.get(Billing::Invoices::Link.path(invoice_id: id)).json["path"].as_s
    shared = Punch::Spec.client.visit(path)
    shared.status.should eq(HTTP::Status::OK)
    shared.should have_element("h1", text: "Invoice INV-000001")
    shared.should have_element("main p strong", text: "Example Consulting GmbH")
    shared.should have_element("table.lines tfoot td", text: "€375.00")
    shared.should_not have_element("nav")
    Punch::Spec.client.visit(Billing::Invoices::SharedPage.href(token: "forged")).status.should eq(HTTP::Status::NOT_FOUND)
  end

  it "slows down guessing shared links: 60 a minute per address" do
    clock = Punch::Spec.clock
    forged = Billing::Invoices::SharedPage.href(token: "forged")
    client = Punch::Spec.client
    59.times { client.visit(forged) }
    client.visit(forged).headers["RateLimit"].should eq(%("billing.invoices.shared_page.ip";r=0;t=60))
    refused = client.visit(forged)
    refused.should be_rate_limited("billing.invoices.shared_page.ip")
    refused.should have_element("code", text: "rate_limited")
    clock.advance(1.second)
    client.visit(forged).status.should eq(HTTP::Status::NOT_FOUND)
  end
end
