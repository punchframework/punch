require "../../src/punch"

module Invoices
  @[Punch::Public]
  struct Show < Punch::Query
    struct Input
      include Punch::Input
      @[Punch::PathParam]
      getter invoice_id : Int64
    end

    def call(input : Input, db : Punch::Reader) : Nil
    end
  end
end

Invoices::Show.path(invoice_id: 1_i64, id: 2)
