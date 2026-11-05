module Accounts::MagicLinks
  # Mails a sign-in link, enqueued by `MagicLinks::Create` for every
  # address asked for, so that the request writes the same whether or not
  # the address has an account; the job ends at once for one no account has.
  # Earlier sign-in links stop working.
  @[Punch::Job::Options(queue: "mail", attempts: 3)]
  record SendLink,
    # The user, or `NOBODY` for an address no account has.
    user_id : Int64,
    email : Punch::Email do
    include Punch::Job

    NOBODY = 0_i64

    def perform(job : Punch::Job::Context) : Punch::Job::Result
      return discard("no account has the address") if user_id == NOBODY

      user, identities = Mailing.load(job, user_id) || return discard("user #{user_id} is gone")
      return discard("the address was removed") unless identities.any?(&.email.==(email))

      token = job.write do |db|
        Punch::Auth::OneTimeTokens.revoke_all(db, Links::MAGIC_LINK, user_id)
        Punch::Auth::OneTimeTokens.issue(db, Links::MAGIC_LINK, Links::MAGIC_VALID, user_id: user_id, subject: email.value)
      end
      mail = LinkMail.new(:magic_link, user.name.value, email, MagicLinks::SignInPage.href(token: token.unwrap))
      Punch::Mailer.deliver(mail, locale: Mailing.locale(user), job: job)
    end
  end
end
