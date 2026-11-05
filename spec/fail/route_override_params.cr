require "../../src/punch"

@[Punch::Route("POST", "/hooks/:provider")]
@[Punch::Public]
@[Punch::RateLimitExempt("a fixture")]
struct Hook < Punch::Command
  struct Input
    include Punch::Input
    @[Punch::PathParam]
    getter source : String
  end

  def call(input : Input, db : Punch::Writer) : Nil
  end
end

Punch::Routing.routes
