# The ID of a row of Billing::PaidCounts, the type of the columns that hold
# one (lib/punch/docs/core-types.md).

module Billing::PaidCounts
  struct ID < Punch::TypedID
  end
end
