# A password is one of the ways a user proves who they are: kept only as a
# hash, never shown again, and chosen by the user. This namespace is where
# a user sets a new one, knowing the old, or with the link a reset mailed
# them.
#
# Changing or resetting a password ends the user's other sessions, so a
# stolen session does not survive it, and tells the user by mail. Asking
# for a reset is its own namespace, because it makes no change yet.
module Accounts::Passwords
end
