# An invoice is an organization's request that a customer pay for what
# it delivered: lines of work or goods, priced in one currency.
#
# It starts as a draft, which the organization may change or discard
# as it likes. Sending it to the customer makes it binding: it gets its
# number, falls due after the payment term, and never changes again. A
# payment of its amount settles it; a sent invoice still unpaid after
# its due date is overdue, and the customer is reminded.
#
# Invoices are what the rest of billing turns on: a customer owes what
# its sent invoices add up to, and payments exist to settle them.
module Billing::Invoices
  # How long a customer has to pay a sent invoice.
  PAYMENT_TERM = 14.days
end
