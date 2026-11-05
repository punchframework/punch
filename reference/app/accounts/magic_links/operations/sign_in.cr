module Accounts::MagicLinks
  # Signs in through a mailed link: the button on `SignInPage`, which uses
  # the token up. The address counts as verified. A user with an
  # authenticator app gives its code next.
  @[Punch::Public]
  @[Punch::RateLimit(30, per: 1.minute, by: :ip)]
  struct SignIn < Punch::Command
    struct Input
      include Punch::Input

      getter token : String
    end

    alias Output = Sessions::SignedIn | LinkExpired | Punch::Auth::SecondFactorRequired

    def call(input : Input, db : Punch::Writer, auth : Punch::Auth::Authentication,
             events : Punch::Events(Punch::Auth::SignInSucceeded)) : Output
      user_id, email = LinkStore.holder(Punch::Auth::OneTimeTokens.consume(db, Links::MAGIC_LINK, input.token), db) || return LinkExpired.new
      Punch::Auth::EmailIdentities.verify(db, email)

      case session = auth.sign_in(user_id, method: "magic_link")
      in Punch::Auth::SecondFactorRequired then session # the link was the first step
      in Punch::Auth::Session
        events.publish(Punch::Auth::SignInSucceeded.new(user_id.value, session.id, "magic_link"))
        Sessions::SignedIn.new(user_id)
      end
    end
  end
end
