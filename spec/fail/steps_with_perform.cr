require "../../src/punch"

struct Export
  include Punch::Job
  include Punch::Job::Stepped

  def initialize
  end

  @[Punch::Job::Step]
  def copy(job : Punch::Job::Context) : Punch::Job::StepResult
  end

  def perform(job : Punch::Job::Context) : Punch::Job::Result
  end
end
