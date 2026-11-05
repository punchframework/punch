module Accounts::Tokens
  # Tells the user that an API token was made for their account
  # (lib/punch/docs/auth.md).
  @[Punch::Subscriber::Delivery(:deferred)]
  @[Punch::Job::Options(queue: "mail")]
  struct NotifyCreated
    include Punch::Subscriber(TokenCreated)

    def call(event : TokenCreated, job : Punch::Job::Context) : Punch::Job::Result
      user, identities = Mailing.load(job, event.user_id) || return discard("user #{event.user_id} is gone")
      recipients = Mailing.notified(identities)
      return discard("user #{event.user_id} has no address") if recipients.empty?

      Punch::Mailer.deliver(NoticeMail.new(:token_created, user.name.value, recipients, token: event.name), locale: Mailing.locale(user), job: job)
    end
  end
end
