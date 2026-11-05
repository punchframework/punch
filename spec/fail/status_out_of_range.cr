require "../../src/punch"

@[Punch::Status(99)]
struct Odd
  include JSON::Serializable

  def initialize
  end
end

@[Punch::Public]
struct Ping < Punch::Query
  struct Input
    include Punch::Input
  end

  def call(input : Input, db : Punch::Reader) : Odd
    Odd.new
  end
end

Punch::Routing::Router.new(Punch::Database.memory)
