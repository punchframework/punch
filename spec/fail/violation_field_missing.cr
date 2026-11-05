require "../../src/punch"

module Tags
  struct NameTaken
    include Punch::Database::Violation

    CONSTRAINT = "tags.name"
    FIELD      = "name"
    MESSAGE    = "UNIQUE constraint failed: tags.name"
  end

  # The input calls the name `title`: the violation must be mapped.
  @[Punch::Public]
  @[Punch::RateLimitExempt("a fixture")]
  struct Rename < Punch::Command
    struct Input
      include Punch::Input
      getter title : String
    end

    def call(input : Input, db : Punch::Writer) : Nil | NameTaken
      NameTaken.new
    end
  end
end

Punch::Routing::Router.new(Punch::Database.memory)
