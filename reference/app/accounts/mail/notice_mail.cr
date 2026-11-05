module Accounts
  # A notice that how the user signs in changed, with what to do if they
  # did not do it themselves.
  struct NoticeMail
    include Punch::Mail

    enum Kind
      PasswordChanged
      PasswordReset
      EmailAdded
      EmailRemoved
      SecondFactorEnabled
      SecondFactorRemoved
      RecoveryCodes
      TokenCreated
    end

    # *email* is the address added or removed, *token* the name of a token
    # made.
    def initialize(@kind : Kind, @name : String, @recipients : Array(Punch::Email), @email : Punch::Email? = nil, @token : String? = nil)
    end

    def to : Array(Punch::Mail::Address)
      @recipients.map { |email| Punch::Mail::Address.new(email, @name) }
    end

    def subject(locale : Punch::Locale) : String
      t = locale.t.accounts.mail.notice

      case @kind
      in .password_changed?      then t.password_changed.subject
      in .password_reset?        then t.password_reset.subject
      in .email_added?           then t.email_added.subject
      in .email_removed?         then t.email_removed.subject
      in .second_factor_enabled? then t.second_factor_enabled.subject
      in .second_factor_removed? then t.second_factor_removed.subject
      in .recovery_codes?        then t.recovery_codes.subject
      in .token_created?         then t.token_created.subject
      end
    end

    def view(v : Punch::View) : Nil
      t = v.t.accounts.mail
      email = @email.try(&.value) || ""
      v.p t.greeting(name: @name)
      v.p case @kind
      in .password_changed?      then t.notice.password_changed.body
      in .password_reset?        then t.notice.password_reset.body
      in .email_added?           then t.notice.email_added.body(email: email)
      in .email_removed?         then t.notice.email_removed.body(email: email)
      in .second_factor_enabled? then t.notice.second_factor_enabled.body
      in .second_factor_removed? then t.notice.second_factor_removed.body
      in .recovery_codes?        then t.notice.recovery_codes.body
      in .token_created?         then t.notice.token_created.body(token: @token || "")
      end
      v.p do
        v.text "#{t.notice.not_you} "
        v.a t.notice.reset, href: PasswordResets::CreatePage.href
      end
    end
  end
end
