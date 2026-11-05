# An email address is how the app reaches a user and one of the ways they
# sign in. A user may have several; an address belongs to one user at a
# time and counts for roles only once its owner has followed the link mailed
# to it.
#
# Adding or removing an address needs a recent proof of who the user is,
# and the user's other addresses are told, so someone who got into an
# account cannot quietly take it over. The last way to sign in cannot be
# removed.
module Accounts::Emails
end
