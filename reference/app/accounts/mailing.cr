module Accounts
  # The mail of the auth slice (lib/punch/docs/auth.md): one-time links, and notices of
  # changes to how a user signs in. Always in the user's language.
  module Mailing
    def self.locale(user : Users::Record) : Punch::Locale
      Punch::I18n.locale(user.locale.try(&.to_s))
    end

    # The language an organization chose, for mail other slices send on
    # its behalf; `nil` for an organization that is gone. Other slices ask
    # here instead of reading accounts' tables.
    def self.organization_locale(job : Punch::Job::Context, organization_id : Organizations::ID) : Punch::LocaleTag?
      job.read { |db| Organizations::Table.find(db, organization_id).try(&.locale) }
    end

    # The addresses a notice goes to: the verified ones, or all of them
    # while none is verified.
    def self.notified(identities : Array(Punch::Auth::EmailIdentity)) : Array(Punch::Email)
      verified = identities.select(&.verified?)
      (verified.empty? ? identities : verified).map(&.email)
    end

    # The user and their identities, in one read.
    def self.load(job : Punch::Job::Context, user_id : Int64) : {Users::Record, Array(Punch::Auth::EmailIdentity)}?
      job.read do |db|
        user = Users::Table.find(db, Users::ID.parse(user_id).as(Users::ID)) || next
        {user, Punch::Auth::EmailIdentities.list(db, user_id)}
      end
    end
  end
end
