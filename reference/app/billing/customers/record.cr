# Tier 1 (lib/punch/docs/models.md): a customer is reference data, created, shown, and
# edited. Its behaviour lives on the generated record, reopened here.
struct Billing::Customers::Record
  # The name invoices are addressed to: the company when there is one.
  def display_name : String
    (company_name || name).value
  end
end
