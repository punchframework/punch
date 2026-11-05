require "../../src/punch"

@[Punch::Public]
@[Punch::RateLimitExempt("a fixture")]
struct Complete < Punch::Command
  struct Input
    include Punch::Input
    getter code : Punch::Auth::OneTimeCode
  end

  def call(input : Input, db : Punch::Writer, auth : Punch::Auth::Authentication, second_factor : Punch::Auth::SecondFactorCheck) : Nil
  end
end

Punch::Routing::Router.new(Punch::Database.memory)
