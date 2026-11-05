# Behaviour of the generated customer record (tier 1).
struct Ledger::Customers::Record
  include Ledger::Emailed

  def display_name : String
    company_name || name
  end
end
