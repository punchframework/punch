require "../../src/punch"

module Invoices
  @[Punch::Public]
  struct Create < Punch::Query
    struct Input
      include Punch::Input
    end

    def call(input : Input, db : Punch::Reader) : Nil
    end
  end
end

Punch::Routing.routes
