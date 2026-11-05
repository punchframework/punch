module Billing::Receipts
  # Deletes a receipt and gives up its scan: the sweep deletes the file
  # from the storage after this transaction commits.
  @[Punch::Authorize(Own)]
  struct Destroy < Punch::Command
    struct Input
      include Punch::Input

      @[Punch::PathParam]
      getter receipt_id : ID
    end

    alias Output = NotFound?

    def call(input : Input, db : Punch::Writer, actor : Examples::Actor, _grant : Punch::Grant(Destroy)) : Output
      receipt = Table.find(db, input.receipt_id) || return NotFound.new

      Table.delete(db, receipt.id)
      Punch::Upload.discard(db, receipt.scan, owner: actor.user.id.to_s)
      nil
    end
  end
end
