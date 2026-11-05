require "../../src/punch"

struct InvoiceID < Punch::TypedID
end

struct CustomerID < Punch::TypedID
end

module Invoices
  @[Punch::Public]
  struct Show < Punch::Query
    struct Input
      include Punch::Input
      @[Punch::PathParam]
      getter invoice_id : InvoiceID
    end

    def call(input : Input, db : Punch::Reader) : Nil
    end
  end
end

Invoices::Show.path(invoice_id: CustomerID.parse(1).as(CustomerID))
