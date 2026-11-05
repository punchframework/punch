module Billing::Invoices
  # Who a sent invoice bills, kept as the customer was then.
  struct BilledTo
    # The customer as an invoice sent now bills them.
    def self.of(customer : Customers::Record) : self
      built = build(customer_id: customer.id, name: customer.name, company_name: customer.company_name,
        address: customer.address.try(&.unwrap), tax_id: customer.tax_id.try(&.unwrap))
      built.is_a?(Punch::Invalid) ? too_large(customer.id, built) : built
    end

    def display_name : String
      (company_name || name).value
    end

    # The name and the address, one line each.
    def lines : Array(String)
      [display_name] + (address.try(&.value.lines) || [] of String)
    end

    private def self.too_large(id : Customers::ID, invalid : Punch::Invalid) : NoReturn
      raise ArgumentError.new("customer #{id.value} does not fit an invoice: #{invalid.code}")
    end
  end
end
