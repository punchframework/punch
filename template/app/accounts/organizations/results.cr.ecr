module Accounts::Organizations
  # An organization as its members see it.
  @[Punch::Status(200)]
  struct Organization
    include JSON::Serializable

    getter id : ID
    getter name : Punch::NonEmptyString
    # Whether the session or token works in it now.
    getter? current : Bool

    def initialize(record : Record, @current : Bool)
      @id = record.id
      @name = record.name
    end
  end

  # The organization in the path does not exist.
  @[Punch::Status(404)]
  struct NotFound
    include Punch::Problem
  end
end
