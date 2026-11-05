module Billing::Invoices
  @[Punch::Status(201)]
  record Created,
    invoice : Detail do
    include JSON::Serializable
  end

  # The customer named in the request does not exist.
  @[Punch::Status(422)]
  struct UnknownCustomer
    include Punch::Problem
  end

  # Starts a draft for a customer of the organization the actor works in.
  # Another organization's customer is unknown, like one that does not
  # exist, even where the actor is a member: drafts go into the current
  # organization only.
  @[Punch::Authorize(Accounts::Organizations::Current)]
  struct Create < Punch::Command
    struct Input
      include Punch::Input

      getter customer_id : Customers::ID
      getter currency : Punch::Currency
      getter lines : Array(LineInput) = [] of LineInput

      def check(errors : Punch::Rejection::Collector) : Nil
        Invoices.check_lines(lines, errors)
      end
    end

    alias Output = Created | UnknownCustomer

    def call(input : Input, db : Punch::Writer, actor : Invoicing::Actor, _grant : Punch::Grant(Create),
             events : Punch::Events(InvoiceDrafted)) : Output
      # The customer is in the body, which no policy sees.
      organization_id = actor.organization_id
      return UnknownCustomer.new unless Customers::Queries.organization(db, customer_id: input.customer_id).try(&.organization_id) == organization_id

      now = Time.utc
      draft = Store.create(db, organization_id: organization_id, customer_id: input.customer_id, currency: input.currency, lines: input.lines.map(&.to_line), at: now)
      events.publish(InvoiceDrafted.new(draft.id, organization_id))
      Created.new(Store.detail(db, draft, now))
    end
  end
end
