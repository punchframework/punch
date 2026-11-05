module Accounts::Emails
  # A user removes only their own addresses, and only after a recent
  # authentication (`Punch::Policy::RecentAuthentication`); another user's address
  # is not found.
  struct OwnRecent
    include Punch::Policy
    include Punch::Policy::RecentAuthentication

    def self.check(actor : Examples::Actor, db : Punch::Reader | Punch::Writer, *, email_id : Int64) : Punch::Policy::Decision
      return not_found unless Punch::Auth::EmailIdentities.list(db, actor.user.id).any?(&.id.==(email_id))

      recently_authenticated(db, actor.principal)
    end
  end
end
