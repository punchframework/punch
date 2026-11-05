module Billing::Profiles
  # Sets the billing profile of the organization the actor works in,
  # making it the first time.
  @[Punch::Authorize(Accounts::Organizations::Current)]
  struct Update < Punch::Command
    struct Input
      include Punch::Input

      getter street : Punch::NonEmptyString
      getter postal_code : Punch::NonEmptyString
      getter city : Punch::NonEmptyString
      getter country : Punch::NonEmptyString
    end

    alias Output = Profile | NoProfile | Punch::Rejection

    def call(input : Input, db : Punch::Writer, actor : Invoicing::Actor, _grant : Punch::Grant(Update)) : Output
      organization = actor.organization || return NoProfile.new
      address = Billing::Address.build(street: input.street, postal_code: input.postal_code, city: input.city, country: input.country)
      # Four fields and no rule of its own: only too long a whole refuses it.
      return Punch::Rejection.new(Punch::Rejection::Path.new, address) if address.is_a?(Punch::Invalid)

      now = Time.utc
      record = if existing = Table.find(db, organization.id)
                 Table.update(db, existing.copy_with(address: address, updated_at: now))
               else
                 # None in this transaction, so the key is free.
                 Punch.cannot_violate(Table.insert(db, organization_id: organization.id, address: address, updated_at: now))
               end
      record ? Profile.new(record) : NoProfile.new
    end
  end
end
