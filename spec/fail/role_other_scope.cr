require "../../src/punch"

module Teams
  struct ID < Punch::TypedID
  end
end

module Notes
  @[Punch::Public]
  struct Index < Punch::Query
    struct Input
      include Punch::Input
    end

    def call(input : Input, db : Punch::Reader) : Nil
    end
  end
end

struct Auditor
  include Punch::Role
  permits Notes::Index
end

struct Member
  include Punch::Role
  scope Teams::ID
  permits Auditor
end

Punch::Roles.definitions
