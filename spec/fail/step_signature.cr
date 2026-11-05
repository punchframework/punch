require "../../src/punch"

struct Export
  include Punch::Job
  include Punch::Job::Stepped

  def initialize
  end

  @[Punch::Job::Step]
  def copy(job : Punch::Job::Context, after : Int64?) : Punch::Job::StepResult
  end
end
