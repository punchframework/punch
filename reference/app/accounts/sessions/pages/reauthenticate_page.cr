module Accounts::Sessions
  struct ReauthenticateView
    include Punch::Component

    def initialize(@actor : Invoicing::Actor, @second_factor : Bool)
    end

    def view(v : Punch::View) : Nil
      t = v.t.accounts.sessions.reauthenticate
      v.render Invoicing::Layout.new(t.title, @actor) do
        v.h1 t.title
        if @second_factor
          v.p t.with_code
          v.form(SecondFactor::Reauthenticate.action) do |form|
            form.field :code, label: v.t.accounts.second_factor.code, hint: v.t.accounts.second_factor.code_hint
            form.submit t.submit
          end
        else
          v.p t.with_password
          v.form(Reauthenticate.action) do |form|
            form.field :current_password, label: v.t.accounts.passwords.current_password
            form.submit t.submit
          end
        end
      end
    end
  end

  # `GET /accounts/sessions/reauthenticate`: proving again who you are before a
  # change that needs a recent authentication, with the authenticator app
  # when the user has one, else with the password.
  @[Punch::Authorize(Punch::SignedIn)]
  @[Punch::Forms(Reauthenticate, SecondFactor::Reauthenticate)]
  struct ReauthenticatePage < Punch::Page
    struct Input
      include Punch::Input
    end

    alias Output = ReauthenticateView

    def call(input : Input, db : Punch::Reader, actor : Invoicing::Actor) : Output
      ReauthenticateView.new(actor, Punch::Auth::SecondFactors.enabled?(db, actor.user.id))
    end

    def self.redirect(result : Reauthenticated) : Punch::Href
      Sessions::IndexPage.href
    end
  end
end
