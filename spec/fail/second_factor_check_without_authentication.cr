require "../../src/punch"

@[Punch::Public]
@[Punch::RateLimit(5, per: 15.minutes, by: :challenge)]
struct Complete < Punch::Command
  struct Input
    include Punch::Input
    getter code : Punch::Auth::OneTimeCode
  end

  def call(input : Input, db : Punch::Writer, second_factor : Punch::Auth::SecondFactorCheck) : Nil
  end
end

Punch::Routing::Router.new(Punch::Database.memory)
