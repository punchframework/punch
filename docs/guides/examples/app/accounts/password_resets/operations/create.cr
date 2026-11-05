module Accounts::PasswordResets
  # The same answer whether the address has an account or not; a browser
  # goes on to the page that says to check the inbox.
  struct Requested
    include JSON::Serializable

    def initialize
    end
  end

  # Mails a reset link to *email* if it belongs to an account. The answer
  # does not say whether it does; the link is made by the job
  # (`SendLink`), so the response takes as long either way.
  @[Punch::Public]
  @[Punch::RateLimit(5, per: 1.hour, by: :email, store: :durable)]
  @[Punch::RateLimit(30, per: 1.hour, by: :ip)]
  struct Create < Punch::Command
    struct Input
      include Punch::Input

      getter email : Punch::Email
    end

    alias Output = Requested

    def call(input : Input, db : Punch::Writer, jobs : Punch::Jobs(SendLink)) : Output
      # Enqueued for any address, so the write is the same; the job ends
      # at once for one no account has (`SendLink::NOBODY`).
      user_id = Punch::Auth::EmailIdentities.find(db, input.email).try(&.user_id) || SendLink::NOBODY
      jobs.enqueue(SendLink.new(user_id, input.email))
      Requested.new
    end
  end
end
