module Accounts::Passwords
  @[Punch::Status(200)]
  struct ResetDone
    include JSON::Serializable

    def initialize
    end
  end

  # Sets a new password through a mailed reset link: the button on
  # `ResetPage`, which uses the token up. Every session of the user ends,
  # and every API token, since whoever knew the old password may have made
  # one; the address counts as verified (the link proved it), and the user
  # is told. They sign in afresh.
  @[Punch::Public]
  @[Punch::RateLimit(30, per: 1.minute, by: :ip)]
  struct Reset < Punch::Command
    struct Input
      include Punch::Input

      getter token : String
      getter password : Punch::Auth::NewPassword
    end

    alias Output = ResetDone | LinkExpired

    def call(input : Input, db : Punch::Writer, events : Punch::Events(Punch::Auth::PasswordChanged | Punch::Auth::SessionRevoked)) : Output
      user_id, email = LinkStore.holder(Punch::Auth::OneTimeTokens.consume(db, Links::PASSWORD_RESET, input.token), db) || return LinkExpired.new
      Punch::Auth::Passwords.set(db, user_id, input.password.hashed)
      Punch::Auth::EmailIdentities.verify(db, email)
      Punch::Auth::Sessions.revoke_all(db, user_id.value)
      Punch::Auth::APITokens.revoke_all(db, user_id.value)
      events.publish(Punch::Auth::PasswordChanged.new(user_id.value, true))
      events.publish(Punch::Auth::SessionRevoked.new(user_id.value, nil, "password_reset"))
      ResetDone.new
    end
  end
end
