module Billing::Invoices
  # Deletes a draft. A sent invoice stays.
  @[Punch::Authorize(ByRole)]
  struct Destroy < Punch::Command
    struct Input
      include Punch::Input

      @[Punch::PathParam]
      getter invoice_id : ID
    end

    alias Output = NotFound | AlreadySent?

    def call(input : Input, db : Punch::Writer, _actor : Invoicing::Actor, _grant : Punch::Grant(Destroy),
             events : Punch::Events(DraftDeleted)) : Output
      case invoice = Store.load(db, input.invoice_id)
      in Nil                          then NotFound.new
      in Invoice::Sent, Invoice::Paid then AlreadySent.new(invoice)
      in Invoice::Draft
        # The invoice's own organization, which need not be the one the
        # actor works in; read while the row is there.
        organization = Queries.organization(db, invoice_id: invoice.id) || return NotFound.new
        Store.delete(db, invoice)
        events.publish(DraftDeleted.new(invoice.id, organization.organization_id))
      end
    end
  end
end
