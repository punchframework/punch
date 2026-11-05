module Punch::Ops::Console
  # ---- Access by role -----------------------------------------------------

  # Every operation of the console, as a global role: an app's own role
  # includes it, so who may use the console is an assignment like any other
  # (docs/ops.md).
  #
  # ```
  # module Accounts::Roles
  #   struct Operator
  #     include Punch::Role
  #     permits Punch::Ops::Console::Operations
  #   end
  # end
  #
  # Punch::Ops::Console.mount Tally::Actor, Punch::Ops::Console::ByRole
  # ```
  #
  # It does not make an app need the role tables on its own: only the
  # app's roles do (`Roles.used?`).
  struct Operations
    include Punch::Role

    permits IndexPage, ErrorsPage, ErrorPage, ResolveError, ReopenError,
      JobsPage, JobPage, RetryJob, DiscardJob, RetryFailed, PauseQueue, ResumeQueue,
      MailsPage, MailPage, MailHTMLPage, CachePage, ClearCache, BansPage, LiftBan,
      WebhooksPage, WebhookPage, RetryWebhook, ReplayWebhook,
      DatabasePage, RecoveryPage, ConfirmRecovery, KeysPage, EventsPage,
      PerformancePage, SeriesPage, RecordPage,
      ShowOverview, ListErrors, ShowError, ShowJobs, ShowJob, ShowPerformance, ShowRecord
  end

  # The policy for an app with roles: whoever holds a global role that
  # includes `Operations` may use the console, in every environment. A
  # user with no global role gets 404, so the console does not show it
  # exists. The app's actor needs `principal`, as `Punch::Auth::Actor`'s
  # example has it.
  struct ByRole
    include Punch::Policy

    def self.check(actor : Punch::Auth::Actor, db : Punch::Reader | Punch::Writer, operation : Punch::Operation.class, **params) : Punch::Policy::Decision
      Punch::Roles.check(db, actor.principal.user_id, operation)
    end
  end
end
