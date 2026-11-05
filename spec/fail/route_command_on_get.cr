require "../../src/punch"

@[Punch::Route("GET", "/logout")]
@[Punch::Public]
@[Punch::RateLimitExempt("a fixture")]
struct Logout < Punch::Command
  struct Input
    include Punch::Input
  end

  def call(input : Input, db : Punch::Writer) : Nil
  end
end

Punch::Routing.routes
