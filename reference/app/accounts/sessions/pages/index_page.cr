module Accounts::Sessions
  struct ListView
    include Punch::Component

    def initialize(@list : List, @actor : Invoicing::Actor, @addresses : Array(Punch::Auth::EmailIdentity), @recent : Bool,
                   @second_factor : Punch::Auth::TOTPAuthenticator?, @new_codes : Array(String)?)
    end

    def view(v : Punch::View) : Nil
      t = v.t.accounts.sessions
      v.render Invoicing::Layout.new(t.title, @actor) do
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
        second_factor(v)
        tokens(v)
        language(v)
      end
    end

    # API tokens for agents live on their own page.
    private def tokens(v : Punch::View) : Nil
      t = v.t.accounts.tokens
      v.h2 t.title
      v.p { v.a t.link, href: Tokens::IndexPage.href }
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
        form.field :revoke_tokens, label: t.revoke_tokens
        form.submit t.change
      end
    end

    # The authenticator app: a button to set one up, or how many recovery
    # codes are left, new ones once until saved, and buttons to replace them
    # or remove the app.
    private def second_factor(v : Punch::View) : Nil
      t = v.t.accounts.second_factor
      v.h2 t.heading
      factor = @second_factor
      unless factor && factor.confirmed?
        v.p t.off
        v.form(SecondFactor::Create.action) { |form| form.submit t.set_up }
        return
      end
      v.p t.enabled(count: factor.recovery_codes)
      if codes = @new_codes
        v.p t.new_codes
        v.ul(class: "recovery-codes") { codes.each { |code| v.li { v.code Punch::Auth::SecondFactors.format(code) } } }
        v.form(SecondFactor::Seen.action, &.submit(t.saved))
      end
      v.form(SecondFactor::Regenerate.action) { |form| form.submit t.regenerate }
      v.form(SecondFactor::Destroy.action) { |form| form.submit t.remove }
    end

    # The interface's language: one of the app's locales, each named in
    # its own language, or none to follow the browser.
    private def language(v : Punch::View) : Nil
      t = v.t.accounts.language
      options = Invoicing::Languages.options
      v.h2 t.heading
      v.form(Accounts::Language::Update.action, values: {locale: @actor.user.locale}) do |form|
        form.field :locale, as: :select, options: options, hint: t.hint
        form.submit t.submit
      end
    end
  end

  # `GET /accounts/sessions`, the account page: the user's sessions, each
  # with a button to end it, their email addresses, the password,
  # the authenticator app, and the interface's language. The sign-out
  # button in the layout belongs here too.
  @[Punch::Authorize(Punch::SignedIn)]
  @[Punch::Forms(Destroy, SignOut, Accounts::Language::Update, Accounts::Emails::Create, Accounts::Emails::Destroy, Accounts::Passwords::Change,
    Accounts::SecondFactor::Create, Accounts::SecondFactor::Regenerate, Accounts::SecondFactor::Seen, Accounts::SecondFactor::Destroy)]
  struct IndexPage < Punch::Page
    alias Input = Index::Input

    alias Output = ListView

    def call(input : Input, db : Punch::Reader, actor : Invoicing::Actor) : Output
      user_id = actor.user.id
      recent = Punch::Policy::RecentAuthentication.recent?(db, actor.principal)
      # New recovery codes sign in: only a recent session sees them.
      codes = Punch::Auth::SecondFactors.new_recovery_codes(db, user_id).try(&.unwrap) if recent
      ListView.new(Index.new.call(input, db, actor), actor, Punch::Auth::EmailIdentities.list(db, user_id),
        recent, Punch::Auth::SecondFactors.find(db, user_id), codes)
    end

    def self.redirect(result : Emails::Added | Passwords::Changed | SecondFactor::Changed | SecondFactor::CodesReplaced) : Punch::Href
      IndexPage.href
    end

    def self.redirect(result : SecondFactor::Started) : Punch::Href
      SecondFactor::SetupPage.href
    end

    def self.redirect(result : Nil) : Punch::Href
      IndexPage.href
    end

    def self.redirect(result : SignedOut) : Punch::Href
      CreatePage.href
    end
  end
end
