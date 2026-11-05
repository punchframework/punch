require "../../src/punch"

struct NoteAdded
  include Punch::Event

  def initialize
  end
end

struct Projection
  include Punch::Subscriber(NoteAdded)

  def call(event : NoteAdded, db : Punch::Writer) : Nil
  end
end
