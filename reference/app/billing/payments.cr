# A payment is money that a customer sent for an invoice, as the payment
# provider reports it. The app does not take payments; it learns of them,
# and a payment that matches a sent invoice settles it.
#
# Payments only arrive from the provider, signed. A payment for an
# invoice that is paid already changes nothing, and one that does not
# fit its invoice is refused and stays visible for someone to look at. Invoices are the model that
# settles; this namespace is the door the provider knocks on.
module Billing::Payments
end
