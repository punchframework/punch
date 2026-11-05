require "../../src/punch"

struct NoteAdded
  include Punch::Event

  def initialize
  end
end

@[Punch::Job::Options(queue: "mail")]
struct Mailer
  include Punch::Subscriber(NoteAdded)

  def call(event : NoteAdded) : Nil
  end
end
