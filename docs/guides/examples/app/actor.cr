module Examples
  # Who a request acts for: a signed-in user, by session or API token
  # (lib/punch/docs/auth.md). Operations that need one take it in `call`; Punch
  # answers 401 when there is none.
  struct Actor
    include Punch::Auth::Actor

    getter user : Accounts::Users::Record
    getter principal : Punch::Auth::Principal

    def initialize(@user, @principal)
    end

    # The language the user chose, which wins over Accept-Language.
    def locale : Punch::LocaleTag?
      user.locale
    end

    # `nil` when the user no longer exists.
    def self.load(principal : Punch::Auth::Principal, db : Punch::Reader | Punch::Writer) : self?
      user = Accounts::Users::Table.find(db, principal.user_id(Accounts::Users::ID)) || return
      new(user, principal)
    end
  end
end
