# Payments arrive from a payment provider as webhooks (lib/punch/docs/webhooks.md). The
# provider here is a stand-in for a real one: it signs by the Standard
# Webhooks scheme (headers `webhook-id`, `webhook-timestamp`,
# `webhook-signature`) and sends
#
#     {"event": "payment.succeeded",
#      "data": {"payment_id": "pay_…", "invoice_number": "INV-000001",
#               "amount": 37500, "currency": "EUR", "paid_at": "…"}}
#
# Punch stores each delivery at `POST /webhooks/payments` and answers 204;
# its job then calls `parse` and `process` here.

module Billing::Payments
  # The part of every delivery that says what happened.
  struct Envelope
    include Punch::Input

    getter event : String
  end

  # `payment.succeeded`: a payment that names the invoice it settles.
  struct Succeeded
    include Punch::Input

    getter data : Payment
  end

  struct Payment
    include Punch::Input

    # The provider's ID of the payment.
    getter payment_id : Punch::NonEmptyString
    getter invoice_number : Invoices::Number
    getter amount : Punch::Money
    getter currency : Punch::Currency
    getter paid_at : Time
  end

  # The payment provider. Its secret is the optional credential
  # `payments.webhook_secret` (and `previous_webhook_secret` during a
  # rotation); without one the endpoint answers 404.
  @[Punch::Webhook::Provider("payments", body_limit: 64 * 1024)]
  struct Provider < Punch::Webhook::Inbound
    def verifier : Punch::Webhook::Verifier?
      secrets = Invoicing::Credentials.current.payments.webhook_secrets || return
      Punch::Webhook::HMAC.new(secrets)
    end

    # `payment.succeeded` is handled; other events are ignored.
    def parse(request : Punch::RawRequest) : Succeeded | Punch::Webhook::Ignored | Punch::Webhook::Unprocessable
      case envelope = Envelope.from_json(request.body)
      in Punch::Rejection then Punch::Webhook::Unprocessable.new("no event type")
      in Envelope
        return Punch::Webhook::Ignored.new(envelope.event) unless envelope.event == "payment.succeeded"

        case succeeded = Succeeded.from_json(request.body)
        in Punch::Rejection then Punch::Webhook::Unprocessable.new("payment.succeeded without a valid payment")
        in Succeeded        then succeeded
        end
      end
    end

    # Marks the invoice paid. A payment for an invoice that is paid
    # already changes nothing; one for an unknown invoice or of the wrong
    # amount fails, which publishes `Punch::Webhook::ProcessingFailed`.
    def process(event : Succeeded, db : Punch::Writer, events : Punch::Events(InvoicePaid)) : Punch::Webhook::Outcome
      payment = event.data
      id = Invoices::Queries.id_by_number(db, number: payment.invoice_number).try(&.id)

      case invoice = id && Invoices::Store.load(db, id)
      in Nil, Invoices::Invoice::Draft then Punch::Webhook::Failed.new("no sent invoice #{payment.invoice_number}")
      in Invoices::Invoice::Paid       then Punch::Webhook::Processed.new
      in Invoices::Invoice::Sent
        case paid = invoice.pay(payment.amount, payment.currency, payment.paid_at, payment.payment_id)
        in Invoices::Invoice::WrongAmount
          Punch::Webhook::Failed.new("#{payment.amount} #{payment.currency} does not settle #{payment.invoice_number} (#{paid.total} #{paid.currency})")
        in Invoices::Invoice::Paid
          Invoices::Store.save(db, paid)
          events.publish(InvoicePaid.new(paid.id, paid.customer_id))
          Punch::Webhook::Processed.new
        end
      end
    end
  end
end
