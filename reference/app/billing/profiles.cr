# A billing profile is how an organization appears on the invoices it
# sends: the postal address it does business from, printed as the
# sender of every invoice.
#
# Each organization has at most one, set by its administrators; until
# then its invoices show no sender's address. Changing it changes the
# sender on every invoice shown afterwards, also sent ones.
module Billing::Profiles
end
