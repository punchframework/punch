module Billing::Invoices
  # One line of an invoice as the API shows it.
  struct LineOutput
    include JSON::Serializable

    getter position : Int32
    getter description : Punch::NonEmptyString
    getter quantity : Quantity
    getter unit_price : Punch::Money
    getter total : Punch::Money

    def initialize(@position : Int32, line : Invoice::Line)
      @description = line.description
      @quantity = line.quantity
      @unit_price = line.unit_price
      @total = line.total
    end
  end

  # Who issued an invoice, from the app's credentials.
  struct Issuer
    include JSON::Serializable

    getter name : Punch::NonEmptyString
    getter vat_id : Punch::NonEmptyString?

    def initialize(issuer : Invoicing::Credentials::Issuer)
      @name = issuer.name
      @vat_id = issuer.vat_id
    end
  end

  # An invoice with its lines. Amounts are integers in minor units of
  # `currency`: 1250 is 12.50 EUR.
  @[Punch::Status(200)]
  struct Detail
    include JSON::Serializable

    getter id : ID
    getter issuer : Issuer
    getter status : Invoice::Status
    getter customer_id : Customers::ID
    getter currency : Punch::Currency
    getter lines : Array(LineOutput)
    getter total : Punch::Money
    getter created_at : Time
    # Set once the invoice is sent.
    getter number : Number?
    getter sent_at : Time?
    getter due_at : Time?
    # Set once its payment arrived.
    getter paid_at : Time?
    # Who the invoice bills: as kept when it was sent, else (a draft, or
    # an invoice sent before that was kept) the customer as they are now.
    getter billed_to : BilledTo?
    # The address it is sent from: the organization's billing profile.
    getter sender : Billing::Address?
    # Sent, unpaid, and past its due date.
    getter? overdue : Bool

    # *billed_to* and *sender* come from the database: build one with
    # `Store.detail`.
    def initialize(invoice : Invoice::Any, now : Time, @billed_to : BilledTo?, @sender : Billing::Address?)
      @id = invoice.id
      @issuer = Issuer.new(Invoicing::Credentials.current.issuer)
      @status = invoice.status
      @customer_id = invoice.customer_id
      @currency = invoice.currency
      @lines = invoice.lines.map_with_index(1) { |line, position| LineOutput.new(position, line) }
      @total = invoice.total
      @created_at = invoice.created_at
      @overdue = false
      if invoice.is_a?(Invoice::Issued)
        @number = invoice.number
        @sent_at = invoice.sent_at
        @due_at = invoice.due_at
        @paid_at = invoice.paid_at
        @overdue = invoice.overdue?(now)
      end
    end
  end

  # An invoice in a list.
  struct Summary
    include JSON::Serializable

    getter id : ID
    getter status : Invoice::Status
    getter number : Number?
    getter customer_id : Customers::ID
    getter customer_name : Punch::NonEmptyString
    getter currency : Punch::Currency
    getter total : Punch::Money
    getter sent_at : Time?
    getter due_at : Time?
    getter paid_at : Time?
    # Sent, unpaid, and past its due date.
    getter? overdue : Bool

    def initialize(row : Queries::Page::Row, now : Time)
      @id = row.id
      @status = Store.status(row.status, row.id, row.paid_at)
      @number = row.number
      @customer_id = row.customer_id
      @customer_name = row.customer_name
      @currency = row.currency
      @total = Punch::Stored.load(Punch::Money, row.total, "invoices", "total", row.id.value)
      @sent_at = row.sent_at
      @due_at = row.due_at
      @paid_at = row.paid_at
      @overdue = row.overdue?(now)
    end
  end

  # One page of invoices.
  struct Page
    include JSON::Serializable

    getter invoices : Array(Summary)
    # Pass as `after` for the next page; absent on the last one.
    getter next_after : Queries::Page::Cursor?

    def initialize(@invoices : Array(Summary), @next_after : Queries::Page::Cursor?)
    end
  end

  @[Punch::Status(404)]
  struct NotFound
    include Punch::Problem
  end

  # A sent invoice is final, also once it is paid.
  @[Punch::Status(409)]
  struct AlreadySent
    include Punch::Problem

    getter number : Number
    getter sent_at : Time

    def initialize(invoice : Invoice::Issued)
      @number = invoice.number
      @sent_at = invoice.sent_at
    end
  end
end
