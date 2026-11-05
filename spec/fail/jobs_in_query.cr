require "../../src/punch"

struct Remind
  include Punch::Job

  def initialize
  end

  def perform(job : Punch::Job::Context) : Punch::Job::Result
  end
end

module Notes
  @[Punch::Public]
  struct Index < Punch::Query
    struct Input
      include Punch::Input
    end

    def call(input : Input, db : Punch::Reader, jobs : Punch::Jobs(Remind)) : Nil
    end
  end
end

Punch::Routing::Router.new(Punch::Database.memory)
