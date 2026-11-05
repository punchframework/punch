# The ID of a row of Billing::IdScans, the type of the columns that hold
# one (lib/punch/docs/core-types.md).

module Billing::IdScans
  struct ID < Punch::TypedID
  end
end
