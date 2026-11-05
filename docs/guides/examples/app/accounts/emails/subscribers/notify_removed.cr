module Accounts::Emails
  # Tells the removed address, and the user's verified ones, that it was
  # removed.
  @[Punch::Subscriber::Delivery(:deferred)]
  @[Punch::Job::Options(queue: "mail")]
  struct NotifyRemoved
    include Punch::Subscriber(EmailRemoved)

    def call(event : EmailRemoved, job : Punch::Job::Context) : Punch::Job::Result
      user, identities = Mailing.load(job, event.user_id) || return discard("user #{event.user_id} is gone")
      recipients = [event.email] + identities.select(&.verified?).map(&.email)
      Punch::Mailer.deliver(NoticeMail.new(:email_removed, user.name.value, recipients, event.email), locale: Mailing.locale(user), job: job)
    end
  end
end
