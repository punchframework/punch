require "../../spec_helper"

# A primitive's `json_schema` restates its `parse`; these keep the two the
# same (lib/punch/docs/json-schema.md).

private def number(sequence = 0_i64) : Billing::Invoices::Number
  Billing::Invoices::Number.next(sequence)
end

describe Billing::Invoices::Number do
  it "counts on past six digits" do
    number(999_999).value.should eq("INV-1000000")
    Billing::Invoices::Number.parse("INV-1000000").should be_a(Billing::Invoices::Number)
    Billing::Invoices::Number.parse("INV-42").should be_invalid("invalid_invoice_number")
  end
end

describe "Billing primitives" do
  it "describes invoice numbers as it parses them" do
    Punch::Spec.schema_agrees(Billing::Invoices::Number,
      valid: ["INV-000001", "INV-999999", "INV-1000000"],
      invalid: ["", "INV-", "INV-00001", "inv-000001", "INV-00000a", " INV-000001", "INV-000001 ", "XINV-000001"])
  end

  it "describes quantities as it parses them" do
    Punch::Spec.schema_agrees(Billing::Invoices::Quantity,
      valid: [1_i64, 2_i64, 9_999_i64, Billing::Invoices::Quantity::MAX],
      invalid: [0_i64, -1_i64, Billing::Invoices::Quantity::MAX + 1, Int64::MAX, Int64::MIN])
  end
end
