module Accounts::Sessions
  # Starts a session: signs in with an email address and a password.
  # Punch checks the password before the transaction; the same answer
  # comes for an unknown address and a wrong password (lib/punch/docs/auth.md). An
  # account none of whose addresses is verified yet is refused, with the
  # right password only: nobody has shown it belongs to the address. Punch
  # publishes `SignInFailed` for a refused one.
  @[Punch::Public]
  @[Punch::RateLimit(10, per: 15.minutes, by: :email, store: :durable)]
  @[Punch::RateLimit(60, per: 1.minute, by: :ip)]
  struct Create < Punch::Command
    struct Input
      include Punch::Input

      getter email : Punch::Email
      getter password : Punch::Auth::Password
    end

    alias Output = SignedIn | Punch::Auth::InvalidCredentials | NotVerified

    def call(input : Input, db : Punch::Writer, auth : Punch::Auth::Authentication, password : Punch::Auth::PasswordCheck,
             events : Punch::Events(Punch::Auth::SignInSucceeded | Punch::Auth::SignInFailed)) : Output
      user_id = password.confirm(db, Users::ID) || return Punch::Auth::InvalidCredentials.new
      return NotVerified.new unless Punch::Auth::EmailIdentities.verified?(db, user_id)

      # No user has a second factor: the app offers none.
      session = auth.sign_in(user_id, method: "password").as(Punch::Auth::Session)
      events.publish(Punch::Auth::SignInSucceeded.new(user_id.value, session.id, "password"))
      SignedIn.new(user_id)
    end
  end
end
