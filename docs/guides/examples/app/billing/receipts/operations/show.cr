module Billing::Receipts
  @[Punch::Authorize(Own)]
  struct Show < Punch::Query
    struct Input
      include Punch::Input

      @[Punch::PathParam]
      getter receipt_id : ID
    end

    alias Output = Detail | NotFound

    def call(input : Input, db : Punch::Reader, _actor : Examples::Actor) : Output
      receipt = Table.find(db, input.receipt_id)
      receipt ? Detail.of(receipt) : NotFound.new
    end
  end
end
