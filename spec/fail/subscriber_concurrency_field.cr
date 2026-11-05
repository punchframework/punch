require "../../src/punch"

struct NoteAdded
  include Punch::Event

  getter note_id : Int64

  def initialize(@note_id)
  end
end

@[Punch::Subscriber::Delivery(:deferred)]
@[Punch::Job::Concurrency(1, by: :customer_id)]
struct Mailer
  include Punch::Subscriber(NoteAdded)

  def call(event : NoteAdded, job : Punch::Job::Context) : Punch::Job::Result
  end
end

Punch::Job::Queue::Registry.runners
