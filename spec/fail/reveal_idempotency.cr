require "../../src/punch"

struct Actor
  include Punch::Auth::Actor
  getter principal : Punch::Auth::Principal

  def initialize(@principal)
  end

  def self.load(principal : Punch::Auth::Principal, db : Punch::Reader | Punch::Writer) : self?
    new(principal)
  end
end

module Tokens
  # The stored answer would hold the token.
  @[Punch::Idempotency(:required)]
  @[Punch::Public]
  @[Punch::RateLimitExempt("a fixture")]
  struct Create < Punch::Command
    struct Input
      include Punch::Input
    end

    def call(input : Input, db : Punch::Writer, actor : Actor, reveal : Punch::Auth::Reveal) : Nil
    end
  end
end

Punch::Routing.routes
