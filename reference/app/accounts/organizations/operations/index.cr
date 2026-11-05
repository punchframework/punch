module Accounts::Organizations
  struct List
    include JSON::Serializable

    getter organizations : Array(Organization)

    def initialize(@organizations : Array(Organization))
    end
  end

  # The organizations the user holds a role on, by name, and which one the
  # session or token works in.
  @[Punch::Authorize(Punch::SignedIn)]
  struct Index < Punch::Query
    struct Input
      include Punch::Input
    end

    alias Output = List

    def call(input : Input, db : Punch::Reader, actor : Invoicing::Actor) : Output
      current = actor.organization.try(&.id)
      List.new(Queries.mine(db, user_id: actor.user.id.value).map { |record| Organization.new(record, record.id == current) })
    end
  end
end
