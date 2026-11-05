# An invoice asks a customer to pay by a due date. Once that date has
# passed without payment, the invoice is overdue, and the customer is
# reminded once a week: politely the first time, firmly after that.
module Billing::Invoices
  # How long after one reminder the next one may go out.
  REMINDER_INTERVAL = 7.days
end
