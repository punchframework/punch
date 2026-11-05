require "../../src/punch"

@[Punch::Payloads::Version(2, from: {1 => Export::V1})]
struct Export
  include Punch::Job

  getter account_id : Int64

  def initialize(@account_id)
  end

  def perform(job : Punch::Job::Context) : Punch::Job::Result
  end

  struct V1
    include Punch::Payloads::Frozen

    getter account : Int64
  end
end
