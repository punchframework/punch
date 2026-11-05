module Operators
  # Mails the operators each trouble Punch announces, once, as a job
  # after the announcement commits.
  @[Punch::Subscriber::Delivery(:deferred)]
  @[Punch::Job::Options(queue: "mail")]
  struct AlertOperators
    include Punch::Subscriber(Punch::Ops::ErrorOccurred)
    include Punch::Subscriber(Punch::Ops::JobsFailing)
    include Punch::Subscriber(Punch::Ops::BackupStale)

    def call(event : Punch::Ops::ErrorOccurred | Punch::Ops::JobsFailing | Punch::Ops::BackupStale, job : Punch::Job::Context) : Punch::Job::Result
      to = Examples::Credentials.current.alert_to || return discard("no alert_to in the credentials")
      locale = Punch::I18n.locale(nil)
      t = locale.t.operators.alert
      summary = case event
                in Punch::Ops::ErrorOccurred then t.error(exception: event.exception, source: event.source)
                in Punch::Ops::JobsFailing   then t.jobs(job_type: event.job_type, failed: event.failed, incompatible: event.incompatible)
                in Punch::Ops::BackupStale   then t.backup(reason: event.reason)
                end
      Punch::Mailer.deliver(AlertMail.new(to, summary), locale: locale, job: job)
    end
  end
end
