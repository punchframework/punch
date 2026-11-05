module Billing::PaidCounts
  # Counts a paid invoice in the payment's own transaction: if it fails,
  # the payment is not recorded either.
  @[Punch::Subscriber::Delivery(:inline)]
  struct CountPaid
    include Punch::Subscriber(InvoicePaid)

    def call(event : InvoicePaid, db : Punch::Writer) : Nil
      Queries.count(db, customer_email: event.customer_email)
    end
  end
end
