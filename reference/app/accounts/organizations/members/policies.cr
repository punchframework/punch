module Accounts::Organizations::Members
  # Removing a member: whoever's role permits it (administrators), and any
  # member removing themselves, which is leaving.
  struct Removal
    include Punch::Policy

    def self.check(actor : Invoicing::Actor, db : Punch::Reader | Punch::Writer, operation : Punch::Operation.class, *,
                   organization_id : ID, user_id : Users::ID) : Punch::Policy::Decision
      decision = Punch::Roles.check(db, actor.user.id, operation, on: organization_id)
      decision.forbid? && user_id == actor.user.id ? allow : decision
    end
  end
end
