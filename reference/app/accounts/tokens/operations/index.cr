module Accounts::Tokens
  # The signed-in user's live API tokens, newest first.
  @[Punch::Authorize(Punch::SignedIn)]
  struct Index < Punch::Query
    struct Input
      include Punch::Input
    end

    alias Output = List

    def call(input : Input, db : Punch::Reader, actor : Invoicing::Actor) : Output
      current = actor.principal.api_token.try(&.id)
      List.new(Punch::Auth::APITokens.list(db, actor.user.id.value).map { |token| Entry.new(token, token.id == current) })
    end
  end
end
