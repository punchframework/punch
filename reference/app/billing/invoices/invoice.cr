# Tier 2 (lib/punch/docs/models.md): an invoice has a lifecycle, and its state decides what
# may happen to it. Each state is its own immutable type; a transition is a
# method that returns the next state. Invoices::Store turns rows into these
# types and back. Nothing here touches the database.
module Billing::Invoices::Invoice
  # Lines per invoice, and the largest unit price in minor units: with
  # Quantity::MAX they keep every total far inside Punch::Money's range.
  MAX_LINES      =               100
  MAX_UNIT_PRICE = 1_000_000_000_i64

  enum Status
    Draft
    Sent
    Paid
  end

  record Line,
    description : Punch::NonEmptyString,
    quantity : Quantity,
    unit_price : Punch::Money do
    def total : Punch::Money
      unit_price * quantity.value
    end
  end

  # What every state has.
  module Billed
    abstract def lines : Array(Line)

    def total : Punch::Money
      lines.sum(Punch::Money.zero, &.total)
    end
  end

  # Whether an invoice is unpaid past its due date. Included by `Sent`,
  # `Paid`, and the rows of the list queries (`-- include
  # Billing::Invoices::Invoice::Due`), so lists and details share one rule; a draft
  # row has no due date and is never overdue.
  module Due
    abstract def due_at : Time?
    abstract def paid_at : Time?

    def overdue?(now : Time) : Bool
      due = due_at
      due && paid_at.nil? ? now > due : false
    end
  end

  # Being written: can be revised, sent, or deleted.
  record Draft,
    id : Invoices::ID,
    customer_id : Customers::ID,
    currency : Punch::Currency,
    lines : Array(Line),
    created_at : Time do
    include Billed

    def status : Status
      Status::Draft
    end

    def revise(*, currency : Punch::Currency = @currency, lines : Array(Line) = @lines) : Draft
      copy_with(currency: currency, lines: lines)
    end

    # Issues the invoice under *number*, billing the customer as
    # *billed_to* says. An invoice without lines cannot be sent.
    def send(number : Invoices::Number, at : Time, billed_to : BilledTo) : Sent | NoLines
      return NoLines.new if lines.empty?

      Sent.new(id, customer_id, currency, lines, created_at, number: number, sent_at: at, due_at: at + Invoices::PAYMENT_TERM, billed_to: billed_to)
    end
  end

  # Issued: numbered, final, and due on a date. Who it bills is kept as
  # it was then; invoices sent before that was kept have none.
  record Sent,
    id : Invoices::ID,
    customer_id : Customers::ID,
    currency : Punch::Currency,
    lines : Array(Line),
    created_at : Time,
    number : Invoices::Number,
    sent_at : Time,
    due_at : Time,
    billed_to : BilledTo? do
    include Billed
    include Due

    def status : Status
      Status::Sent
    end

    def paid_at : Time?
      nil
    end

    # Settles the invoice with a payment of *amount* in *currency*, which
    # must be its total in its currency.
    def pay(amount : Punch::Money, currency : Punch::Currency, at : Time, reference : Punch::NonEmptyString) : Paid | WrongAmount
      return WrongAmount.new(total, @currency) unless amount == total && currency == @currency

      Paid.new(id, customer_id, @currency, lines, created_at, number, sent_at, due_at, billed_to, paid_at: at, payment_reference: reference)
    end
  end

  # Settled: a sent invoice whose payment arrived. Final, like `Sent`.
  record Paid,
    id : Invoices::ID,
    customer_id : Customers::ID,
    currency : Punch::Currency,
    lines : Array(Line),
    created_at : Time,
    number : Invoices::Number,
    sent_at : Time,
    due_at : Time,
    billed_to : BilledTo?,
    paid_at : Time,
    payment_reference : Punch::NonEmptyString do
    include Billed
    include Due

    def status : Status
      Status::Paid
    end
  end

  # Why a draft could not be sent.
  record NoLines

  # Why a payment did not settle an invoice: it was not over the invoice's
  # total in its currency.
  record WrongAmount, total : Punch::Money, currency : Punch::Currency

  # Every state; `Issued` the ones that are final.
  alias Any = Draft | Sent | Paid
  alias Issued = Sent | Paid
end
