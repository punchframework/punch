module Billing::Invoices
  # The invoice behind a link from `Link`. A forged, expired, or unknown
  # link is not found.
  @[Punch::Public]
  struct Shared < Punch::Query
    struct Input
      include Punch::Input

      @[Punch::PathParam]
      getter token : String
    end

    alias Output = Detail | NotFound

    def call(input : Input, db : Punch::Reader) : Output
      now = Time.utc
      id = Sharing.invoice_id(input.token, now) || return NotFound.new

      case invoice = Store.load(db, id)
      in Invoice::Sent, Invoice::Paid then Store.detail(db, invoice, now)
      in Invoice::Draft, Nil          then NotFound.new
      end
    end
  end
end
