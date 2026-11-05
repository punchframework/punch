require "../../spec_helper"

private def paid_invoices(email : String) : Int64?
  Punch::Spec.db.read { |db| db.query_one?("SELECT invoices FROM paid_counts WHERE customer_email = ?", email, &.read(Int64)) }
end

describe Billing::PaidCounts::CountPaid do
  it "counts each paid invoice in the payment's transaction, and a refused payment not at all" do
    client = AccountsSpec.client
    first, second = BillingSpec.invoice(due_at: Time.utc), BillingSpec.invoice(due_at: Time.utc)
    pay = ->(invoice : Billing::Invoices::Record) { client.post(Billing::Invoices::RecordPayment.path(invoice_id: invoice.id)) }

    -> { pay.call(first).status.should eq(HTTP::Status::OK) }.should publish(Billing::InvoicePaid, invoice_id: first.id, times: 1)
    pay.call(second)
    paid_invoices("ada@example.org").should eq(2)

    pay.call(first).json["code"].should eq("already_paid")
    paid_invoices("ada@example.org").should eq(2)
  end
end
