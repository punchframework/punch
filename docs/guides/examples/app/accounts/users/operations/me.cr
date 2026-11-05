module Accounts::Users
  # The signed-in user, as the API shows them.
  struct Account
    include JSON::Serializable

    getter id : Users::ID
    getter name : Punch::NonEmptyString
    # How this request was authenticated: `session` or `token`.
    getter via : String

    def initialize(actor : Examples::Actor)
      @id = actor.user.id
      @name = actor.user.name
      @via = actor.principal.session ? "session" : "token"
    end
  end

  # Who am I? Answers 401 without a session or API token.
  @[Punch::Authorize(Punch::SignedIn)]
  struct Me < Punch::Query
    struct Input
      include Punch::Input
    end

    alias Output = Account

    def call(input : Input, db : Punch::Reader, actor : Examples::Actor) : Output
      Account.new(actor)
    end
  end
end
