require "../../src/punch"

module Notes
  @[Punch::Public]
  @[Punch::Idempotency(:required)]
  struct Index < Punch::Query
    struct Input
      include Punch::Input
    end

    def call(input : Input, db : Punch::Reader) : Nil
    end
  end
end

Punch::Routing::Router.new(Punch::Database.memory)
