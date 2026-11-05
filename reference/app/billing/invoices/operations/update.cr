module Billing::Invoices
  # Revises a draft: a new currency, new lines (replacing all), or both.
  @[Punch::Authorize(ByRole)]
  struct Update < Punch::Command
    struct Input
      include Punch::Input

      @[Punch::PathParam]
      getter invoice_id : ID

      getter currency : Punch::Currency?
      getter lines : Array(LineInput)?

      def check(errors : Punch::Rejection::Collector) : Nil
        Invoices.check_lines(lines, errors)
      end
    end

    alias Output = Detail | NotFound | AlreadySent

    def call(input : Input, db : Punch::Writer, _actor : Invoicing::Actor, _grant : Punch::Grant(Update),
             events : Punch::Events(DraftRevised)) : Output
      case invoice = Store.load(db, input.invoice_id)
      in Nil                          then NotFound.new
      in Invoice::Sent, Invoice::Paid then AlreadySent.new(invoice)
      in Invoice::Draft
        revised = invoice.revise(
          currency: input.currency || invoice.currency,
          lines: input.lines.try(&.map(&.to_line)) || invoice.lines)
        Store.save(db, revised)
        events.publish(DraftRevised.new(revised.id))
        Store.detail(db, revised, Time.utc)
      end
    end
  end
end
