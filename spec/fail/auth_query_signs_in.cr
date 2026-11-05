require "../../src/punch"

module Accounts
  @[Punch::Public]
  struct Peek < Punch::Query
    struct Input
      include Punch::Input
    end

    def call(input : Input, db : Punch::Reader, auth : Punch::Auth::Authentication) : Nil
    end
  end
end

Punch::Routing::Router.new(Punch::Database.memory)
