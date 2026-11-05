require "../../spec_helper"

# A sent invoice of 2 × 125.00 EUR to a customer at *email*; its number.
private def sent_invoice(client, email : String) : {Billing::Invoices::ID, String}
  customer = client.post(Billing::Customers::Create.path, json: {name: "Ada Lovelace", email: email}).json["customer"]["id"].as_s
  created = client.post(Billing::Invoices::Create.path,
    json: {customer_id: customer, currency: "EUR", lines: [{description: "Consulting", quantity: 2, unit_price: 12_500}]})
  id = InvoicingSpec.parse(Billing::Invoices::ID, created.json["invoice"]["id"].as_s)
  sent = client.post(Billing::Invoices::Send.path(invoice_id: id), headers: Punch::Spec.idempotency_key)
  sent.status.should eq(HTTP::Status::OK)
  {id, sent.json["number"].as_s}
end

private def payment(number : String, amount = 25_000, currency = "EUR", event = "payment.succeeded") : String
  {event: event, data: {payment_id: "pay_#{Random::Secure.hex(6)}", invoice_number: number, amount: amount, currency: currency, paid_at: "2026-10-12T09:30:00Z"}}.to_json
end

private def deliver(body : String, secret = BillingSpec::WEBHOOK_SECRET, id = "msg_#{Random::Secure.hex(8)}", at = Time.utc)
  Punch::Spec.client.deliver_webhook(Billing::Payments::Provider::Receive.path, body, secret: secret, id: id, at: at)
end

# The last invocation of the payment provider, in its state.
private def last_invocation : Punch::Webhook::Invocation::Any
  Punch::Spec.webhooks("payments").last
end

private def unique_email : String
  "billing-#{Random::Secure.hex(6)}@example.org"
end

describe "the payment webhook" do
  it "stores the delivery, then marks the invoice paid, once" do
    client = AccountsSpec.client
    id, number = sent_invoice(client, unique_email)
    Punch::Spec.perform_jobs # the invoice mail
    body = payment(number)

    -> { deliver(body, id: "msg_once").status.should eq(HTTP::Status::NO_CONTENT) }.should publish(Billing::InvoicePaid, times: 0)
    client.get(Billing::Invoices::Show.path(invoice_id: id)).json["status"].should eq("sent")
    -> { Punch::Spec.perform_jobs.map(&.type).should eq(["Punch::Webhook::Process"]) }.should publish(Billing::InvoicePaid, invoice_id: id, times: 1)
    shown = client.get(Billing::Invoices::Show.path(invoice_id: id)).json
    shown["status"].should eq("paid")
    shown["paid_at"].should eq("2026-10-12T09:30:00Z")
    shown["overdue"].should be_false
    last_invocation.should be_a(Punch::Webhook::Invocation::Processed)

    # The same delivery again: answered, nothing stored or processed.
    deliver(body, id: "msg_once").status.should eq(HTTP::Status::NO_CONTENT)
    Punch::Spec.perform_jobs.should be_empty
    Punch::Spec.webhooks("payments").size.should eq(1)
    # Another payload under the same delivery ID: 409.
    deliver(payment(number, amount: 1), id: "msg_once").status.should eq(HTTP::Status::CONFLICT)
  end

  it "records one payment for a delivery sent twice, and settles the customer's statement" do
    client = AccountsSpec.client
    id, number = sent_invoice(client, unique_email)
    body = payment(number)
    2.times { deliver(body, id: "msg_twice").status.should eq(HTTP::Status::NO_CONTENT) }
    Punch::Spec.perform_jobs
    Punch::Spec.db.read { |db| db.query_all("SELECT count(*) FROM invoice_payments", &.read(Int64)) }.should eq([1])

    customer = client.get(Billing::Invoices::Show.path(invoice_id: id)).json["customer_id"].as_s
    statement = client.get(Billing::Customers::Statement.path(customer_id: InvoicingSpec.parse(Billing::Customers::ID, customer)))
    statement.json["balances"][0]["outstanding"].should eq(0)
    statement.json["balances"][0]["total"].should eq(25_000)
  end

  it "keeps a paid invoice final and its reminder away" do
    clock = Punch::Spec.clock
    client = AccountsSpec.client
    id, number = sent_invoice(client, unique_email)
    deliver(payment(number)).status.should eq(HTTP::Status::NO_CONTENT)
    Punch::Spec.perform_jobs

    client.patch(Billing::Invoices::Update.path(invoice_id: id), json: {currency: "CHF"}).json["code"].should eq("already_sent")
    clock.advance(Billing::Invoices::PAYMENT_TERM + 1.minute)
    reminders = Punch::Spec.perform_jobs.select(&.type.==("Billing::Invoices::Remind"))
    reminders.map(&.error).should eq(["invoice #{id} is paid"])
  end

  it "refuses a delivery without a valid signature, and stores nothing" do
    client = AccountsSpec.client
    id, number = sent_invoice(client, unique_email)
    body = payment(number)
    wrong_secret = "whsec_#{Base64.strict_encode("someone-else-entirely-0123456")}"

    deliver(body, secret: wrong_secret).json["code"].should eq("invalid_signature")
    deliver(body, at: Time.utc - 10.minutes).status.should eq(HTTP::Status::UNAUTHORIZED)
    unsigned = Punch::Spec.client.post(Billing::Payments::Provider::Receive.path, json: JSON.parse(body))
    unsigned.status.should eq(HTTP::Status::UNAUTHORIZED)
    Punch::Spec.webhooks.should be_empty
    client.get(Billing::Invoices::Show.path(invoice_id: id)).json["status"].should eq("sent")
  end

  it "fails a payment of the wrong amount or for an unknown invoice, with the failure event, and pays nothing" do
    client = AccountsSpec.client
    id, number = sent_invoice(client, unique_email)
    Punch::Spec.perform_jobs # the invoice mail

    {payment(number, amount: 20_000), payment(number, currency: "CHF"), payment("INV-999999")}.each do |body|
      deliver(body).status.should eq(HTTP::Status::NO_CONTENT)
      -> { Punch::Spec.perform_jobs }.should publish(Punch::Webhook::ProcessingFailed, provider: "payments", state: "failed", times: 1)
    end
    Punch::Spec.webhooks("payments").map(&.error).should eq([
      "20000 EUR does not settle #{number} (25000 EUR)", "25000 CHF does not settle #{number} (25000 EUR)", "no sent invoice INV-999999",
    ])
    deliver(%({"event": "payment.succeeded", "data": {"invoice_number": "nope"}}))
    -> { Punch::Spec.perform_jobs }.should publish(Punch::Webhook::ProcessingFailed, state: "unprocessable", times: 1)
    client.get(Billing::Invoices::Show.path(invoice_id: id)).json["status"].should eq("sent")
  end

  it "ignores other events" do
    client = AccountsSpec.client
    id, number = sent_invoice(client, unique_email)
    deliver(payment(number, event: "payment.refunded")).status.should eq(HTTP::Status::NO_CONTENT)
    Punch::Spec.perform_jobs
    last_invocation.should be_a(Punch::Webhook::Invocation::Ignored)
    last_invocation.error.should eq("payment.refunded")
    client.get(Billing::Invoices::Show.path(invoice_id: id)).json["status"].should eq("sent")
  end
end
