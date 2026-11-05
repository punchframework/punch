module Billing::Invoices
  # Every morning, records a reminder for each sent, unpaid invoice past
  # its due date that has none: a sweep behind `Remind`, for invoices
  # whose reminder never ran (a job lost in a restore). It walks every
  # organization's invoices in ID order, a batch at a time, and runs in
  # steps (lib/punch/docs/jobs.md, "Long jobs: steps"): a deploy or a crash
  # resumes it after the last batch it saved.
  @[Punch::Job::Recurring(cron: "0 6 * * *")]
  @[Punch::Job::Options(queue: "reminders", priority: -10)]
  record RemindOverdue do
    include Punch::Job
    include Punch::Job::Stepped

    BATCH = 200_i64

    @[Punch::Job::Step]
    def remind(job : Punch::Job::Context, invoices : Punch::Job::Cursor(ID)) : Punch::Job::StepResult
      filter = Queries::OverdueWithoutReminder::Filter.new(after: invoices.at)
      batch = job.read { |db| Queries.overdue_without_reminder(db, now: Time.utc, limit: BATCH, filter: filter) }
      return if batch.empty?

      job.write do |db|
        batch.each { |invoice| Queries.add_reminder(db, invoice_id: invoice.id, created_at: Time.utc) }
        invoices.continue(batch.last.id)
      end
    end
  end
end
