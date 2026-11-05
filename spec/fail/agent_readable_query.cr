require "../../src/punch"

module Reports
  @[Punch::AgentReadable]
  @[Punch::Public]
  struct Index < Punch::Query
    struct Input
      include Punch::Input
    end

    def call(input : Input, db : Punch::Reader) : Nil
    end
  end
end

Punch::Routing.routes
