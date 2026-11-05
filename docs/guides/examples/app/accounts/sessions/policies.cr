module Accounts::Sessions
  # A user sees and ends only their own sessions; another user's session
  # is not found, so session IDs reveal nothing (lib/punch/docs/authorization.md).
  struct Own
    include Punch::Policy

    def self.check(actor : Examples::Actor, db : Punch::Reader | Punch::Writer, *, session_id : Int64) : Punch::Policy::Decision
      Punch::Auth::Sessions.list(db, actor.user.id.value).any?(&.id.== session_id) ? allow : not_found
    end
  end
end
