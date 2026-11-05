# Signing up is how a person starts using the app: it makes their user,
# their first address and password, and an organization of their own that
# they administer, and signs them in, all or nothing. It has no data of
# its own, because it writes into users and organizations at once.
#
# It is open to anyone, so it is limited per client. The new address is
# unverified until its owner follows the mailed link, and a taken address
# leaves nothing behind.
module Accounts::SignUp
end
