require "../../src/punch"

# Version 2 upgrades to version 1: the chain must move forward.
@[Punch::Payloads::Version(3, from: {1 => V1, 2 => V2})]
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

    def upgrade : V2
      V2.from_json(to_json)
    end
  end

  struct V2
    include Punch::Payloads::Frozen

    getter account : Int64

    def upgrade : V1
      V1.from_json(to_json)
    end
  end
end
