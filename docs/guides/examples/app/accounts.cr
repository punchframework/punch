# Accounts is who may use the app and as whom: people with their ways of
# proving who they are, and the roles that say what they may do. It knows
# nothing about the rest of the app, which asks it only who is acting.
#
# Every way of signing in ends in the same place, a session or an API
# token that stands for one user. Whatever changes how a user signs in (a
# new address, a changed password) is announced to them
# by mail, and when they make the change while signed in it needs a recent
# proof of who they are. Asking for a mailed link never reveals whether an
# address has an account.
module Accounts
end
