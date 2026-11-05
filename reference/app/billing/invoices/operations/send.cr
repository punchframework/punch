module Billing::Invoices
  # An invoice without lines cannot be sent.
  @[Punch::Status(422)]
  struct NoLines
    include Punch::Problem
  end

  # Sends a draft: it gets the next invoice number and is due after the
  # payment term, and it keeps the customer's name and address as they
  # are now. Only a draft with lines can be sent. Each user sends at most
  # 30 an hour, since each one mails a customer (`MailInvoice`). A client
  # must name each attempt with an idempotency key, so a retry after a
  # lost answer gets that answer instead of `already_sent`.
  @[Punch::Authorize(ByRole)]
  @[Punch::RateLimit(30, per: 1.hour, by: :actor)]
  @[Punch::Idempotency(:required)]
  struct Send < Punch::Command
    struct Input
      include Punch::Input

      @[Punch::PathParam]
      getter invoice_id : ID
    end

    alias Output = Detail | NotFound | AlreadySent | NoLines

    def call(input : Input, db : Punch::Writer, _actor : Invoicing::Actor, _grant : Punch::Grant(Send),
             events : Punch::Events(InvoiceSent), jobs : Punch::Jobs(Remind)) : Output
      case invoice = Store.load(db, input.invoice_id)
      in Nil                          then NotFound.new
      in Invoice::Sent, Invoice::Paid then AlreadySent.new(invoice)
      in Invoice::Draft
        now = Time.utc

        # The customer is there: the foreign key keeps it while an invoice is.
        customer = Customers::Table.find(db, invoice.customer_id) || return NotFound.new
        case sent = invoice.send(Store.next_number(db), now, BilledTo.of(customer))
        in Invoice::NoLines then NoLines.new
        in Invoice::Sent
          Store.save(db, sent)
          events.publish(InvoiceSent.new(sent.id, sent.customer_id))
          # Through the outbox: the reminder exists exactly when the sent invoice does.
          jobs.enqueue(Remind.new(sent.id), at: sent.due_at)
          Store.detail(db, sent, now)
        end
      end
    end
  end
end
