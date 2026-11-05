# The ID of a row of Billing::Invoices, the type of the columns that hold
# one (lib/punch/docs/core-types.md).

module Billing::Invoices
  struct ID < Punch::TypedID
  end

  # Which reminder a customer gets: the first one, or a firmer one after it.
  enum Reminder
    First
    Final
  end
end
