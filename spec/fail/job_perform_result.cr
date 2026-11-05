require "../../src/punch"

struct Export
  include Punch::Job

  def initialize
  end

  def perform(job : Punch::Job::Context)
    "done"
  end
end

Punch::Job::Queue::Registry.runners
