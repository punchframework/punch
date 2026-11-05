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
  # Only a Command shows a secret once.
  @[Punch::Public]
  struct Index < Punch::Query
    struct Input
      include Punch::Input
    end

    def call(input : Input, db : Punch::Reader, actor : Actor, reveal : Punch::Auth::Reveal) : Nil
    end
  end
end

Punch::Routing.routes
