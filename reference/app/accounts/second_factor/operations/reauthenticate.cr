module Accounts::SecondFactor
  # Proves again who the user is with the app's code (or a recovery code),
  # for changes that need a recent authentication. A user with an app
  # proves it this way; the password alone no longer counts for them.
  @[Punch::Authorize(Punch::SignedIn)]
  @[Punch::RateLimit(5, per: 15.minutes, by: :actor, store: :durable)]
  struct Reauthenticate < Punch::Command
    struct Input
      include Punch::Input

      getter code : Punch::Auth::OneTimeCode
    end

    alias Output = Accounts::Sessions::Reauthenticated | Punch::Auth::InvalidCode

    def call(input : Input, db : Punch::Writer, actor : Invoicing::Actor, auth : Punch::Auth::Authentication, _grant : Punch::Grant(Reauthenticate),
             second_factor : Punch::Auth::OwnSecondFactorCheck) : Output
      factor = second_factor.confirm(db) || return Punch::Auth::InvalidCode.new
      auth.renew(method: factor)
      Accounts::Sessions::Reauthenticated.new
    end
  end
end
