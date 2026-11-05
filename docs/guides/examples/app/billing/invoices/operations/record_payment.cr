module Billing::Invoices
  # Records that an invoice was paid, now. A paid invoice stays as it is.
  @[Punch::Authorize(Punch::SignedIn)]
  struct RecordPayment < Punch::Command
    struct Input
      include Punch::Input

      @[Punch::PathParam]
      getter invoice_id : ID
    end

    alias Output = Detail | NotFound | AlreadyPaid

    def call(input : Input, db : Punch::Writer, _actor : Examples::Actor, _grant : Punch::Grant(RecordPayment),
             events : Punch::Events(InvoicePaid)) : Output
      invoice = Table.find(db, input.invoice_id) || return NotFound.new
      if paid_at = invoice.paid_at
        return AlreadyPaid.new(paid_at)
      end

      now = Time.utc
      Queries.mark_paid(db, id: invoice.id, now: now)
      events.publish(InvoicePaid.new(invoice.id, invoice.customer_email))
      Detail.of(invoice.copy_with(paid_at: now))
    end
  end
end
