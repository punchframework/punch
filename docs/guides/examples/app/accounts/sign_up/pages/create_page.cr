module Accounts::SignUp
  struct SignUpView
    include Punch::Component

    def initialize(@sent : Bool)
    end

    def view(v : Punch::View) : Nil
      t = v.t.accounts.sign_up
      v.render Examples::Layout.new(t.title) do
        v.h1 t.title
        if @sent
          v.p t.sent
        else
          v.form(Create.action) do |form|
            form.field :name, label: t.name
            form.field :email
            form.field :password, hint: t.password_hint(min: Punch::Auth::NewPassword::MIN)
            form.submit t.submit
          end
        end
        v.p do
          v.text "#{t.have_account} "
          v.a t.sign_in, href: Sessions::CreatePage.href
        end
      end
    end
  end

  # `GET /accounts/sign_up/new`; with `sent`, says to follow the link
  # mailed to the address.
  @[Punch::Public]
  struct CreatePage < Punch::Page
    struct Input
      include Punch::Input

      getter? sent : Bool = false
    end

    alias Output = SignUpView

    def call(input : Input, db : Punch::Reader) : Output
      SignUpView.new(input.sent?)
    end

    def self.redirect(result : SignedUp) : Punch::Href
      CreatePage.href(sent: true)
    end
  end
end
