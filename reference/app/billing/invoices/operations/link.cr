module Billing::Invoices
  # Only a sent invoice can be shared.
  @[Punch::Status(422)]
  struct NotSent
    include Punch::Problem
  end

  # A link that shows an invoice without signing in.
  @[Punch::Status(200)]
  record ShareLink,
    path : String,
    expires_at : Time do
    include JSON::Serializable
  end

  # A link to a sent invoice for its recipient, valid for 30 days, that
  # needs no sign-in.
  @[Punch::Authorize(ByRole)]
  struct Link < Punch::Query
    struct Input
      include Punch::Input

      @[Punch::PathParam]
      getter invoice_id : ID
    end

    alias Output = ShareLink | NotFound | NotSent

    def call(input : Input, db : Punch::Reader, _actor : Invoicing::Actor) : Output
      case invoice = Store.load(db, input.invoice_id)
      in Nil            then NotFound.new
      in Invoice::Draft then NotSent.new
      in Invoice::Sent, Invoice::Paid
        expires_at = Time.utc.at_beginning_of_second + Sharing::VALID
        ShareLink.new(Shared.path(token: Sharing.token(invoice, expires_at)), expires_at)
      end
    end
  end
end
