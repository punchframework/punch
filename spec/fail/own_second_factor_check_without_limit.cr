require "../../src/punch"

struct Actor
  include Punch::Auth::Actor

  def self.load(principal : Punch::Auth::Principal, db : Punch::Reader | Punch::Writer) : self?
    new
  end
end

@[Punch::Authorize(Punch::SignedIn)]
@[Punch::RateLimitExempt("a fixture")]
struct Reauthenticate < Punch::Command
  struct Input
    include Punch::Input
    getter code : Punch::Auth::OneTimeCode
  end

  def call(input : Input, db : Punch::Writer, actor : Actor, _grant : Punch::Grant(Reauthenticate), second_factor : Punch::Auth::OwnSecondFactorCheck) : Nil
  end
end

Punch::Routing::Router.new(Punch::Database.memory)
