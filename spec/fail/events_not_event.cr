require "../../src/punch"

struct NoteAdded
  include Punch::Event

  def initialize
  end
end

module Notes
  @[Punch::Public]
  @[Punch::RateLimitExempt("a fixture")]
  struct Create < Punch::Command
    struct Input
      include Punch::Input
    end

    def call(input : Input, db : Punch::Writer, events : Punch::Events(NoteAdded | String)) : Nil
    end
  end
end

Punch::Routing::Router.new(Punch::Database.memory)
