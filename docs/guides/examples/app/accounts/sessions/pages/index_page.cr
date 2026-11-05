module Accounts::Sessions
  struct ListView
    include Punch::Component

    def initialize(@list : List, @actor : Examples::Actor, @addresses : Array(Punch::Auth::EmailIdentity), @recent : Bool)
    end

    def view(v : Punch::View) : Nil
      t = v.t.accounts.sessions
      v.render Examples::Layout.new(t.title, @actor) do
        v.h1 t.heading
        v.table(class: "sessions") do
          v.thead { v.tr { [t.browser, t.address, t.signed_in, t.last_seen, ""].each { |label| v.th label, scope: "col" } } }
          v.tbody do
            @list.sessions.each do |session|
              v.tr do
                v.td do
                  v.text session.user_agent || t.unknown
                  v.strong " #{t.this_browser}" if session.current?
                end
                v.td session.ip || "–"
                v.td v.locale.time(session.created_at, :short)
                v.td v.locale.time(session.last_seen_at, :short)
                v.td do
                  v.form(Destroy.action(session_id: session.id)) do |form|
                    form.submit session.current? ? t.sign_out : t.end_session
                  end
                end
              end
            end
          end
        end
        reauthenticate(v)
        addresses(v)
        password(v)
        language(v)
      end
    end

    # Changing addresses and the second factor needs a recent
    # authentication; without one their forms are left out (their
    # policies), and the page says how to get one.
    private def reauthenticate(v : Punch::View) : Nil
      return if @recent

      t = v.t.accounts.sessions.reauthenticate
      v.p do
        v.text "#{t.needed} "
        v.a t.title, href: ReauthenticatePage.href
      end
    end

    # The user's email addresses.
    private def addresses(v : Punch::View) : Nil
      t = v.t.accounts.emails
      v.h2 t.heading
      v.ul(class: "addresses") do
        @addresses.each do |address|
          v.li do
            v.text address.email.value
            v.text " "
            v.small address.verified? ? t.verified : t.unverified
            v.form(Emails::Destroy.action(email_id: address.id)) { |form| form.submit t.remove }
          end
        end
      end
      v.form(Emails::Create.action) do |form|
        form.field :email, label: t.new_address
        form.submit t.add
      end
    end

    private def password(v : Punch::View) : Nil
      t = v.t.accounts.passwords
      v.h2 t.change_title
      v.form(Passwords::Change.action) do |form|
        form.field :current_password, label: t.current_password
        form.field :password, label: t.new_password, hint: v.t.accounts.sign_up.password_hint(min: Punch::Auth::NewPassword::MIN)
        form.submit t.change
      end
    end

    # The interface's language: one of the app's locales, each named in
    # its own language, or none to follow the browser.
    private def language(v : Punch::View) : Nil
      t = v.t.accounts.language
      options = Examples::Languages.options
      v.h2 t.heading
      v.form(Accounts::Language::Update.action, values: {locale: @actor.user.locale}) do |form|
        form.field :locale, as: :select, options: options, hint: t.hint
        form.submit t.submit
      end
    end
  end

  # `GET /accounts/sessions`, the account page: the user's sessions, each
  # with a button to end it, their email addresses, the password,
  # and the interface's language. The sign-out button in the layout belongs
  # here too.
  @[Punch::Authorize(Punch::SignedIn)]
  @[Punch::Forms(Destroy, SignOut, Accounts::Language::Update, Accounts::Emails::Create, Accounts::Emails::Destroy, Accounts::Passwords::Change)]
  struct IndexPage < Punch::Page
    alias Input = Index::Input

    alias Output = ListView

    def call(input : Input, db : Punch::Reader, actor : Examples::Actor) : Output
      user_id = actor.user.id
      ListView.new(Index.new.call(input, db, actor), actor, Punch::Auth::EmailIdentities.list(db, user_id),
        Punch::Policy::RecentAuthentication.recent?(db, actor.principal))
    end

    def self.redirect(result : Emails::Added | Passwords::Changed) : Punch::Href
      IndexPage.href
    end

    def self.redirect(result : Nil) : Punch::Href
      IndexPage.href
    end

    def self.redirect(result : SignedOut) : Punch::Href
      CreatePage.href
    end
  end
end
