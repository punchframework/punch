module Punch::Auth
  # The domain events of authentication: an app's sign-in, sign-out, and
  # account Commands publish them, for an audit trail, the ops console, and
  # notification mails. User IDs are plain integers, since Punch does not
  # know the app's ID type.

  # Someone signed in: a new session for *user_id*.
  struct SignInSucceeded
    include Punch::Event

    getter user_id : Int64
    getter session_id : Int64
    # How: `password`, `magic_link`, `sign_up`, …
    getter method : String

    def initialize(@user_id, @session_id, @method)
    end
  end

  # A sign-in with a password was refused. Published by Punch, not by the
  # Command, after the Command's transaction rolled back: a Command that
  # takes `Punch::Auth::PasswordCheck` must list this event in its
  # `Punch::Events(...)`. *user_id* is the owner of the address, when it
  # belongs to someone.
  struct SignInFailed
    include Punch::Event

    getter email : Email
    getter user_id : Int64?

    def initialize(@email, @user_id)
    end
  end

  # The password of *user_id* was changed with the current one, or set
  # through a reset link (*reset*).
  struct PasswordChanged
    include Punch::Event

    getter user_id : Int64
    getter? reset : Bool

    def initialize(@user_id, @reset)
    end
  end

  # Sessions of *user_id* ended before their time: the session
  # *session_id*, or with `nil` every session but the current one.
  struct SessionRevoked
    include Punch::Event

    getter user_id : Int64
    getter session_id : Int64?
    # Why: `sign_out`, `revoked` (by the user, from the session list),
    # `password_changed`, `password_reset`.
    getter reason : String

    def initialize(@user_id, @session_id, @reason)
    end
  end
end

module Punch::Auth
  # The second factor of *user_id* changed. Published by the app's Commands;
  # a notice to the user's addresses follows.
  struct SecondFactorChanged
    include Punch::Event

    enum Change
      # An authenticator app was confirmed.
      Enabled
      # It was removed, with its recovery codes.
      Removed
      # The recovery codes were replaced.
      RecoveryCodes
    end

    getter user_id : Int64
    getter change : Change

    def initialize(@user_id : Int64, @change : Change)
    end
  end
end
