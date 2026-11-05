module Punch::Auth
  # How long sessions and tokens live, set once in app code:
  #
  # ```
  # Punch::Auth.config = Punch::Auth::Config.new(token_prefix: "inv", session_idle_timeout: 2.days)
  # ```
  struct Config
    PREFIX = /\A[a-z][a-z0-9]{1,15}\z/

    # A session ends after this long without a request.
    getter session_idle_timeout : Time::Span
    # And after this long in any case, counted from sign-in.
    getter session_lifetime : Time::Span
    # The last-seen time of a session or token is written at most this
    # often, so a signed-in request does not cost a write each.
    getter touch_interval : Time::Span
    # The start of every API token, so that people and secret scanners can
    # tell what it is: `inv_…`. Lowercase letters and digits.
    getter token_prefix : String
    # An API token must expire within this span of its creation.
    getter token_max_lifetime : Time::Span
    # How long a sign-in waits for its second factor after the password.
    getter second_factor_timeout : Time::Span
    # How long a sign-in counts as recent for `Punch::Policy::RecentAuthentication`.
    getter recent_authentication : Time::Span

    def initialize(*, @session_idle_timeout = 7.days, @session_lifetime = 30.days, @touch_interval = 5.minutes,
                   @token_prefix = "punch", @token_max_lifetime = 366.days, @second_factor_timeout = 10.minutes,
                   @recent_authentication = 15.minutes)
      raise ArgumentError.new("token_prefix must be 2 to 16 lowercase letters and digits, starting with a letter") unless PREFIX.matches?(token_prefix)
      raise ArgumentError.new("session_idle_timeout must be positive") unless session_idle_timeout.positive?
      raise ArgumentError.new("session_lifetime must be at least session_idle_timeout") unless session_lifetime >= session_idle_timeout
      raise ArgumentError.new("touch_interval must be shorter than session_idle_timeout") unless touch_interval < session_idle_timeout
      raise ArgumentError.new("token_max_lifetime must be positive") unless token_max_lifetime.positive?
      raise ArgumentError.new("second_factor_timeout must be from 1 to 60 minutes") unless 1.minute <= second_factor_timeout <= 1.hour
      raise ArgumentError.new("recent_authentication must be positive and shorter than session_idle_timeout") unless recent_authentication.positive? && recent_authentication < session_idle_timeout
    end
  end

  class_property config : Config = Config.new

  # The session cookie. `__Host-` makes browsers insist on `Secure`,
  # `Rejection::Path=/`, and no `Domain`, so a subdomain cannot set or
  # shadow it.
  COOKIE = "__Host-session"

  # The challenge of a sign-in that waits for its second factor: a
  # one-time token, so no session exists before the code is checked.
  CHALLENGE_COOKIE = "__Host-second-factor"
end
