module Accounts::Emails
  struct VerifyView
    include Punch::Component

    def initialize(@token : String, @email : Punch::Email?)
    end

    def view(v : Punch::View) : Nil
      t = v.t.accounts.emails
      v.render Invoicing::Layout.new(t.verify_title) do
        v.h1 t.verify_title
        if email = @email
          v.p t.verify_intro(email: email.value)
          v.form(Verify.action, values: {token: @token}) do |form|
            form.field :token, as: :hidden
            form.submit t.verify
          end
        else
          v.p v.t.accounts.link_expired
        end
      end
    end
  end

  # `GET /accounts/emails/verify?token=…`, the link in a verification
  # mail. It only looks the token up: mail scanners fetch links, so the
  # button (`Verify`) uses it.
  @[Punch::Public]
  struct VerifyPage < Punch::Page
    struct Input
      include Punch::Input

      # Optional, so a refused button can show this page again.
      getter token : String?
    end

    alias Output = VerifyView

    def call(input : Input, db : Punch::Reader) : Output
      token = input.token || ""
      holder = LinkStore.holder(Punch::Auth::OneTimeTokens.find(db, Links::VERIFY_EMAIL, token), db)
      VerifyView.new(token, holder.try(&.[1]))
    end

    def self.redirect(result : Verified) : Punch::Href
      Sessions::CreatePage.href
    end
  end
end
