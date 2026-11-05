require "../../src/punch"

@[Punch::Public]
@[Punch::RateLimit(5, per: 15.minutes, by: :challenge)]
struct Guess < Punch::Command
  struct Input
    include Punch::Input
  end

  def call(input : Input, db : Punch::Writer) : Nil
  end
end

Punch::Routing::Router.new(Punch::Database.memory)
