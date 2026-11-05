require "../../src/punch"

struct Member
  include Punch::Auth::Actor

  def self.load(principal : Punch::Auth::Principal, db : Punch::Reader | Punch::Writer) : self?
    new
  end
end

module Notes
  @[Punch::Authorize(Punch::SignedIn)]
  @[Punch::RateLimitExempt("a fixture")]
  struct Archive < Punch::Command
    struct Input
      include Punch::Input
    end

    def call(input : Input, db : Punch::Writer, actor : Member, grant : Punch::Grant(Purge)) : Nil
    end
  end

  @[Punch::Authorize(Punch::SignedIn)]
  @[Punch::RateLimitExempt("a fixture")]
  struct Purge < Punch::Command
    struct Input
      include Punch::Input
    end

    def call(input : Input, db : Punch::Writer, actor : Member, grant : Punch::Grant(Purge)) : Nil
    end
  end
end

Punch::Routing::Router.new(Punch::Database.memory)
