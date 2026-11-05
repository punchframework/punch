require "../../src/punch"

@[Punch::Job::Options(queue: "Mail")]
struct Export
  include Punch::Job

  def initialize
  end

  def perform(job : Punch::Job::Context) : Punch::Job::Result
  end
end
