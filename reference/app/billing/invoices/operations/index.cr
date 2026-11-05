module Billing::Invoices
  # Lists the invoices of the organization the actor works in, in the
  # order they were created; of one customer, in one state, or matching a
  # search (an invoice number's start, or part of the customer's name).
  @[Punch::Authorize(Accounts::Organizations::Current)]
  struct Index < Punch::Query
    struct Input
      include Punch::Input

      # What narrows the list: the query's filter object, read from
      # `filter[customer_id]`, `filter[status]`, and `filter[q]`, and
      # usable without a request (spec/billing/invoice_queries_spec.cr).
      getter filter : Queries::Page::Filter = Queries::Page::Filter.new
      # Where the page starts: `next_after` of the one before.
      getter after : Queries::Page::Cursor?
      getter limit : Punch::PageSize = Punch::PageSize.of(50)
    end

    alias Output = Page

    def call(input : Input, db : Punch::Reader, actor : Invoicing::Actor) : Output
      now = Time.utc
      page = Queries.page(db, organization_id: actor.organization_id, filter: input.filter, after: input.after, limit: input.limit)
      Page.new(page.map { |row| Summary.new(row, now) }, page.next_after)
    end

    # Invoice *id* as this list shows it, or `nil` when it is not in the
    # actor's organization or does not match the filter: for a list that
    # is open when the invoice changes (`IndexPage#live`).
    def self.listed(db : Punch::Reader, id : ID, input : Input, actor : Invoicing::Actor) : Summary?
      row = Queries.page_by_key(db, key: id, organization_id: actor.organization_id, filter: input.filter) || return
      Summary.new(row, Time.utc)
    end
  end
end
