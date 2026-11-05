module Punch::Mailer
  # Sends a rendered mail. Punch has two, `Capture` and `SMTP`; write one
  # for a provider's HTTP API, and register it with
  # `Punch::Mailer.adapter` and `delivery: adapter`.
  #
  # `deliver_now` returns when the mail was accepted. It raises
  # `DeliveryFailed` when delivery failed, as does any other exception,
  # which the job retries.
  abstract class Adapter
    abstract def deliver_now(message : Message) : Nil
  end

  # A delivery failed. *permanent* when the server refused the recipient
  # for good (an SMTP 5xx answer to `RCPT`), so another attempt cannot
  # succeed.
  class DeliveryFailed < Exception
    getter? permanent : Bool

    def initialize(message : String, *, @permanent : Bool = false)
      super(message)
    end
  end
end
