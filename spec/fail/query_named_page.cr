require "../../src/punch"

module Notes
  @[Punch::Public]
  struct ListPage < Punch::Query
    struct Input
      include Punch::Input
    end

    def call(input : Input, db : Punch::Reader) : Nil
    end
  end
end

Punch::Routing.routes
