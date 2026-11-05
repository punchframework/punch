module Billing::Invoices
  # An invoice as the API shows it once it is recorded.
  @[Punch::Status(201)]
  record Created,
    id : ID,
    number : String,
    due_at : Time do
    include JSON::Serializable
  end

  # Records an invoice issued elsewhere, so its customer is reminded when
  # it falls due. Invoice numbers are unique: one that is taken is refused
  # at `number`.
  @[Punch::Authorize(Punch::SignedIn)]
  struct Create < Punch::Command
    struct Input
      include Punch::Input

      getter number : Punch::NonEmptyString
      getter customer_email : Punch::Email
      getter due_at : Time
    end

    alias Output = Created | NumberTaken

    def call(input : Input, db : Punch::Writer, _actor : Examples::Actor, _grant : Punch::Grant(Create)) : Output
      case invoice = Table.insert(db, number: input.number.value, customer_email: input.customer_email, due_at: input.due_at)
      in Record      then Created.new(invoice.id, invoice.number, invoice.due_at)
      in NumberTaken then invoice
      end
    end
  end
end
