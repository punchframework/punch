require "../../src/punch"

module Notes
  @[Punch::Public]
  struct Create < Punch::Command
    struct Input
      include Punch::Input
    end

    def call(input : Input, db : Punch::Writer) : Nil
    end
  end
end

Punch::Routing::Router.new(Punch::Database.memory)
