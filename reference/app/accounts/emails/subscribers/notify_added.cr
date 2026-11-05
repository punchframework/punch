module Accounts::Emails
  # Tells the user's other addresses that one was added.
  @[Punch::Subscriber::Delivery(:deferred)]
  @[Punch::Job::Options(queue: "mail")]
  struct NotifyAdded
    include Punch::Subscriber(EmailAdded)

    def call(event : EmailAdded, job : Punch::Job::Context) : Punch::Job::Result
      user, identities = Mailing.load(job, event.user_id) || return discard("user #{event.user_id} is gone")
      others = identities.reject(&.email.==(event.email)).select(&.verified?).map(&.email)
      return if others.empty?

      Punch::Mailer.deliver(NoticeMail.new(:email_added, user.name.value, others, event.email), locale: Mailing.locale(user), job: job)
    end
  end
end
