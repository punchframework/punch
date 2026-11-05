# The ID of a row of Billing::Statements, the type of the columns that hold
# one (lib/punch/docs/core-types.md).

module Billing::Statements
  struct ID < Punch::TypedID
  end
end
