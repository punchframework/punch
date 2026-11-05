# A password reset is a person asking for a way back in when they forgot
# their password. They give an address, and if it belongs to an account the
# app mails a link that works once and for a short time.
#
# The answer is the same whether the address has an account or not, and
# takes as long, so asking cannot be used to find out who has one. The
# mailed link leads to setting the new password (`Passwords`); asking again
# cancels the earlier links.
module Accounts::PasswordResets
end
