module Accounts::SecondFactor
  # Removes the authenticator app and its recovery codes: signing in takes
  # the password (or a mailed link) alone again. Needs a recent
  # authentication, which for this user means the app's code; the user's
  # addresses are told.
  @[Punch::Authorize(Punch::RecentlyAuthenticated)]
  struct Destroy < Punch::Command
    struct Input
      include Punch::Input
    end

    alias Output = Changed

    def call(input : Input, db : Punch::Writer, actor : Invoicing::Actor, _grant : Punch::Grant(Destroy),
             events : Punch::Events(Punch::Auth::SecondFactorChanged)) : Output
      if Punch::Auth::SecondFactors.remove(db, actor.user.id)
        events.publish(Punch::Auth::SecondFactorChanged.new(actor.user.id.value, :removed))
      end
      Changed.new(false)
    end
  end
end
