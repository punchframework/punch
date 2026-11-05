module Accounts::SecondFactor
  # Tells the user that their second factor changed (lib/punch/docs/auth.md).
  @[Punch::Subscriber::Delivery(:deferred)]
  @[Punch::Job::Options(queue: "mail")]
  struct NotifyChanged
    include Punch::Subscriber(Punch::Auth::SecondFactorChanged)

    def call(event : Punch::Auth::SecondFactorChanged, job : Punch::Job::Context) : Punch::Job::Result
      user, identities = Mailing.load(job, event.user_id) || return discard("user #{event.user_id} is gone")
      recipients = Mailing.notified(identities)
      return discard("user #{event.user_id} has no address") if recipients.empty?

      kind = case event.change
             in .enabled?        then NoticeMail::Kind::SecondFactorEnabled
             in .removed?        then NoticeMail::Kind::SecondFactorRemoved
             in .recovery_codes? then NoticeMail::Kind::RecoveryCodes
             end
      Punch::Mailer.deliver(NoticeMail.new(kind, user.name.value, recipients), locale: Mailing.locale(user), job: job)
    end
  end
end
