# A customer is someone an organization bills: a company or a person it
# sends invoices to, and who pays them.
#
# An organization keeps its customers for as long as it has invoiced
# them, so a customer is kept up to date rather than removed. What a
# customer owes, in total and overdue, follows from the invoices sent to
# it and the payments received for them. Each organization knows only
# its own customers, and writes to each in the customer's language.
module Billing::Customers
end
