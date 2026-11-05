require "../../src/punch"

struct NoteAdded
  include Punch::Event

  getter note_id : Int64
  getter body : String

  def initialize(@note_id, @body)
  end
end

BODIES = Punch::Cache(Int64, String).new("bodies", ttl: 1.minute)

@[Punch::Subscriber::Forget(BODIES, key: id)]
struct ForgetBody
  include Punch::Subscriber(NoteAdded)
end
