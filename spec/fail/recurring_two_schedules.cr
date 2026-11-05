require "../../src/punch"

@[Punch::Job::Recurring(cron: "0 3 * * *", every: 1.hour)]
struct Report
  include Punch::Job

  def initialize
  end

  def perform(job : Punch::Job::Context) : Punch::Job::Result
  end
end
