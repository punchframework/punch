module Accounts
  # An email address was added to a user, unverified: a verification mail
  # goes to it, a notice to the user's other verified addresses.
  record EmailAdded,
    user_id : Int64,
    email : Punch::Email do
    include Punch::Event
  end

  # An email address was removed from a user: a notice goes to it, so its
  # owner learns if someone else did it.
  record EmailRemoved,
    user_id : Int64,
    email : Punch::Email do
    include Punch::Event
  end
end
