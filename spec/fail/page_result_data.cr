require "../../src/punch"

struct Note
  include JSON::Serializable
  getter title = "x"

  def initialize
  end
end

@[Punch::Public]
struct NotePage < Punch::Page
  struct Input
    include Punch::Input
  end

  def call(input : Input, db : Punch::Reader) : Note
    Note.new
  end
end

Punch::Routing.routes.first.handler
