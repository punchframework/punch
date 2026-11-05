module Accounts::Sessions
  struct SignInView
    include Punch::Component

    def view(v : Punch::View) : Nil
      t = v.t.accounts.sessions.create
      v.render Examples::Layout.new(t.title) do
        v.h1 t.title
        v.form(Create.action) do |form|
          form.field :email
          form.field :password
          form.submit t.submit
        end
        v.p do
          v.a t.forgot_password, href: PasswordResets::CreatePage.href
        end
        v.p do
          v.text "#{t.new_here} "
          v.a t.create_account, href: SignUp::CreatePage.href
        end
      end
    end
  end

  # `GET /accounts/sessions/new`, where a browser goes when a page needs a
  # signed-in user (`Punch::Pages.sign_in`, in `app/setup.cr`).
  @[Punch::Public]
  struct CreatePage < Punch::Page
    struct Input
      include Punch::Input
    end

    alias Output = SignInView

    def call(input : Input, db : Punch::Reader) : Output
      SignInView.new
    end

    def self.redirect(result : SignedIn) : Punch::Href
      Home::IndexPage.href
    end
  end
end

# A browser without a session that asks for a page needing one comes here
# (lib/punch/docs/auth.md).
