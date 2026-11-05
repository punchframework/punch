module Billing::Customers
  # What a customer's sent invoices in one currency add up to.
  struct Balance
    include JSON::Serializable

    getter currency : Punch::Currency
    getter invoices : Int64
    # Unpaid invoices past their due date when the statement was computed.
    getter overdue : Int64
    # In the currency's minor units.
    getter total : Punch::Money
    # What is not paid yet, in minor units.
    getter outstanding : Punch::Money

    def initialize(row : Queries::Statement::Row)
      @currency = row.currency
      @invoices = row.invoices
      @overdue = row.overdue
      @total = Punch::Money.parse(row.total).as(Punch::Money)
      @outstanding = Punch::Money.parse(row.outstanding).as(Punch::Money)
    end
  end

  # A customer's balances per currency. Computing it adds up every line of
  # every sent invoice, so it is cached (`STATEMENTS`) and may be up to a
  # minute old; `as_of` says when it was computed. Repeated requests get
  # `304 Not Modified` while the balances are unchanged.
  @[Punch::Status(200)]
  struct Balances
    include JSON::Serializable
    include Punch::HTTP::Versioned

    getter customer_id : ID
    getter balances : Array(Balance)
    getter as_of : Time

    def initialize(@customer_id : ID, @balances : Array(Balance), @as_of : Time)
    end

    # The balances themselves: a recomputed statement with the same
    # numbers keeps its version.
    def version : String
      Digest::SHA256.hexdigest(balances.to_json)
    end
  end

  # Statements for a minute, in memory in front of cache.db. Sending an
  # invoice or its payment forgets its customer's entry (`ForgetStatement`,
  # on `BalanceChanged`).
  STATEMENTS = Punch::Cache(ID, Balances).new("customer_statements", ttl: 1.minute, tier: :both)

  # What a customer owes, per currency.
  @[Punch::Authorize(ByRole)]
  struct Statement < Punch::Query
    struct Input
      include Punch::Input

      @[Punch::PathParam]
      getter customer_id : ID
    end

    alias Output = Balances | NotFound

    def call(input : Input, db : Punch::Reader, _actor : Invoicing::Actor) : Output
      return NotFound.new unless Table.find(db, input.customer_id)

      STATEMENTS.fetch(input.customer_id) do
        now = Time.utc
        Balances.new(input.customer_id, Queries.statement(db, now: now, customer_id: input.customer_id).map { |row| Balance.new(row) }, now)
      end
    end
  end
end
