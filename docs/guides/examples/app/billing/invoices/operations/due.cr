module Billing::Invoices
  # Unpaid invoices due in a period, by due date.
  @[Punch::Status(200)]
  record DueInvoices,
    invoices : Array(Detail) do
    include JSON::Serializable
  end

  # The unpaid invoices due from `from` and before `before`: a forecast
  # of what comes in.
  @[Punch::Authorize(Punch::SignedIn)]
  struct Due < Punch::Query
    struct Input
      include Punch::Input

      getter from : Time
      getter before : Time

      # Runs once both fields have parsed.
      def check(errors : Punch::Rejection::Collector) : Nil
        errors.add("before", Punch::Invalid.new("before_start")) unless from < before
      end
    end

    alias Output = DueInvoices

    def call(input : Input, db : Punch::Reader, _actor : Examples::Actor) : Output
      rows = Queries.due_between(db, from: input.from, before: input.before)
      DueInvoices.new(rows.map { |row| Detail.new(row.id, row.number, row.customer_email, row.due_at, row.paid_at) })
    end
  end
end
