require "../../src/punch"

struct NoteAdded
  include Punch::Event

  def initialize
  end
end

module Notes
  @[Punch::Public]
  struct Index < Punch::Query
    struct Input
      include Punch::Input
    end

    def call(input : Input, db : Punch::Reader, events : Punch::Events(NoteAdded)) : Nil
    end
  end
end

Punch::Routing::Router.new(Punch::Database.memory)
