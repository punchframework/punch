require "../../src/punch"

struct NoteAdded
  include Punch::Event

  def initialize
  end

  property body : String = ""
end
