require "../../src/punch"

struct Export
  include Punch::Job

  def perform(job : Punch::Job::Context) : Punch::Job::Result
  end
end
