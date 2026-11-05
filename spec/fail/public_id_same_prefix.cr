require "../../src/punch"

struct InvoiceID < Punch::TypedID
  public_id "inv"
end

struct InventoryID < Punch::TypedID
  public_id "inv"
end
