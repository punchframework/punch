module Billing::Invoices
  @[Punch::Authorize(ByRole)]
  struct Show < Punch::Query
    struct Input
      include Punch::Input

      @[Punch::PathParam]
      getter invoice_id : ID
    end

    alias Output = Detail | NotFound

    def call(input : Input, db : Punch::Reader, _actor : Invoicing::Actor) : Output
      invoice = Store.load(db, input.invoice_id)
      invoice ? Store.detail(db, invoice, Time.utc) : NotFound.new
    end
  end
end
