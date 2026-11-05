require "../../src/punch"

module Logins
  @[Punch::Public]
  @[Punch::RateLimitExempt("spec")]
  @[Punch::Idempotency(scope: :ip)]
  struct Create < Punch::Command
    struct Input
      include Punch::Input
    end

    def call(input : Input, db : Punch::Writer, auth : Punch::Auth::Authentication) : Nil
    end
  end
end

Punch::Routing::Router.new(Punch::Database.memory)
