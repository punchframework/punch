require "../../src/punch"

module Accounts
  @[Punch::Public]
  @[Punch::RateLimitExempt("a fixture")]
  struct Rename < Punch::Command
    struct Input
      include Punch::Input
    end

    def call(input : Input, db : Punch::Writer, actor) : Nil
    end
  end
end

Punch::Routing::Router.new(Punch::Database.memory)
