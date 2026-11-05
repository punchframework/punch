# The customer's ID and tax number, the types of its columns (columns.cr).

module Billing::Customers
  struct ID < Punch::TypedID
    public_id "cus"
  end

  # A VAT or tax number, `DE123456789`: a country code and 2 to 13
  # letters or digits, kept without spaces and in capitals, so the same
  # number written two ways is one value. That matters for its blind
  # index, which finds only equal values.
  struct TaxID
    include Punch::Primitive(String)

    FORMAT = /\A[A-Z]{2}[A-Z0-9]{2,13}\z/

    def self.json_schema
      {pattern: "^ *[A-Za-z] *[A-Za-z]( *[A-Za-z0-9]){2,13} *$"}
    end

    def self.parse(raw : String) : self | Punch::Invalid
      normal = raw.delete(' ').upcase(Unicode::CaseOptions::ASCII)
      FORMAT.matches?(normal) ? new(normal) : Punch::Invalid.new("invalid_tax_id")
    end
  end
end
