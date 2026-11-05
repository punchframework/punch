# Domain types of invoices: IDs and the primitives the columns map to
# (db/columns.cr).

module Billing::Invoices
  struct ID < Punch::TypedID
    public_id "inv"
  end

  # The number a sent invoice carries, `INV-000042`: assigned in sending
  # order without gaps, at least six digits.
  struct Number
    include Punch::Primitive(String)

    FORMAT = /\AINV-[0-9]{6,}\z/

    def self.json_schema
      {pattern: "^INV-[0-9]{6,}$"}
    end

    def self.parse(raw : String) : self | Punch::Invalid
      FORMAT.matches?(raw) ? new(raw) : Punch::Invalid.new("invalid_invoice_number")
    end

    # The number after *sequence*, the numeric part of the last one issued.
    def self.next(sequence : Int64) : self
      new("INV-#{(sequence + 1).to_s.rjust(6, '0')}")
    end
  end

  # How many units a line bills, 1 to 10,000.
  struct Quantity
    include Punch::Primitive(Int64)

    MAX = 10_000_i64

    def self.json_schema
      {minimum: 1, maximum: MAX}
    end

    def self.parse(raw : Int) : self | Punch::Invalid
      raw >= 1 && raw <= MAX ? new(raw.to_i64) : Punch::Invalid.new("out_of_range", min: 1, max: MAX)
    end
  end

  module Lines
    struct ID < Punch::TypedID
    end
  end
end
