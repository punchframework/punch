module Accounts::Organizations::Members
  struct List
    include JSON::Serializable

    getter members : Array(Membership)

    def initialize(@members : Array(Membership))
    end
  end

  # Who belongs to the organization, in which role, and until when;
  # expired roles are left out.
  @[Punch::Authorize(ByRole)]
  struct Index < Punch::Query
    struct Input
      include Punch::Input

      @[Punch::PathParam]
      getter organization_id : ID
    end

    alias Output = List

    def call(input : Input, db : Punch::Reader, _actor : Invoicing::Actor) : Output
      List.new(Store.members(db, input.organization_id))
    end
  end
end
