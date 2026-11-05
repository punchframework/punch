module Billing::Customers
  @[Punch::Authorize(ByRole)]
  struct Show < Punch::Query
    struct Input
      include Punch::Input

      @[Punch::PathParam]
      getter customer_id : ID
    end

    alias Output = Customer | NotFound

    def call(input : Input, db : Punch::Reader, _actor : Invoicing::Actor) : Output
      record = Table.find(db, input.customer_id)
      record ? Customer.new(record) : NotFound.new
    end
  end
end
