module Accounts::Passwords
  struct Changed
    include JSON::Serializable

    def initialize
    end
  end

  # Changes the signed-in user's password, given the current one (checked
  # by Punch before the transaction, `Punch::Auth::OwnPasswordCheck`). Every
  # other session ends, this one gets a new ID, and the user is told by
  # mail (lib/punch/docs/auth.md). With `revoke_tokens`, every API token
  # ends too.
  @[Punch::Authorize(Punch::SignedIn)]
  @[Punch::RateLimit(10, per: 15.minutes, by: :actor, store: :durable)]
  struct Change < Punch::Command
    struct Input
      include Punch::Input

      getter current_password : Punch::Auth::Password
      getter password : Punch::Auth::NewPassword
      getter? revoke_tokens : Bool = false
    end

    alias Output = Changed | Punch::Auth::InvalidCredentials

    def call(input : Input, db : Punch::Writer, actor : Invoicing::Actor, auth : Punch::Auth::Authentication, _grant : Punch::Grant(Change),
             password : Punch::Auth::OwnPasswordCheck, events : Punch::Events(Punch::Auth::PasswordChanged | Punch::Auth::SessionRevoked)) : Output
      return Punch::Auth::InvalidCredentials.new unless password.confirm(db)

      user_id = actor.user.id
      Punch::Auth::Passwords.set(db, user_id, input.password.hashed)
      Punch::Auth::Sessions.revoke_all(db, user_id.value, except: auth.session.try(&.id))
      Punch::Auth::APITokens.revoke_all(db, user_id.value) if input.revoke_tokens?
      auth.renew
      events.publish(Punch::Auth::PasswordChanged.new(user_id.value, false))
      events.publish(Punch::Auth::SessionRevoked.new(user_id.value, nil, "password_changed"))
      Changed.new
    end
  end
end
