require "../../src/punch"

module Teams
  struct ID < Punch::TypedID
  end
end

module Projects
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

struct Member
  include Punch::Role
  scope Teams::ID
  permits Notes::Index
end

Punch::Database.memory.write do |db|
  Punch::Roles.assign(db, 1_i64, Member, on: Projects::ID.parse(1).as(Projects::ID))
end
