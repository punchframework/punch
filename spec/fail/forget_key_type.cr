require "../../src/punch"

struct NoteAdded
  include Punch::Event

  getter note_id : Int64
  getter body : String

  def initialize(@note_id, @body)
  end
end

BODIES = Punch::Cache(Int64, String).new("bodies", ttl: 1.minute)

@[Punch::Subscriber::Forget(BODIES, key: body)]
struct ForgetBody
  include Punch::Subscriber(NoteAdded)
end

module Notes
  @[Punch::Public]
  @[Punch::RateLimitExempt("a fixture")]
  struct Create < Punch::Command
    struct Input
      include Punch::Input
    end

    def call(input : Input, db : Punch::Writer, events : Punch::Events(NoteAdded)) : Nil
      events.publish(NoteAdded.new(1, "a"))
    end
  end
end

Punch::Routing::Router.new(Punch::Database.memory)
