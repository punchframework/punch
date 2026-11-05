module Accounts
  # A mail with a one-time link: to verify an address or to reset the
  # password.
  struct LinkMail
    include Punch::Mail

    enum Kind
      Verify
      Reset
    end

    def initialize(@kind : Kind, @name : String, @email : Punch::Email, @link : Punch::Href)
    end

    def to : Punch::Mail::Address
      Punch::Mail::Address.new(@email, @name)
    end

    def subject(locale : Punch::Locale) : String
      t = locale.t.accounts.mail

      case @kind
      in .verify? then t.verify.subject
      in .reset?  then t.reset.subject
      end
    end

    def view(v : Punch::View) : Nil
      t = v.t.accounts.mail
      v.p t.greeting(name: @name)

      case @kind
      in .verify?
        v.p t.verify.intro(email: @email.value)
        v.p { v.a t.verify.action, href: @link }
        v.p t.verify.expiry
      in .reset?
        v.p t.reset.intro
        v.p { v.a t.reset.action, href: @link }
        v.p t.reset.expiry
        v.p t.ignore
      end
    end
  end
end
