module Billing::Profiles
  # The billing profile of the organization the actor works in.
  @[Punch::Authorize(Accounts::Organizations::Current)]
  struct Show < Punch::Query
    struct Input
      include Punch::Input
    end

    alias Output = Profile | NoProfile

    def call(input : Input, db : Punch::Reader, actor : Invoicing::Actor) : Output
      organization = actor.organization || return NoProfile.new
      record = Table.find(db, organization.id)
      record ? Profile.new(record) : NoProfile.new
    end
  end
end
