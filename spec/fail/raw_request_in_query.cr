require "../../src/punch"

module Notes
  @[Punch::Public]
  struct Index < Punch::Query
    struct Input
      include Punch::Input
    end

    def call(input : Input, db : Punch::Reader, request : Punch::RawRequest) : Nil
    end
  end
end

Punch::Routing::Router.new(Punch::Database.memory)
