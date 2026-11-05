# The ID of a row of Billing::Products, the type of the columns that hold
# one (lib/punch/docs/core-types.md).

module Billing::Products
  struct ID < Punch::TypedID
  end
end
