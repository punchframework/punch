require "../../spec_helper"

private def customer_id(client) : Billing::Customers::ID
  raw = client.post(Billing::Customers::Create.path, json: {name: "Ada Lovelace", email: "ada@example.org"}).json["customer"]["id"]
  InvoicingSpec.parse(Billing::Customers::ID, raw.as_s)
end

# Sends an invoice of *amount* in *currency* and returns its ID.
private def send_invoice(client, customer : Billing::Customers::ID, amount : Int32, currency = "EUR") : Int64
  created = client.post(Billing::Invoices::Create.path,
    json: {customer_id: customer, currency: currency, lines: [{description: "Work", quantity: 2, unit_price: amount // 2}]})
  id = InvoicingSpec.parse(Billing::Invoices::ID, created.json["invoice"]["id"].as_s)
  client.post(Billing::Invoices::Send.path(invoice_id: id), headers: Punch::Spec.idempotency_key).status.should eq(HTTP::Status::OK)
  id.value
end

private def balances(response) : Array({String, Int64, Int64, Int64})
  response.json["balances"].as_a.map { |balance| {balance["currency"].as_s, balance["invoices"].as_i64, balance["overdue"].as_i64, balance["total"].as_i64} }
end

describe "customer statement" do
  it "forgets the statement when an invoice to the customer is sent" do
    client = AccountsSpec.client
    customer = customer_id(client)
    send_invoice(client, customer, 1_000)
    path = Billing::Customers::Statement.path(customer_id: customer)
    first = client.get(path)
    etag = first.headers["ETag"]

    -> { send_invoice(client, customer, 2_000) }.should publish(Billing::InvoiceSent, customer_id: customer, times: 1)
    Billing::Customers::STATEMENTS.cached?(customer).should be_false
    now = client.get(path, headers: HTTP::Headers{"If-None-Match" => etag})
    now.status.should eq(HTTP::Status::OK)
    balances(now).should eq([{"EUR", 2, 0, 3_000}])
  end
end
