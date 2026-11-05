require "../../src/punch"

module Accounts
  @[Punch::RateLimit(5, per: 1.minute, by: :nickname)]
  @[Punch::Public]
  struct SignIn < Punch::Command
    struct Input
      include Punch::Input
      getter email : String
    end

    def call(input : Input, db : Punch::Writer) : Nil
    end
  end
end

Punch::Routing::Router.new(Punch::Database.memory)
