require "../../src/punch"
require "../query_gen/fixture/app/ledger/types"
require "../query_gen/fixture/app/ledger/customers/record"
require "../query_gen/fixture/app/ledger/columns"
require "../query_gen/fixture/app/ledger/records.gen"

# A generated `Record` is a database row, not a wire type: returning one in
# a result does not compile, and says what to return instead.
module Customers
  struct Found
    include JSON::Serializable
    getter customer : Ledger::Customers::Record

    def initialize(@customer : Ledger::Customers::Record)
    end
  end

  @[Punch::Public]
  struct Index < Punch::Query
    struct Input
      include Punch::Input
    end

    def call(input : Input, db : Punch::Reader) : Found
      raise "never run"
    end
  end
end

Punch::Routing::Router.new(Punch::Database.memory)
Punch::Routing.render(Customers::Found.allocate, Punch::HTTP::Context.allocate)
