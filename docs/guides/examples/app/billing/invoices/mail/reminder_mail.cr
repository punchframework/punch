module Billing::Invoices
  # Reminds a customer that an invoice is overdue.
  struct ReminderMail
    include Punch::Mail

    def initialize(@invoice : Record, @reminder : Reminder)
    end

    def to : Punch::Mail::Address
      Punch::Mail::Address.new(@invoice.customer_email)
    end

    def subject(locale : Punch::Locale) : String
      t = locale.t.billing.reminder
      @reminder.first? ? t.subject(number: @invoice.number) : t.final_subject(number: @invoice.number)
    end

    def view(v : Punch::View) : Nil
      t = v.t.billing.reminder
      v.p t.body(number: @invoice.number, due: v.locale.date(@invoice.due_at, :long))
      v.p t.final unless @reminder.first?
    end
  end
end
