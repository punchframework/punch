module Accounts::Emails
  # Removes one of the user's addresses, unless it is their last way to
  # sign in (409 `last_sign_in_method`, checked by Punch in this
  # transaction); the removed address is told (`EmailRemoved`). Needs a
  # recent sign-in.
  @[Punch::Authorize(OwnRecent)]
  struct Destroy < Punch::Command
    struct Input
      include Punch::Input

      @[Punch::PathParam]
      getter email_id : Int64
    end

    alias Output = Punch::Auth::LastSignInMethod?

    def call(input : Input, db : Punch::Writer, actor : Examples::Actor, _grant : Punch::Grant(Destroy),
             events : Punch::Events(EmailRemoved)) : Output
      case removed = Punch::Auth::EmailIdentities.remove(db, actor.user.id, input.email_id)
      in Punch::Auth::LastSignInMethod then removed
      in Nil                           then nil # the policy found it; gone meanwhile
      in Punch::Auth::EmailIdentity
        events.publish(EmailRemoved.new(actor.user.id.value, removed.email))
        nil
      end
    end
  end
end
