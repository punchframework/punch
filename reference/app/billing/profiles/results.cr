module Billing::Profiles
  # An organization's billing profile as the API shows it.
  @[Punch::Status(200)]
  struct Profile
    include JSON::Serializable

    getter address : Billing::Address
    getter updated_at : Time

    def initialize(record : Record)
      @address = record.address
      @updated_at = record.updated_at
    end
  end

  # The organization has no billing profile yet.
  @[Punch::Status(404)]
  struct NoProfile
    include Punch::Problem
  end
end
