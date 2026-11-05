require "../../spec_helper"

describe Billing::Invoices do
  it "names invoices and their states in each locale" do
    en, de = Punch::I18n.locale("en"), Punch::I18n.locale("de")
    id = InvoicingSpec.parse(Billing::Invoices::ID, 7)
    number = InvoicingSpec.parse(Billing::Invoices::Number, "INV-000001")
    Billing::Invoices.title(en, nil, id).should eq("Draft #{id}")
    Billing::Invoices.title(de, number, id).should eq("Rechnung INV-000001")
    Billing::Invoices.state(de, :sent, overdue: true).should eq("überfällig")
    Billing::Invoices.state(en, :paid, overdue: false).should eq("paid")
  end
end
