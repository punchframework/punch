require "../../src/punch"

struct Member
  include Punch::Auth::Actor

  def self.load(principal : Punch::Auth::Principal, db : Punch::Reader | Punch::Writer) : self?
    new
  end
end

module Notes
  @[Punch::Authorize(Punch::SignedIn)]
  @[Punch::Public]
  struct Index < Punch::Query
    struct Input
      include Punch::Input
    end

    def call(input : Input, db : Punch::Reader, actor : Member) : Nil
    end
  end
end

Punch::Routing::Router.new(Punch::Database.memory)
