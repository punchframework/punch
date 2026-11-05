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
  it "adds up sent invoices per currency, leaving drafts out" do
    clock = Punch::Spec.clock(Time.utc - 90.days)
    user = AccountsSpec.user
    client = Punch::Spec.client.sign_in(user.id)
    customer = customer_id(client)
    send_invoice(client, customer, 5_000)
    clock.advance(90.days)
    client = Punch::Spec.client.sign_in(user.id)
    send_invoice(client, customer, 10_000)
    send_invoice(client, customer, 700, "CHF")
    client.post(Billing::Invoices::Create.path, json: {customer_id: customer, currency: "EUR", lines: [{description: "Draft", quantity: 1, unit_price: 99}]})

    response = client.get(Billing::Customers::Statement.path(customer_id: customer))
    response.status.should eq(HTTP::Status::OK)
    balances(response).should eq([{"CHF", 1, 0, 700}, {"EUR", 2, 1, 15_000}])
  end

  it "answers 404 for a customer that does not exist" do
    client = AccountsSpec.client
    client.get(Billing::Customers::Statement.path(customer_id: InvoicingSpec.parse(Billing::Customers::ID, 999))).status.should eq(HTTP::Status::NOT_FOUND)
  end

  it "computes once a minute and answers 304 while the balances are unchanged" do
    clock = Punch::Spec.clock
    client = AccountsSpec.client
    customer = customer_id(client)
    send_invoice(client, customer, 1_000)
    path = Billing::Customers::Statement.path(customer_id: customer)
    first = client.get(path)
    etag = first.headers["ETag"]
    client.get(path, headers: HTTP::Headers{"If-None-Match" => etag}).status.should eq(HTTP::Status::NOT_MODIFIED)

    again = client.get(path)
    balances(again).should eq(balances(first))
    if Punch::Caches.enabled?
      again.json["as_of"].should eq(first.json["as_of"])
      Billing::Customers::STATEMENTS.stats.snapshot.hits.should be > 0
    end

    clock.advance(61.seconds)
    later = client.get(path, headers: HTTP::Headers{"If-None-Match" => etag})
    later.status.should eq(HTTP::Status::NOT_MODIFIED)
  end
end
