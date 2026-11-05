require "../../src/punch"

struct Export
  include Punch::Job
  include JSON::Serializable::Strict

  getter account_id : Int64

  def initialize(@account_id)
  end

  def perform(job : Punch::Job::Context) : Punch::Job::Result
  end
end
