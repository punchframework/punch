require "../../spec_helper"

describe Billing::Invoices::SendReminder do
  it "enqueues a first reminder through the outbox, and none for a paid invoice" do
    client = AccountsSpec.client
    invoice = BillingSpec.invoice(due_at: Time.utc - 3.days)
    remind = -> { client.post(Billing::Invoices::SendReminder.path(invoice_id: invoice.id)).status.should eq(HTTP::Status::ACCEPTED) }
    remind.should enqueue(Billing::Invoices::RemindOverdue, invoice_id: invoice.id, reminder: Billing::Invoices::Reminder::First, times: 1)

    paid = BillingSpec.invoice(due_at: Time.utc - 3.days, paid_at: Time.utc)
    refused = -> { client.post(Billing::Invoices::SendReminder.path(invoice_id: paid.id)).json["code"].should eq("already_paid") }
    refused.should enqueue(Billing::Invoices::RemindOverdue, times: 0)
  end
end
