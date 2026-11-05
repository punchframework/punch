require "../../src/punch"

struct Export
  include Punch::Job

  def initialize
  end

  def perform(job : Punch::Job::Context) : Punch::Job::Result
  end

  @[Punch::Job::Step]
  def copy(job : Punch::Job::Context) : Punch::Job::StepResult
  end
end
