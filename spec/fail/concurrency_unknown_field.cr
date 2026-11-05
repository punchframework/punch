require "../../src/punch"

@[Punch::Job::Concurrency(1, by: :customer_id)]
struct Report
  include Punch::Job

  getter account_id : Int64

  def initialize(@account_id)
  end

  def perform(job : Punch::Job::Context) : Punch::Job::Result
  end
end
