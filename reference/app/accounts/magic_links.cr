# A magic link signs a person in without a password: they give an address,
# and if it belongs to an account the app mails a link that works once and
# for a short time. Whoever can read that mail can sign in, which is why
# the address counts as verified afterwards.
#
# Like a reset, asking never says whether the address has an account, and
# asking again cancels the earlier links. A link makes a session like any
# other, with the second step if the user has one.
module Accounts::MagicLinks
end
