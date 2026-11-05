# The ID of a row of Billing::Receipts, the type of the columns that hold
# one (lib/punch/docs/core-types.md).

module Billing::Receipts
  struct ID < Punch::TypedID
  end
end
