require "../../src/punch"

@[Punch::Payloads::Version(2, from: {1 => V1})]
struct Export
  include Punch::Job

  getter account_id : Int64

  def initialize(@account_id)
  end

  def perform(job : Punch::Job::Context) : Punch::Job::Result
  end

  struct V1
    include JSON::Serializable

    getter account : Int64
  end
end
