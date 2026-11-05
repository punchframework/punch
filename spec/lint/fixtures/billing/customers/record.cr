# Punch/RecordFile: the record's own file, where it may be reopened.
struct Billing::Customers::Record
  def display_name : String
    name
  end
end

module Billing::Customers
  struct Record
  end
end

# Another record does not belong here.
struct Billing::Invoices::Record # expect
end
