module Billing::Customers
  @[Punch::Status(201)]
  record Created,
    customer : Customer do
    include JSON::Serializable
  end

  # Adds a customer to the organization the actor works in. Each
  # organization's customers have unique email addresses and tax numbers.
  @[Punch::Authorize(Accounts::Organizations::Current)]
  struct Create < Punch::Command
    struct Input
      include Punch::Input

      getter name : Punch::NonEmptyString
      getter company_name : Punch::NonEmptyString?
      getter email : Punch::Email
      # The postal address invoices go to; stored encrypted.
      getter address : Punch::NonEmptyString?
      # The VAT or tax number; stored encrypted.
      getter tax_id : TaxID?
      # The language of the customer's mail; without one, the user's.
      getter locale : Punch::LocaleTag?
    end

    alias Output = Created | TaxIdTaken | Punch::Rejection

    def call(input : Input, db : Punch::Writer, actor : Invoicing::Actor, _grant : Punch::Grant(Create)) : Output
      if rejection = Invoicing::Languages.check(input.locale)
        return rejection
      end

      case created = Table.insert(db, organization_id: actor.organization_id, name: input.name, company_name: input.company_name, email_encrypted: Punch::Secret.new(input.email),
        address: input.address.try { |address| Punch::Secret.new(address) }, tax_id: input.tax_id.try { |tax_id| Punch::Secret.new(tax_id) },
        created_at: Time.utc, locale: input.locale)
      in Record              then Created.new(Customer.new(created))
      in EmailEncryptedTaken then created.rejection("email") # named after the encrypted column; 422 at `email`
      in TaxIdTaken          then created                    # 422 at `tax_id`
      end
    end
  end
end
