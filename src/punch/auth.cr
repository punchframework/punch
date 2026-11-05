require "./auth/token"
require "./auth/config"
require "./auth/sessions"
require "./auth/api_tokens"
require "./auth/one_time_tokens"
require "./auth/passwords"
require "./auth/identities"
require "./auth/totp"
require "./auth/actor"
require "./auth/schema"
require "./auth/events"
require "./auth/reveal"

module Punch
  # Authentication primitives (docs/auth.md): server-side sessions, API
  # tokens, and one-time tokens, each random and stored as a digest; the
  # actor in the request context. Sign-in flows are the app's own operations
  # over these.
  module Auth
  end
end
