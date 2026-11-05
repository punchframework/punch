module Billing::Invoices
  # Comes due with its invoice: `Send` enqueues it through the outbox for
  # the due date (lib/punch/docs/jobs.md). It records a reminder for an invoice that
  # is still unpaid; it mails nothing (the invoice itself is mailed by
  # `MailInvoice`). Safe to run twice: an invoice has one
  # reminder.
  @[Punch::Job::Options(queue: "reminders")]
  record Remind,
    invoice_id : ID do
    include Punch::Job

    def perform(job : Punch::Job::Context) : Punch::Job::Result
      job.write do |db|
        case invoice = Store.load(db, invoice_id)
        in Nil            then discard("invoice #{invoice_id} was deleted")
        in Invoice::Draft then discard("invoice #{invoice_id} is not sent")
        in Invoice::Paid  then discard("invoice #{invoice_id} is paid")
        in Invoice::Sent
          Queries.add_reminder(db, invoice_id: invoice.id, created_at: Time.utc)
          nil
        end
      end
    end
  end
end
