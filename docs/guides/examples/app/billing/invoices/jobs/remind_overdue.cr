module Billing::Invoices
  # Mails the customer of one overdue invoice a reminder, and records
  # when. Safe to run again: an invoice that was paid, or reminded in the
  # meantime, is skipped. At most two run at a time, so the reminders of
  # a big sweep leave the mail relay's other connections to sign-in mail.
  @[Punch::Job::Options(queue: "mail", attempts: 5)]
  @[Punch::Job::Concurrency(2)]
  @[Punch::Payloads::Version(2, from: {1 => V1})]
  record RemindOverdue,
    invoice_id : ID,
    reminder : Reminder do
    include Punch::Job

    def perform(job : Punch::Job::Context) : Punch::Job::Result
      # On the run's wide event, so a reminder can be found by its invoice.
      Punch::Trace.event["invoice.id"] = invoice_id.value
      Punch::Trace.event["invoice.reminder"] = reminder.to_s.underscore
      invoice = job.read { |db| Table.find(db, invoice_id) }
      return discard("invoice #{invoice_id} is gone") unless invoice
      return discard("invoice #{invoice_id} is paid") if invoice.paid_at
      if reminded = invoice.reminded_at
        return discard("invoice #{invoice_id} was reminded already") if reminded > Time.utc - REMINDER_INTERVAL
      end

      result = Punch::Mailer.deliver(ReminderMail.new(invoice, reminder), locale: Punch::I18n.locale(nil), job: job)
      job.write { |db| Queries.mark_reminded(db, id: invoice_id, now: Time.utc) } if result.nil?
      result
    end

    # Version 1: before there was a final reminder, every reminder was a
    # first one. Never change it.
    struct V1
      include Punch::Payloads::Frozen

      getter invoice_id : ID

      def upgrade : RemindOverdue
        RemindOverdue.new(invoice_id, Reminder::First)
      end
    end
  end
end
