# The billing slice's domain events (lib/punch/docs/events.md): what
# happened, with what a subscriber needs to look up the rest.

module Billing
  # An invoice's payment was recorded. Published by
  # `Invoices::RecordPayment`.
  record InvoicePaid,
    invoice_id : Invoices::ID,
    customer_email : Punch::Email do
    include Punch::Event
  end
end
