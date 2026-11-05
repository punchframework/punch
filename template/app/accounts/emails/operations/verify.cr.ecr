module Accounts::Emails
  @[Punch::Status(200)]
  record Verified,
    email : Punch::Email do
    include JSON::Serializable
  end

  # Verifies the address a link was mailed to: the button on
  # `VerifyPage`, which uses the token up. Needs no session, since the
  # link may be opened on another device.
  @[Punch::Public]
  @[Punch::RateLimit(30, per: 1.minute, by: :ip)]
  struct Verify < Punch::Command
    struct Input
      include Punch::Input

      getter token : String
    end

    alias Output = Verified | LinkExpired

    def call(input : Input, db : Punch::Writer) : Output
      _, email = LinkStore.holder(Punch::Auth::OneTimeTokens.consume(db, Links::VERIFY_EMAIL, input.token), db) || return LinkExpired.new
      Punch::Auth::EmailIdentities.verify(db, email)
      Verified.new(email)
    end
  end
end
