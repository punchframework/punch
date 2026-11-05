require "../../src/punch"

module Invoices
  @[Punch::Public]
  struct Purge < Punch::Query
    struct Input
      include Punch::Input
    end

    def call(input : Input, db : Punch::Writer) : Nil
    end
  end
end

Punch::Routing::Router.new(Punch::Database.memory)
