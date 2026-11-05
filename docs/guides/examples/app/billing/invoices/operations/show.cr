module Billing::Invoices
  # One invoice, or `not_found`.
  @[Punch::Authorize(Punch::SignedIn)]
  struct Show < Punch::Query
    struct Input
      include Punch::Input

      @[Punch::PathParam]
      getter invoice_id : ID
    end

    alias Output = Detail | NotFound

    def call(input : Input, db : Punch::Reader, _actor : Examples::Actor) : Output
      case invoice = Table.find(db, input.invoice_id)
      in Nil    then NotFound.new
      in Record then Detail.of(invoice)
      end
    end
  end
end
