module Accounts::Organizations::Members
  # A member of an organization and the role they hold there.
  @[Punch::Status(200)]
  struct Membership
    include JSON::Serializable

    getter organization_id : ID
    getter user_id : Users::ID
    getter name : Punch::NonEmptyString
    getter role : Roles::Name
    # When the role ends; never when absent.
    getter expires_at : Time?

    def initialize(@organization_id : ID, user : Users::Record, @role : Roles::Name, @expires_at : Time?)
      @user_id = user.id
      @name = user.name
    end
  end

  # A member was removed, or left.
  @[Punch::Status(200)]
  struct Removed
    include JSON::Serializable

    getter organization_id : ID
    getter user_id : Users::ID
    # Whether they removed themselves.
    getter? left : Bool

    def initialize(@organization_id : ID, @user_id : Users::ID, @left : Bool)
    end
  end

  # 422: the organization must keep an administrator, and this is its last.
  @[Punch::Status(422)]
  struct LastAdministrator
    include Punch::Problem
  end
end
