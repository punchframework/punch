require "../../src/punch"

module Notes
  @[Punch::Status(200)]
  struct Added
    include JSON::Serializable

    def initialize
    end
  end

  # The failure forgot its status: it would answer 200 and commit.
  struct Missing
    include JSON::Serializable

    def initialize
    end
  end

  @[Punch::Public]
  @[Punch::RateLimitExempt("a fixture")]
  struct Create < Punch::Command
    struct Input
      include Punch::Input
    end

    def call(input : Input, db : Punch::Writer) : Added | Missing
      rand < 0.5 ? Added.new : Missing.new
    end
  end
end

Punch::Routing::Router.new(Punch::Database.memory)
