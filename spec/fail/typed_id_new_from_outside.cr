require "../../src/punch"

struct InvoiceID < Punch::TypedID
end

InvoiceID.new(-1_i64)
