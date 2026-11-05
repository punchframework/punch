module Accounts::Sessions
  # Proves again who the user is with their password (checked by Punch
  # before the transaction, `Punch::Auth::OwnPasswordCheck`), for changes that
  # need a recent authentication.
  @[Punch::Authorize(Punch::SignedIn)]
  @[Punch::RateLimit(10, per: 15.minutes, by: :actor, store: :durable)]
  struct Reauthenticate < Punch::Command
    struct Input
      include Punch::Input

      getter current_password : Punch::Auth::Password
    end

    alias Output = Reauthenticated | Punch::Auth::InvalidCredentials

    def call(input : Input, db : Punch::Writer, actor : Examples::Actor, auth : Punch::Auth::Authentication, _grant : Punch::Grant(Reauthenticate),
             password : Punch::Auth::OwnPasswordCheck) : Output
      return Punch::Auth::InvalidCredentials.new unless password.confirm(db)

      auth.renew(method: "password")
      Reauthenticated.new
    end
  end
end
