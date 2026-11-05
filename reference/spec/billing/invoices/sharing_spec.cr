require "../../spec_helper"

private def sent_invoice(client) : String
  customer = client.post(Billing::Customers::Create.path, json: {name: "Ada Lovelace", email: "ada-#{Random.new.hex(4)}@example.org"}).json["customer"]["id"].as_s
  id = client.post(Billing::Invoices::Create.path, json: {customer_id: customer, currency: "EUR", lines: [{description: "Work", quantity: 1, unit_price: 1_000}]}).json["invoice"]["id"].as_s
  client.post(Billing::Invoices::Send.path(invoice_id: InvoicingSpec.parse(Billing::Invoices::ID, id)), headers: Punch::Spec.idempotency_key)
  id
end

private def with_ring(ring : Punch::KeyRing, &) : Nil
  previous = Punch::KeyRing.current
  Punch::KeyRing.current = ring
  begin
    yield
  ensure
    Punch::KeyRing.current = previous
  end
end

describe "sharing an invoice" do
  it "keeps links working through a key rotation until the old key retires" do
    client = AccountsSpec.client
    id = InvoicingSpec.parse(Billing::Invoices::ID, sent_invoice(client))
    path = client.get(Billing::Invoices::Link.path(invoice_id: id)).json["path"].as_s
    old = Punch::KeyRing.current.keys.first
    fresh = Punch::KeyRing::Key.generate(2)
    with_ring(Punch::KeyRing.new([fresh.with_pending(true), old])) do
      client.get(path).status.should eq(HTTP::Status::OK)
    end
    promoted = Punch::KeyRing.new([fresh, old])
    with_ring(promoted) do
      response = client.get(path)
      response.status.should eq(HTTP::Status::OK)
      response.trace.root["punch.key_ring.old_key_id"].should eq(1)
      # The link's signature, and the invoice's billed_to, encrypted under the old key.
      promoted.uses[1].should eq(2)
    end
    with_ring(Punch::KeyRing.new([fresh])) do
      client.get(path).status.should eq(HTTP::Status::NOT_FOUND)
    end
    client.get(path).status.should eq(HTTP::Status::OK)
  end
end
