module Accounts::Tokens
  # An API token as its owner sees it: never the token itself, which is
  # shown once, when it is created.
  struct Entry
    include JSON::Serializable

    getter id : Int64
    getter name : String
    getter created_at : Time
    getter expires_at : Time
    getter last_used_at : Time?
    # Whether the request that asked came with this token.
    getter? current : Bool

    def initialize(token : Punch::Auth::APIToken, @current = false)
      @id = token.id
      @name = token.name
      @created_at = token.created_at
      @expires_at = token.expires_at
      @last_used_at = token.last_used_at
    end
  end

  record List,
    tokens : Array(Entry) do
    include JSON::Serializable
  end
end
