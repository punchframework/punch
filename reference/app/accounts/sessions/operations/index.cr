module Accounts::Sessions
  # A session as its owner sees it in the list.
  struct Entry
    include JSON::Serializable

    getter id : Int64
    getter method : String
    getter created_at : Time
    getter last_seen_at : Time
    getter ip : String?
    getter user_agent : String?
    # Whether this is the session of the request that asked.
    getter? current : Bool

    def initialize(session : Punch::Auth::Session, @current)
      @id = session.id
      @method = session.method
      @created_at = session.created_at
      @last_seen_at = session.last_seen_at
      @ip = session.ip
      @user_agent = session.user_agent
    end
  end

  record List,
    sessions : Array(Entry) do
    include JSON::Serializable
  end

  # The signed-in user's live sessions, most recently used first.
  @[Punch::Authorize(Punch::SignedIn)]
  struct Index < Punch::Query
    struct Input
      include Punch::Input
    end

    alias Output = List

    def call(input : Input, db : Punch::Reader, actor : Invoicing::Actor) : Output
      current = actor.principal.session.try(&.id)
      List.new(Punch::Auth::Sessions.list(db, actor.user.id.value).map { |session| Entry.new(session, session.id == current) })
    end
  end
end
