module Billing::Customers
  # Customers found by a name prefix.
  struct Matches
    include JSON::Serializable

    getter customers : Array(Customer)

    def initialize(@customers : Array(Customer))
    end
  end

  # Finds the customers of the organization the actor works in whose name starts with `q`, in any case and script
  # (`ä` finds `Ärger`), sorted by name as German readers expect.
  @[Punch::Authorize(Accounts::Organizations::Current)]
  struct Search < Punch::Query
    struct Input
      include Punch::Input

      getter q : Punch::NonEmptyString
      getter limit : Punch::PageSize = Punch::PageSize.of(20)
    end

    alias Output = Matches

    def call(input : Input, db : Punch::Reader, actor : Invoicing::Actor) : Output
      # The prefix is text, not a pattern: `%` and `_` in it match themselves.
      prefix = Punch::LikeText.new(input.q.value)
      Matches.new(Queries.search(db, organization_id: actor.organization_id, prefix: prefix, limit: input.limit.to_i.to_i64).map { |record| Customer.new(record) })
    end
  end
end
