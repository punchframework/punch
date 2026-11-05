# A paid count is how many invoices one customer has paid: a projection
# of the invoices, kept up to date in the same transaction as each
# payment, so a reader never sees the two disagree.
module Billing::PaidCounts
end
