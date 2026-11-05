module Accounts::Sessions
  # Who just signed in; a browser goes on to the home page.
  @[Punch::Status(200)]
  record SignedIn,
    user_id : Users::ID do
    include JSON::Serializable
  end

  # 403 `not_verified`: the password is right, but no address of the
  # account is verified yet. The link mailed at sign-up verifies it, and
  # so does a password reset link.
  @[Punch::Status(403)]
  struct NotVerified
    include Punch::Problem
  end

  # The session ended; a browser goes on to the sign-in page.
  @[Punch::Status(200)]
  struct SignedOut
    include JSON::Serializable

    def initialize
    end
  end

  # The user proved again who they are; a browser goes back to the account
  # page.
  struct Reauthenticated
    include JSON::Serializable

    def initialize
    end
  end
end
