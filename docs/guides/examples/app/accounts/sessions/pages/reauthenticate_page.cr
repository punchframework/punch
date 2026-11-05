module Accounts::Sessions
  struct ReauthenticateView
    include Punch::Component

    def initialize(@actor : Examples::Actor)
    end

    def view(v : Punch::View) : Nil
      t = v.t.accounts.sessions.reauthenticate
      v.render Examples::Layout.new(t.title, @actor) do
        v.h1 t.title
        v.p t.with_password
        v.form(Reauthenticate.action) do |form|
          form.field :current_password, label: v.t.accounts.passwords.current_password
          form.submit t.submit
        end
      end
    end
  end

  # `GET /accounts/sessions/reauthenticate`: proving again who you are before a
  # change that needs a recent authentication, with the password.
  @[Punch::Authorize(Punch::SignedIn)]
  @[Punch::Forms(Reauthenticate)]
  struct ReauthenticatePage < Punch::Page
    struct Input
      include Punch::Input
    end

    alias Output = ReauthenticateView

    def call(input : Input, db : Punch::Reader, actor : Examples::Actor) : Output
      ReauthenticateView.new(actor)
    end

    def self.redirect(result : Reauthenticated) : Punch::Href
      Sessions::IndexPage.href
    end
  end
end
