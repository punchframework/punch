module Accounts
  # A mail with a one-time link: to verify an address, to reset the
  # password, or to sign in.
  struct LinkMail
    include Punch::Mail

    enum Kind
      Verify
      Reset
      MagicLink
    end

    def initialize(@kind : Kind, @name : String, @email : Punch::Email, @link : Punch::Href)
    end

    def to : Punch::Mail::Address
      Punch::Mail::Address.new(@email, @name)
    end

    def subject(locale : Punch::Locale) : String
      t = locale.t.accounts.mail

      case @kind
      in .verify?     then t.verify.subject
      in .reset?      then t.reset.subject
      in .magic_link? then t.magic_link.subject
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
      in .magic_link?
        v.p t.magic_link.intro
        v.p { v.a t.magic_link.action, href: @link }
        v.p t.magic_link.expiry
        v.p t.ignore
      end
    end
  end
end
