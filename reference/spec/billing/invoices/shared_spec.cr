require "../../spec_helper"

private def sent_invoice(client) : String
  customer = client.post(Billing::Customers::Create.path, json: {name: "Ada Lovelace", email: "ada-#{Random.new.hex(4)}@example.org"}).json["customer"]["id"].as_s
  id = client.post(Billing::Invoices::Create.path, json: {customer_id: customer, currency: "EUR", lines: [{description: "Work", quantity: 1, unit_price: 1_000}]}).json["invoice"]["id"].as_s
  client.post(Billing::Invoices::Send.path(invoice_id: InvoicingSpec.parse(Billing::Invoices::ID, id)), headers: Punch::Spec.idempotency_key)
  id
end

describe "sharing an invoice" do
  it "answers 404 for a forged, damaged, expired, or misused token" do
    client = AccountsSpec.client
    id = sent_invoice(client)
    signer = Punch::KeyRing.current
    good = Billing::Invoices::Sharing::PURPOSE
    {
      Punch::KeyRing.current.signer(good).sign_text(id.to_s, expires_at: Time.utc - 1.second),
      Punch::KeyRing.current.signer("unsubscribe").sign_text(id.to_s),
      Punch::KeyRing.new([Punch::KeyRing::Key.generate(1)]).signer(good).sign_text(id.to_s),
      signer.signer(good).sign_text(id.to_s).sub(/.$/) { |char| char == "A" ? "B" : "A" },
      "not-a-token",
    }.each do |token|
      client.get(Billing::Invoices::Shared.path(token: token)).status.should eq(HTTP::Status::NOT_FOUND)
    end
  end
end
