module Accounts::Emails
  # Sends the verification link to an address just added. Deferred: it
  # issues the token in its own write, so the token exists only in the
  # mail, never in a payload.
  @[Punch::Subscriber::Delivery(:deferred)]
  @[Punch::Job::Options(queue: "mail")]
  struct SendVerification
    include Punch::Subscriber(EmailAdded)

    def call(event : EmailAdded, job : Punch::Job::Context) : Punch::Job::Result
      user, identities = Mailing.load(job, event.user_id) || return discard("user #{event.user_id} is gone")
      identity = identities.find(&.email.==(event.email)) || return discard("the address was removed")
      return if identity.verified?

      token = job.write do |db|
        Punch::Auth::OneTimeTokens.issue(db, Links::VERIFY_EMAIL, Links::VERIFY_VALID, user_id: event.user_id, subject: event.email.value)
      end
      mail = LinkMail.new(:verify, user.name.value, event.email, Emails::VerifyPage.href(token: token.unwrap))
      Punch::Mailer.deliver(mail, locale: Mailing.locale(user), job: job)
    end
  end
end
