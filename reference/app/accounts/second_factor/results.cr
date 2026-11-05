module Accounts::SecondFactor
  # The setup began: a browser goes on to `SetupPage`.
  @[Punch::Status(201)]
  struct Started
    include JSON::Serializable

    def initialize
    end
  end

  # The authenticator app counts from now on, or no longer.
  struct Changed
    include JSON::Serializable

    getter? enabled : Bool

    def initialize(@enabled)
    end
  end

  # New recovery codes wait on the account page until the user says they
  # saved them.
  @[Punch::Status(200)]
  struct CodesReplaced
    include JSON::Serializable

    def initialize
    end
  end
end

module Accounts::SecondFactor
  # 409 `not_set_up`: the user has no authenticator app.
  @[Punch::Status(409)]
  struct NotSetUp
    include Punch::Problem
  end
end
