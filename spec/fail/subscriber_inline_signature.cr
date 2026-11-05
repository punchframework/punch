require "../../src/punch"

struct NoteAdded
  include Punch::Event

  def initialize
  end
end

@[Punch::Subscriber::Delivery(:inline)]
struct Projection
  include Punch::Subscriber(NoteAdded)

  def call(event : NoteAdded) : Nil
  end
end
