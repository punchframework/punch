# The second factor is an authenticator app that a user can add as a second
# step to signing in: after the password (or a mailed link) the browser
# also needs a code the app shows, or one of the recovery codes given when
# it was set up.
#
# It is on only once the user has proved that the app works, so a mistake
# cannot lock them out. Turning it off, replacing the recovery codes, or
# using it as the proof of identity for other changes all take the app's
# code again, and each change is mailed to the user.
module Accounts::SecondFactor
end
