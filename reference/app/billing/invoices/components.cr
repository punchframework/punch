# What the invoice pages share (lib/punch/docs/views.md): a helper and the
# components that more than one page renders. A component only one page
# uses lives in that page's file under pages/. Amounts and dates are
# written in the view's locale (`v.locale.money`, `v.locale.date`).

module Billing::Invoices
  # What a list or a page calls an invoice: its number once sent.
  def self.title(locale : Punch::Locale, number : Number?, id : ID) : String
    t = locale.t.invoices
    number ? t.numbered(number: number.to_s) : t.draft(id: id.to_s)
  end

  # An invoice's state as a list shows it: overdue wins over sent.
  def self.state(locale : Punch::Locale, status : Invoice::Status, overdue : Bool) : String
    t = locale.t.invoices.statuses
    return t.overdue if overdue

    case status
    in .draft? then t.draft
    in .sent?  then t.sent
    in .paid?  then t.paid
    end
  end

  # An address as a definition in a list of facts: one line each, the
  # way it is written on an envelope.
  struct AddressLines
    include Punch::Component

    def initialize(@lines : Array(String))
    end

    def view(v : Punch::View) : Nil
      v.dd do
        @lines.each_with_index do |line, index|
          v.br if index > 0
          v.text line
        end
      end
    end
  end

  # The lines of an invoice with their total: shown to the user who issued
  # it and to the recipient of a shared link.
  struct LinesTable
    include Punch::Component

    def initialize(@detail : Detail)
    end

    def view(v : Punch::View) : Nil
      t, locale = v.t.invoices, v.locale
      currency, rows = @detail.currency, @detail.lines
      v.table(class: "lines") do
        v.caption t.line_count(count: rows.size)
        v.thead do
          v.tr { [t.position, t.description, t.quantity, t.unit_price, t.amount].each { |label| v.th label, scope: "col" } }
        end
        v.tbody do
          rows.each do |line|
            v.tr do
              v.td line.position.to_s
              v.td line.description.to_s
              v.td locale.number(line.quantity.value)
              v.td locale.money(line.unit_price, currency)
              v.td locale.money(line.total, currency)
            end
          end
        end
        v.tfoot do
          v.tr do
            v.th t.total, scope: "row", colspan: 4
            v.td { v.strong locale.money(@detail.total, currency) }
          end
        end
      end
    end
  end

  # When a sent invoice was issued, is due, and was paid.
  struct Dates
    include Punch::Component

    def initialize(@detail : Detail)
    end

    def view(v : Punch::View) : Nil
      sent_at, due_at = @detail.sent_at, @detail.due_at
      return unless sent_at && due_at

      t, locale = v.t.invoices, v.locale
      v.dt t.issued
      v.dd { v.time locale.date(sent_at, :long), datetime: sent_at }
      v.dt t.due
      v.dd do
        v.time locale.date(due_at, :long), datetime: due_at
        if @detail.overdue?
          v.text " "
          v.strong t.overdue, class: "overdue"
        end
      end
      if paid_at = @detail.paid_at
        v.dt t.paid
        v.dd { v.time locale.date(paid_at, :long), datetime: paid_at }
      end
    end
  end
end
