require "../../src/punch"

struct Actor
  include Punch::Auth::Actor

  def self.load(principal : Punch::Auth::Principal, db : Punch::Reader | Punch::Writer) : self?
    new
  end
end

@[Punch::Public]
@[Punch::RateLimitExempt("a fixture")]
struct ChangePassword < Punch::Command
  struct Input
    include Punch::Input
    getter current_password : Punch::Auth::Password
  end

  def call(input : Input, db : Punch::Writer, actor : Actor, password : Punch::Auth::OwnPasswordCheck) : Nil
  end
end

Punch::Routing::Router.new(Punch::Database.memory)
