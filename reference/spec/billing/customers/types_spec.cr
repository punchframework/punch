require "../../spec_helper"

describe Billing::Customers::TaxID do
  it "keeps a number without spaces and in capitals, so its blind index finds it written either way" do
    Billing::Customers::TaxID.parse("at u1234 5678").as(Billing::Customers::TaxID).value.should eq("ATU12345678")
    Billing::Customers::TaxID.parse("ÄT12345678").should be_invalid("invalid_tax_id")
  end

  it "describes tax numbers as it parses them" do
    Punch::Spec.schema_agrees(Billing::Customers::TaxID,
      valid: ["DE123456789", "de 123 456 789", " AT U12345678 ", "NL123456789B01", "XX12"],
      invalid: ["", "DE", "DE1", "123456789", "D E", "DE-123456789", "ÄT12345678", "DE1234567890123456"])
  end
end
