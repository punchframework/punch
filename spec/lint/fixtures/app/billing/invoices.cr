# An invoice is an organization's request that a customer pay for what
# it delivered.
module Billing::Invoices
  # How long a customer has to pay a sent invoice.
  PAYMENT_TERM = 14.days
  # Lines an invoice may hold.
  LINES = 1..100
end
