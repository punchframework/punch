require "../../src/punch"

@[Punch::Job::Recurring(every: 1.hour)]
struct Report
  include Punch::Job

  getter account_id : Int64

  def initialize(@account_id)
  end

  def perform(job : Punch::Job::Context) : Punch::Job::Result
  end
end

Punch::Job::Queue.tasks
