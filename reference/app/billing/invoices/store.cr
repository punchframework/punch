# Loads and saves Billing::Invoices::Invoice states with the generated queries. Call
# it inside one `read` or `write`, so a load and the save after it see the
# same data (lib/punch/docs/models.md).
module Billing::Invoices::Store
  extend self

  def load(db : Punch::Reader | Punch::Writer, id : ID) : Invoice::Any?
    row = Table.find(db, id) || return
    lines = Queries.lines(db, invoice_id: id).map do |line|
      Invoice::Line.new(line.description, line.quantity, line.unit_price)
    end
    payment = row.status == "sent" ? Queries.payment(db, invoice_id: id) : nil

    case status(row.status, id, payment.try(&.paid_at))
    in .draft?
      Invoice::Draft.new(row.id, row.customer_id, row.currency, lines, row.created_at)
    in .sent?
      Invoice::Sent.new(row.id, row.customer_id, row.currency, lines, row.created_at,
        number: row.number || missing(id, "number"),
        sent_at: row.sent_at || missing(id, "sent_at"),
        due_at: row.due_at || missing(id, "due_at"),
        billed_to: row.billed_to.try(&.unwrap))
    in .paid?
      payment ||= missing(id, "invoice_payments")
      Invoice::Paid.new(row.id, row.customer_id, row.currency, lines, row.created_at,
        number: row.number || missing(id, "number"),
        sent_at: row.sent_at || missing(id, "sent_at"),
        due_at: row.due_at || missing(id, "due_at"),
        billed_to: row.billed_to.try(&.unwrap),
        paid_at: payment.paid_at, payment_reference: payment.reference)
    end
  end

  # A new draft for *customer_id*, which must belong to *organization_id*;
  # the foreign key refuses a customer of another organization.
  def create(db : Punch::Writer, *, organization_id : Accounts::Organizations::ID, customer_id : Customers::ID, currency : Punch::Currency, lines : Array(Invoice::Line), at : Time) : Invoice::Draft
    # A draft has no number yet, so it cannot take one.
    row = Punch.cannot_violate(Table.insert(db, organization_id: organization_id, customer_id: customer_id, currency: currency, status: "draft", created_at: at))
    insert_lines(db, row.id, lines)
    Invoice::Draft.new(row.id, customer_id, currency, lines, row.created_at)
  end

  # Writes the state and replaces the lines. Organization and customer stay. A
  # payment is written once, when a `Sent` invoice loaded in the same
  # transaction becomes `Paid`; it never changes after.
  def save(db : Punch::Writer, invoice : Invoice::Any) : Nil
    # Numbers come from `next_number` in the same transaction.
    saved = case invoice
            in Invoice::Draft
              Queries.save(db, id: invoice.id, currency: invoice.currency, status: "draft", number: nil, sent_at: nil, due_at: nil, billed_to: nil)
            in Invoice::Sent
              Queries.save(db, id: invoice.id, currency: invoice.currency, status: "sent", number: invoice.number, sent_at: invoice.sent_at, due_at: invoice.due_at,
                billed_to: invoice.billed_to.try { |billed_to| Punch::Secret.new(billed_to) })
            in Invoice::Paid
              # Nothing of the sent invoice changes; only the payment is new.
              Queries.record_payment(db, invoice_id: invoice.id, reference: invoice.payment_reference, amount: invoice.total, paid_at: invoice.paid_at)
              return
            end

    raise Punch::Database::Error.new("invoice #{invoice.id} is gone") if Punch.cannot_violate(saved).zero?
    Queries.delete_lines(db, invoice_id: invoice.id)
    insert_lines(db, invoice.id, invoice.lines)
  end

  def delete(db : Punch::Writer, invoice : Invoice::Draft) : Nil
    Queries.delete_lines(db, invoice_id: invoice.id)
    Table.delete(db, invoice.id)
  end

  # The number the next sent invoice gets.
  # *invoice* as operations answer with it: who it bills (as kept when it
  # was sent, else the customer as they are now) and the address it is
  # sent from (its organization's billing profile).
  def detail(db : Punch::Reader | Punch::Writer, invoice : Invoice::Any, now : Time) : Detail
    kept = invoice.billed_to if invoice.is_a?(Invoice::Issued)
    billed_to = kept || Customers::Table.find(db, invoice.customer_id).try { |customer| BilledTo.of(customer) }
    Detail.new(invoice, now, billed_to, Queries.sender(db, invoice_id: invoice.id).try(&.address))
  end

  def next_number(db : Punch::Writer) : Number
    Number.next(Queries.last_sequence(db).try(&.sequence) || 0_i64)
  end

  # The state a stored status names, with the time of the invoice's
  # payment if it has one; also for list rows.
  def status(raw : String, id : ID, paid_at : Time?) : Invoice::Status
    case raw
    when "draft" then Invoice::Status::Draft
    when "sent"  then paid_at ? Invoice::Status::Paid : Invoice::Status::Sent
    else              invalid_status_choice(id)
    end
  end

  private def insert_lines(db : Punch::Writer, id : ID, lines : Array(Invoice::Line)) : Nil
    # Positions are numbered here, after the old lines were deleted.
    lines.each_with_index(1) do |line, position|
      Punch.cannot_violate(Lines::Table.insert(db, invoice_id: id, position: position.to_i64, description: line.description, quantity: line.quantity, unit_price: line.unit_price))
    end
  end

  private def missing(id : ID, column : String) : NoReturn
    raise Punch::Database::RowError.new("invoices", column, id.value, "Billing::Invoices::Invoice::Sent", "required")
  end

  private def invalid_status_choice(id : ID) : NoReturn
    raise Punch::Database::RowError.new("invoices", "status", id.value, "Billing::Invoices::Invoice::Status", "invalid_choice")
  end
end
