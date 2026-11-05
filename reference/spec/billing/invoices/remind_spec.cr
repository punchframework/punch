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
  it "reminds once when a sent invoice comes due, through the outbox" do
    clock = Punch::Spec.clock
    client = AccountsSpec.client
    invoice_id = draft(client, customer_id(client))
    send = -> { client.post(Billing::Invoices::Send.path(invoice_id: invoice_id), headers: Punch::Spec.idempotency_key).status.should eq(HTTP::Status::OK) }
    send.should enqueue(Billing::Invoices::Remind, invoice_id: invoice_id, times: 1)
    # Only the mail runs now; the reminder is not due for 14 days.
    Punch::Spec.perform_jobs.map(&.type).should eq(["Billing::Invoices::MailInvoice(Billing::InvoiceSent)"])
    clock.advance(Billing::Invoices::PAYMENT_TERM + 1.minute)
    Punch::Spec.perform_jobs.map(&.outcome).should eq([Punch::Job::Queue::Outcome::Done])
    reminded = Punch::Spec.db.read { |db| Billing::Invoices::Queries.reminded(db, invoice_id: invoice_id) }
    (reminded.try(&.created_at) || fail "no reminder").should be_close(clock.now, 1.second)
  end

  it "writes no second reminder when the job runs again" do
    clock = Punch::Spec.clock
    client = AccountsSpec.client
    invoice_id = draft(client, customer_id(client))
    client.post(Billing::Invoices::Send.path(invoice_id: invoice_id), headers: Punch::Spec.idempotency_key).status.should eq(HTTP::Status::OK)
    clock.advance(Billing::Invoices::PAYMENT_TERM + 1.minute)
    Punch::Spec.perform_jobs
    Punch::Job::Queue.enqueue(Billing::Invoices::Remind.new(invoice_id))
    Punch::Spec.perform_jobs.map(&.outcome).should eq([Punch::Job::Queue::Outcome::Done])
    Punch::Spec.db.read { |db| db.query_all("SELECT count(*) FROM invoice_reminders", &.read(Int64)) }.should eq([1])
  end

  it "discards the reminder of an invoice that is gone" do
    Punch::Job::Queue.enqueue(Billing::Invoices::Remind.new(Billing::Invoices::ID.parse(999_i64).as(Billing::Invoices::ID)))
    performed = Punch::Spec.perform_jobs
    performed.map(&.outcome).should eq([Punch::Job::Queue::Outcome::Discarded])
    performed.first.error.should eq("invoice #{Billing::Invoices::ID.parse(999_i64)} was deleted")
  end
end
