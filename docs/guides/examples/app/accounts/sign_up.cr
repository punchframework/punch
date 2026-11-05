# Signing up is how a person starts using the app: it makes their user,
# their first address and password, and signs them in, all or nothing. It
# has no data of its own, because it writes into the user and Punch's
# tables for addresses and passwords at once.
#
# It is open to anyone, so it is limited per client. The new address is
# unverified until its owner follows the mailed link, and a taken address
# leaves nothing behind.
module Accounts::SignUp
end
