require "../../spec_helper"

private def overdue_invoices(count : Int32) : Array(Billing::Invoices::ID)
  client = AccountsSpec.client
  customer = client.post(Billing::Customers::Create.path, json: {name: "Ada Lovelace", email: "ada@example.org"}).json["customer"]["id"].as_s
  ids = Array(Billing::Invoices::ID).new(count) do
    raw = client.post(Billing::Invoices::Create.path, json: {customer_id: customer, currency: "EUR", lines: [{description: "Consulting", quantity: 1, unit_price: 9_000}]}).json["invoice"]["id"]
    id = InvoicingSpec.parse(Billing::Invoices::ID, raw.as_s)
    client.post(Billing::Invoices::Send.path(invoice_id: id), headers: Punch::Spec.idempotency_key).status.should eq(HTTP::Status::OK)
    id
  end
  Punch::Spec.perform_jobs # the invoice mails
  # Their reminders were lost, as in a restore that predates them.
  Punch::Spec.queue.list(type: "Billing::Invoices::Remind", limit: 100).each { |job| Punch::Spec.queue.discard_job(job.id) }
  ids
end

private def reminders : Int64
  Punch::Spec.db.read { |db| db.query_one?("SELECT count(*) FROM invoice_reminders", &.read(Int64)) } || 0_i64
end

describe Billing::Invoices::RemindOverdue do
  it "reminds every overdue invoice without a reminder, once, wherever a deploy stops it" do
    clock = Punch::Spec.clock
    overdue_invoices(3)
    clock.advance(Billing::Invoices::PAYMENT_TERM + 1.day)
    id = Punch::Job::Queue.enqueue(Billing::Invoices::RemindOverdue.new) || fail "not enqueued"

    Punch::Spec.perform_jobs(interrupt_every: 1).last.outcome.should eq(Punch::Job::Queue::Outcome::Done)
    reminders.should eq(3)
    Punch::Spec.job_progress(id).try(&.finished?).should be_true

    # A second sweep finds nothing left.
    Punch::Job::Queue.enqueue(Billing::Invoices::RemindOverdue.new)
    Punch::Spec.perform_jobs.map(&.outcome).should eq([Punch::Job::Queue::Outcome::Done])
    reminders.should eq(3)
  end

  it "leaves invoices that are not due yet" do
    clock = Punch::Spec.clock
    overdue_invoices(2)
    clock.advance(1.day)
    Punch::Job::Queue.enqueue(Billing::Invoices::RemindOverdue.new)
    Punch::Spec.perform_jobs
    reminders.should eq(0)
  end
end
