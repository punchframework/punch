require "../../src/punch"

@[Punch::Status(201)]
struct Created
  include JSON::Serializable
  include Punch::HTTP::Versioned

  getter revision = 1_i64

  def initialize
  end

  def version : Int64
    revision
  end
end

@[Punch::Public]
@[Punch::RateLimitExempt("a fixture")]
struct Make < Punch::Command
  struct Input
    include Punch::Input
  end

  def call(input : Input, db : Punch::Writer) : Created
    Created.new
  end
end

Punch::Routing::Router.new(Punch::Database.memory)
