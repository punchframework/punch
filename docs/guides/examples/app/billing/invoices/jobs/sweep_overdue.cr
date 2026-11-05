module Billing::Invoices
  # Every morning, finds the invoices that are overdue and whose customer
  # was not reminded in the last week, and enqueues a reminder for each.
  # It reminds nobody itself: each reminder is a job of its own, retried
  # on its own.
  @[Punch::Job::Recurring(cron: "0 6 * * *")]
  record SweepOverdue do
    include Punch::Job

    def perform(job : Punch::Job::Context) : Punch::Job::Result
      overdue = job.read { |db| Queries.overdue(db, now: Time.utc, since: Time.utc - REMINDER_INTERVAL) }
      overdue.each do |invoice|
        job.enqueue(RemindOverdue.new(invoice.id, invoice.reminded_at ? Reminder::Final : Reminder::First))
      end
      nil
    end
  end
end
