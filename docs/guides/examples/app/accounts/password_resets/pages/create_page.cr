module Accounts::PasswordResets
  struct CreateView
    include Punch::Component

    def initialize(@sent : Bool)
    end

    def view(v : Punch::View) : Nil
      t = v.t.accounts.password_resets.create
      v.render Examples::Layout.new(t.title) do
        v.h1 t.title
        if @sent
          v.p t.sent
        else
          v.p t.intro
          v.form(Create.action) do |form|
            form.field :email
            form.submit t.send_link
          end
        end
        v.p { v.a v.t.accounts.sessions.create.title, href: Sessions::CreatePage.href }
      end
    end
  end

  # `GET /accounts/password_resets/new`: asks for the address to mail
  # a reset link to; with `sent`, says to check the inbox.
  @[Punch::Public]
  struct CreatePage < Punch::Page
    struct Input
      include Punch::Input

      getter? sent : Bool = false
    end

    alias Output = CreateView

    def call(input : Input, db : Punch::Reader) : Output
      CreateView.new(input.sent?)
    end

    def self.redirect(result : Requested) : Punch::Href
      CreatePage.href(sent: true)
    end
  end
end
