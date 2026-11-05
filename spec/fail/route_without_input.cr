require "../../src/punch"

@[Punch::Public]
struct Ping < Punch::Query
  def call(input, db : Punch::Reader) : Nil
  end
end

Punch::Routing.routes
