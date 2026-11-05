require "../../src/punch"

struct Export
  include Punch::Job
  include Punch::Job::Stepped

  def initialize
  end

  @[Punch::Job::Step]
  def copy(job : Punch::Job::Context, rows : Punch::Job::Cursor(Int64)) : Punch::Job::StepResult
    rows.continue("page-2")
  end
end

Punch::Job::Queue::Registry.runners
