require "../../src/punch"

# A failure result's fields become Problem Details members; `status` is one.
@[Punch::Status(409)]
struct Conflict
  include JSON::Serializable
  getter status : String = "taken"

  def initialize
  end
end

@[Punch::Public]
@[Punch::RateLimitExempt("a fixture")]
struct Claim < Punch::Command
  struct Input
    include Punch::Input
  end

  def call(input : Input, db : Punch::Writer) : Conflict
    Conflict.new
  end
end

Punch::Routing::Router.new(Punch::Database.memory)
