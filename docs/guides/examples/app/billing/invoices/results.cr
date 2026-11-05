module Billing::Invoices
  # An invoice as the API shows it.
  @[Punch::Status(200)]
  record Detail,
    id : ID,
    number : String,
    customer_email : Punch::Email,
    due_at : Time,
    paid_at : Time? do
    include JSON::Serializable

    def self.of(invoice : Record) : self
      new(invoice.id, invoice.number, invoice.customer_email, invoice.due_at, invoice.paid_at)
    end
  end

  @[Punch::Status(404)]
  struct NotFound
    include Punch::Problem
  end

  # A paid invoice needs no reminder, and is paid only once.
  @[Punch::Status(409)]
  struct AlreadyPaid
    include Punch::Problem

    getter paid_at : Time

    def initialize(@paid_at : Time)
    end
  end
end
