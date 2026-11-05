require "../../src/punch"

module Notes
  @[Punch::Public]
  @[Punch::RateLimitExempt("spec")]
  @[Punch::Idempotency(:required)]
  struct Create < Punch::Command
    struct Input
      include Punch::Input
    end

    def call(input : Input, db : Punch::Writer) : Nil
    end
  end
end

Punch::Routing::Router.new(Punch::Database.memory)
