# A session is one browser's signed-in state for one user. Signing in
# starts one, signing out or ending it from the list of sessions stops it,
# and a user sees only their own, with where and when each was last used.
#
# A session is a proof of who the user is, but an old one is not proof
# enough for changes that weaken how they sign in: for those the user
# confirms who they are again. This is also where a browser without a
# session is sent, and where signing in by password begins; the other ways
# in (an emailed link, a second step) are their own namespaces that end in
# a session here.
module Accounts::Sessions
end
