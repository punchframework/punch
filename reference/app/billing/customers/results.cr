module Billing::Customers
  # A customer as the API shows it.
  @[Punch::Status(200)]
  struct Customer
    include JSON::Serializable

    getter id : ID
    getter organization_id : Accounts::Organizations::ID
    # The contact person.
    getter name : Punch::NonEmptyString
    getter company_name : Punch::NonEmptyString?
    getter email : Punch::Email
    # The postal address invoices go to.
    getter address : Punch::NonEmptyString?
    # The VAT or tax number, without spaces.
    getter tax_id : TaxID?
    # The language of the customer's mail, if one was chosen.
    getter locale : Punch::LocaleTag?
    # The company name if there is one, else the contact's name.
    getter display_name : String
    getter created_at : Time

    def initialize(record : Record)
      @id = record.id
      @organization_id = record.organization_id
      @name = record.name
      @company_name = record.company_name
      @email = record.email_encrypted.unwrap
      @address = record.address.try(&.unwrap) # decrypted for the response
      @tax_id = record.tax_id.try(&.unwrap)
      @locale = record.locale
      @display_name = record.display_name
      @created_at = record.created_at
    end
  end

  @[Punch::Status(404)]
  struct NotFound
    include Punch::Problem
  end
end
