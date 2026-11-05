module Billing::Customers
  # Changes the fields given; absent fields keep their value.
  @[Punch::Authorize(ByRole)]
  struct Update < Punch::Command
    struct Input
      include Punch::Input

      @[Punch::PathParam]
      getter customer_id : ID

      getter name : Punch::NonEmptyString?
      getter company_name : Punch::NonEmptyString?
      getter email : Punch::Email?
      getter address : Punch::NonEmptyString?
      getter tax_id : TaxID?
      getter locale : Punch::LocaleTag?
    end

    alias Output = Customer | NotFound | TaxIdTaken | Punch::Rejection

    def call(input : Input, db : Punch::Writer, _actor : Invoicing::Actor, _grant : Punch::Grant(Update)) : Output
      if rejection = Invoicing::Languages.check(input.locale)
        return rejection
      end

      record = Table.find(db, input.customer_id) || return NotFound.new
      changed = record.copy_with(
        name: input.name || record.name,
        company_name: input.company_name || record.company_name,
        email_encrypted: input.email.try { |email| Punch::Secret.new(email) } || record.email_encrypted,
        address: input.address.try { |address| Punch::Secret.new(address) } || record.address,
        tax_id: input.tax_id.try { |tax_id| Punch::Secret.new(tax_id) } || record.tax_id,
        locale: input.locale || record.locale,
      )

      case updated = Table.update(db, changed)
      in Record              then Customer.new(updated)
      in EmailEncryptedTaken then updated.rejection("email")
      in TaxIdTaken          then updated
      in Nil                 then NotFound.new
      end
    end
  end
end
