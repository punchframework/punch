require "../../src/punch"

struct NoteAdded
  include Punch::Event

  def initialize
  end
end

struct Mailer
  include Punch::Subscriber(String)

  def call(event : String) : Nil
  end
end
