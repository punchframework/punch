module Accounts::SecondFactor
  # The second step of signing in: the code from the app, or a recovery
  # code, for the user whose password (or mailed link) this browser just
  # gave. Punch finds the challenge in its cookie and limits the tries per
  # user (`Punch::Auth::SecondFactorCheck`).
  @[Punch::Public]
  @[Punch::RateLimit(5, per: 15.minutes, by: :challenge, store: :durable)]
  @[Punch::RateLimit(60, per: 1.minute, by: :ip)]
  struct SignIn < Punch::Command
    struct Input
      include Punch::Input

      getter code : Punch::Auth::OneTimeCode
    end

    alias Output = Accounts::Sessions::SignedIn | Punch::Auth::InvalidCode | Punch::Auth::SecondFactorExpired

    def call(input : Input, db : Punch::Writer, auth : Punch::Auth::Authentication, second_factor : Punch::Auth::SecondFactorCheck,
             events : Punch::Events(Punch::Auth::SignInSucceeded)) : Output
      case session = second_factor.sign_in(db, auth)
      in Punch::Auth::InvalidCode, Punch::Auth::SecondFactorExpired then session
      in Punch::Auth::Session
        user_id = session.user_id(Users::ID)
        events.publish(Punch::Auth::SignInSucceeded.new(user_id.value, session.id, session.method))
        Accounts::Sessions::SignedIn.new(user_id)
      end
    end
  end
end
