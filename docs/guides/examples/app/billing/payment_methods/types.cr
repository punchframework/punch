# The ID of a row of Billing::PaymentMethods, the type of the columns that hold
# one (lib/punch/docs/core-types.md).

module Billing::PaymentMethods
  struct ID < Punch::TypedID
  end
end
