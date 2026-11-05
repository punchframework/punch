module Accounts::SecondFactor
  # Confirms the setup with the app's current code: from now on signing in
  # takes the second step. The session counts as signed in with the app,
  # and the user's addresses are told (`SecondFactorChanged`). Needs a
  # recent sign-in, as `Create` does: a session left open must not turn
  # a setup someone else began into an authenticator of theirs.
  @[Punch::Authorize(Punch::RecentlyAuthenticated)]
  @[Punch::RateLimit(10, per: 15.minutes, by: :actor)]
  struct Confirm < Punch::Command
    struct Input
      include Punch::Input

      getter code : Punch::Auth::OneTimeCode
    end

    alias Output = Changed | Punch::Auth::InvalidCode

    def call(input : Input, db : Punch::Writer, actor : Invoicing::Actor, auth : Punch::Auth::Authentication, _grant : Punch::Grant(Confirm),
             events : Punch::Events(Punch::Auth::SecondFactorChanged)) : Output
      return Punch::Auth::InvalidCode.new unless Punch::Auth::SecondFactors.confirm(db, actor.user.id, input.code)

      auth.renew(method: "totp")
      events.publish(Punch::Auth::SecondFactorChanged.new(actor.user.id.value, :enabled))
      Changed.new(true)
    end
  end
end
