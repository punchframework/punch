require "../../../spec_helper"

describe Billing::Invoices::SweepOverdue do
  it "reminds the customers of overdue invoices not reminded this week" do
    clock = Punch::Spec.clock
    now = clock.now
    BillingSpec.invoice(due_at: now - 3.days, email: "late@example.org")
    BillingSpec.invoice(due_at: now + 1.day, email: "early@example.org")
    BillingSpec.invoice(due_at: now - 3.days, email: "paid@example.org", paid_at: now - 1.day)
    BillingSpec.invoice(due_at: now - 10.days, email: "reminded@example.org", reminded_at: now - 2.days)
    BillingSpec.invoice(due_at: now - 20.days, email: "again@example.org", reminded_at: now - 8.days)

    Punch::Job::Queue.enqueue(Billing::Invoices::SweepOverdue.new)
    Punch::Spec.perform_jobs.map(&.type).should eq(["Billing::Invoices::SweepOverdue", "Billing::Invoices::RemindOverdue", "Billing::Invoices::RemindOverdue"])
    Punch::Spec.mails.map { |mail| {mail.to, mail.subject.split(" is ").last} }.sort!.should eq([
      {["again@example.org"], "still unpaid"},
      {["late@example.org"], "overdue"},
    ])
  end
end
