require "../../spec_helper"

describe Billing::Invoices::Due do
  it "lists the unpaid invoices due in a period, and refuses a period that ends before it starts" do
    client = AccountsSpec.client
    due = BillingSpec.invoice(due_at: Time.utc(2026, 11, 10))
    BillingSpec.invoice(due_at: Time.utc(2026, 11, 12), paid_at: Time.utc(2026, 11, 1))
    BillingSpec.invoice(due_at: Time.utc(2026, 12, 10))
    listed = client.get(Billing::Invoices::Due.path, query: {from: "2026-11-01T00:00:00Z", before: "2026-12-01T00:00:00Z"})
    listed.json["invoices"].as_a.map(&.["number"]).should eq([due.number])

    refused = client.get(Billing::Invoices::Due.path, query: {from: "2026-12-01T00:00:00Z", before: "2026-11-01T00:00:00Z"})
    refused.status.should eq(HTTP::Status::UNPROCESSABLE_ENTITY)
    refused.json["errors"].should eq(JSON.parse(%([{"path": ["before"], "code": "before_start", "params": {}, "message": "Must be after the start."}])))
  end
end
