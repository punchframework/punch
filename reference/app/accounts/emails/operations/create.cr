module Accounts::Emails
  @[Punch::Status(201)]
  record Added,
    address : Address do
    include JSON::Serializable
  end

  # Adds an address to the signed-in user, unverified until its owner
  # follows the link mailed to it; the user's other addresses are told
  # (`EmailAdded`). Needs a recent authentication.
  @[Punch::Authorize(Punch::RecentlyAuthenticated)]
  @[Punch::RateLimit(10, per: 1.hour, by: :actor)]
  struct Create < Punch::Command
    struct Input
      include Punch::Input

      getter email : Punch::Email
    end

    alias Output = Added | Punch::Auth::EmailIdentities::EmailTaken

    def call(input : Input, db : Punch::Writer, actor : Invoicing::Actor, _grant : Punch::Grant(Create),
             events : Punch::Events(EmailAdded)) : Output
      case identity = Punch::Auth::EmailIdentities.add(db, actor.user.id, input.email)
      in Punch::Auth::EmailIdentities::EmailTaken then identity
      in Punch::Auth::EmailIdentity
        events.publish(EmailAdded.new(actor.user.id.value, identity.email))
        Added.new(Address.new(identity))
      end
    end
  end
end
