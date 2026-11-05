require "../../spec_helper"

describe Billing::Invoices::Create do
  it "records an invoice, and refuses a second one with its number at `number`" do
    client = AccountsSpec.client
    invoice = {number: "INV-000042", customer_email: "ada@example.org", due_at: "2026-11-30T00:00:00Z"}
    client.post(Billing::Invoices::Create.path, json: invoice).status.should eq(HTTP::Status::CREATED)

    taken = client.post(Billing::Invoices::Create.path, json: invoice.merge(customer_email: "grace@example.org"))
    taken.status.should eq(HTTP::Status::UNPROCESSABLE_ENTITY)
    taken.json["errors"].should eq(JSON.parse(%([{"path": ["number"], "code": "taken", "params": {}, "message": "Is already taken."}])))
  end
end
