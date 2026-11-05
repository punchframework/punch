require "../../spec_helper"

describe Billing::Invoices::Show do
  it "shows an invoice, and answers 404 for one that does not exist" do
    client = AccountsSpec.client
    invoice = BillingSpec.invoice(due_at: Time.utc(2026, 11, 30))
    shown = client.get(Billing::Invoices::Show.path(invoice_id: invoice.id))
    {shown.status, shown.json["number"]}.should eq({HTTP::Status::OK, invoice.number})

    missing = client.get(Billing::Invoices::Show.path(invoice_id: ExamplesSpec.parse(Billing::Invoices::ID, invoice.id.value + 1)))
    {missing.status, missing.json["code"]}.should eq({HTTP::Status::NOT_FOUND, "not_found"})
  end
end
