module Shop::Invoices
  # Sends an invoice to its recipient.
  #
  # Only a draft can be sent; sending twice answers 409.
  @[Punch::Public]
  @[Punch::RateLimitExempt("a fixture")]
  struct Send < Punch::Command
    struct Input
      include Punch::Input

      @[Punch::PathParam]
      getter invoice_id : ID
    end

    def call(input : Input, db : Punch::Writer) : NotFound | AlreadySent?
      nil
    end
  end
end
