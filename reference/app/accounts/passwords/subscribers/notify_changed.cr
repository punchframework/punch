module Accounts::Passwords
  # Tells the user that their password changed (lib/punch/docs/auth.md).
  @[Punch::Subscriber::Delivery(:deferred)]
  @[Punch::Job::Options(queue: "mail")]
  struct NotifyChanged
    include Punch::Subscriber(Punch::Auth::PasswordChanged)

    def call(event : Punch::Auth::PasswordChanged, job : Punch::Job::Context) : Punch::Job::Result
      user, identities = Mailing.load(job, event.user_id) || return discard("user #{event.user_id} is gone")
      recipients = Mailing.notified(identities)
      return discard("user #{event.user_id} has no address") if recipients.empty?

      kind = event.reset? ? NoticeMail::Kind::PasswordReset : NoticeMail::Kind::PasswordChanged
      Punch::Mailer.deliver(NoticeMail.new(kind, user.name.value, recipients), locale: Mailing.locale(user), job: job)
    end
  end
end
