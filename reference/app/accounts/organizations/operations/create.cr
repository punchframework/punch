module Accounts::Organizations
  @[Punch::Status(201)]
  record Created,
    organization : Organization do
    include JSON::Serializable
  end

  # Starts an organization. Its founder is its administrator, and the
  # session or token goes on to work in it.
  @[Punch::Authorize(Punch::SignedIn)]
  struct Create < Punch::Command
    struct Input
      include Punch::Input

      getter name : Punch::NonEmptyString
    end

    alias Output = Created

    def call(input : Input, db : Punch::Writer, actor : Invoicing::Actor, _grant : Punch::Grant(Create),
             events : Punch::Events(Punch::Roles::Assigned)) : Output
      organization, assigned = Store.found(db, input.name, actor.user, Time.utc)
      events.publish(Punch::Roles::Assigned.new(assigned))
      Store.choose(db, actor.principal, organization.id)
      Created.new(Organization.new(organization, current: true))
    end
  end
end
