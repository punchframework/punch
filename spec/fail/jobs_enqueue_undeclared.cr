require "../../src/punch"

struct Remind
  include Punch::Job

  def initialize
  end

  def perform(job : Punch::Job::Context) : Punch::Job::Result
  end
end

struct Export
  include Punch::Job

  def initialize
  end

  def perform(job : Punch::Job::Context) : Punch::Job::Result
  end
end

module Notes
  @[Punch::Public]
  @[Punch::RateLimitExempt("a fixture")]
  struct Create < Punch::Command
    struct Input
      include Punch::Input
    end

    def call(input : Input, db : Punch::Writer, jobs : Punch::Jobs(Remind)) : Nil
      jobs.enqueue(Export.new)
    end
  end
end

Punch::Routing::Router.new(Punch::Database.memory)
