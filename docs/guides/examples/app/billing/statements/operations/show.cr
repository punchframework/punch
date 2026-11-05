module Billing::Statements
  @[Punch::Authorize(Own)]
  struct Show < Punch::Query
    struct Input
      include Punch::Input

      @[Punch::PathParam]
      getter statement_id : ID
    end

    alias Output = Detail | NotFound

    def call(input : Input, db : Punch::Reader, _actor : Examples::Actor) : Output
      statement = Table.find(db, input.statement_id)
      statement ? Detail.of(statement) : NotFound.new
    end
  end
end
