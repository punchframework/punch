require "../../src/punch"

module Invoices
  @[Punch::Public]
  @[Punch::RateLimitExempt("a fixture")]
  struct Index < Punch::Command
    struct Input
      include Punch::Input
    end

    def call(input : Input, db : Punch::Writer) : Nil
    end
  end
end

Punch::Routing.routes
