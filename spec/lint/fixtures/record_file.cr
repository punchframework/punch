# Punch/RecordFile: a record reopened outside the file named after it.
struct Billing::Customers::Record # expect
  def display_name : String
    name
  end
end

module Billing
  module Customers
    struct Record # expect
    end
  end

  # Not a record: a struct with another name, and a module named Record.
  struct Summary
  end

  module Record
  end
end
