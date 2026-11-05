require "../../src/punch"

struct Export
  include Punch::Job::Stepped

  def initialize
  end

  @[Punch::Job::Step]
  def copy(job : Punch::Job::Context) : Punch::Job::StepResult
  end
end
