module Billing::Customers
  # One page of customers.
  struct Page
    include JSON::Serializable

    getter customers : Array(Customer)
    # Pass as `after` for the next page; absent on the last one.
    getter next_after : Queries::Page::Cursor?

    def initialize(page : Punch::Paged(Record, Queries::Page::Cursor))
      @customers = page.map { |record| Customer.new(record) }
      @next_after = page.next_after
    end
  end

  # Lists the customers of the organization the actor works in, in the
  # order they were created, or by name; `filter[tax_id]` finds the one
  # with that tax number.
  @[Punch::Authorize(Accounts::Organizations::Current)]
  struct Index < Punch::Query
    struct Input
      include Punch::Input

      getter filter : Queries::Page::Filter = Queries::Page::Filter.new
      getter order : Queries::Page::Order = Queries::Page::Order::Created
      getter direction : Punch::Database::Direction = Punch::Database::Direction::Asc
      # Where the page starts: `next_after` of the one before. It continues
      # in the order and direction it was made in.
      getter after : Queries::Page::Cursor?
      getter limit : Punch::PageSize = Punch::PageSize.of(50)
    end

    alias Output = Page

    def call(input : Input, db : Punch::Reader, actor : Invoicing::Actor) : Output
      Page.new(Queries.page(db, organization_id: actor.organization_id, filter: input.filter, order: input.order, direction: input.direction, after: input.after, limit: input.limit))
    end
  end
end
