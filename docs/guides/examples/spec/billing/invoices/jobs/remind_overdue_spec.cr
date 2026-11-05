require "../../../spec_helper"

describe Billing::Invoices::RemindOverdue do
  it "mails one reminder, also when it runs twice" do
    clock = Punch::Spec.clock
    invoice = BillingSpec.invoice(due_at: clock.now - 3.days)
    2.times { Punch::Job::Queue.enqueue(Billing::Invoices::RemindOverdue.new(invoice.id, :first)) }
    performed = Punch::Spec.perform_jobs
    performed.map(&.outcome).should eq([Punch::Job::Queue::Outcome::Done, Punch::Job::Queue::Outcome::Discarded])
    performed.last.error.should eq("invoice #{invoice.id} was reminded already")
    Punch::Spec.mails.map(&.subject).should eq(["Invoice #{invoice.number} is overdue"])
  end

  it "reads a payload of version 1 as a first reminder" do
    remind = Punch::Spec.read_payload(Billing::Invoices::RemindOverdue, 1, %({"invoice_id": 7}))
    {remind.invoice_id.value, remind.reminder}.should eq({7, Billing::Invoices::Reminder::First})
  end

  it "records the invoice on the run's wide event" do
    ops = Punch::Spec.ops
    invoice = BillingSpec.invoice(due_at: Punch::Spec.clock.now - 3.days)
    Punch::Job::Queue.enqueue(Billing::Invoices::RemindOverdue.new(invoice.id, :final))
    Punch::Spec.perform_jobs
    run = ops.records(kind: "job").find!(&.name.ends_with?("Billing::Invoices::RemindOverdue"))
    fields = JSON.parse(run.fields)
    {fields["invoice.id"], fields["invoice.reminder"]}.should eq({invoice.id.value, "final"})
  end

  it "reminds nobody of a paid invoice" do
    clock = Punch::Spec.clock
    invoice = BillingSpec.invoice(due_at: clock.now - 3.days, paid_at: clock.now)
    Punch::Job::Queue.enqueue(Billing::Invoices::RemindOverdue.new(invoice.id, :first))
    Punch::Spec.perform_jobs.map(&.outcome).should eq([Punch::Job::Queue::Outcome::Discarded])
    Punch::Spec.mails.should be_empty
  end
end
