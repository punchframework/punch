module Billing::Invoices
  # A reminder is on its way: the job runs after the commit.
  @[Punch::Status(202)]
  struct ReminderQueued
    include JSON::Serializable

    def initialize
    end
  end

  # Reminds the customer of one unpaid invoice now, without waiting for
  # the sweep: the first reminder, mailed by `RemindOverdue`.
  @[Punch::Authorize(Punch::SignedIn)]
  struct SendReminder < Punch::Command
    struct Input
      include Punch::Input

      @[Punch::PathParam]
      getter invoice_id : ID
    end

    alias Output = ReminderQueued | NotFound | AlreadyPaid

    def call(input : Input, db : Punch::Writer, _actor : Examples::Actor, _grant : Punch::Grant(SendReminder),
             jobs : Punch::Jobs(RemindOverdue)) : Output
      invoice = Table.find(db, input.invoice_id) || return NotFound.new
      if paid_at = invoice.paid_at
        return AlreadyPaid.new(paid_at)
      end

      # Through the outbox: the job exists exactly when this Command commits.
      jobs.enqueue(RemindOverdue.new(invoice.id, Reminder::First))
      ReminderQueued.new
    end
  end
end
