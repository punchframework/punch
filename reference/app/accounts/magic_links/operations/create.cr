module Accounts::MagicLinks
  # The same answer whether the address has an account or not.
  struct LinkRequested
    include JSON::Serializable

    def initialize
    end
  end

  # Mails a sign-in link to *email* if it belongs to an account
  # (`SendLink`); no account is made for an unknown address.
  @[Punch::Public]
  @[Punch::RateLimit(5, per: 1.hour, by: :email, store: :durable)]
  @[Punch::RateLimit(30, per: 1.hour, by: :ip)]
  struct Create < Punch::Command
    struct Input
      include Punch::Input

      getter email : Punch::Email
    end

    alias Output = LinkRequested

    def call(input : Input, db : Punch::Writer, jobs : Punch::Jobs(SendLink)) : Output
      # Enqueued for any address, so the write is the same; the job ends
      # at once for one no account has (`SendLink::NOBODY`).
      user_id = Punch::Auth::EmailIdentities.find(db, input.email).try(&.user_id) || SendLink::NOBODY
      jobs.enqueue(SendLink.new(user_id, input.email))
      LinkRequested.new
    end
  end
end
