module BillingSpec
  # The payment provider's signing secret in specs.
  WEBHOOK_SECRET = "whsec_#{Base64.strict_encode("payments-spec-secret-0123456789")}"

  def self.line(description = "Consulting", quantity = 3, unit_price = 12_500) : Billing::Invoices::Invoice::Line
    Billing::Invoices::Invoice::Line.new(InvoicingSpec.parse(Punch::NonEmptyString, description), InvoicingSpec.parse(Billing::Invoices::Quantity, quantity), InvoicingSpec.parse(Punch::Money, unit_price))
  end

  # A customer of *organization*, by default of a new user's.
  # Who an invoice sent to customer *id* bills.
  def self.billed_to(id : Billing::Customers::ID, name = "Ada") : Billing::Invoices::BilledTo
    Billing::Invoices::BilledTo.build(customer_id: id, name: InvoicingSpec.parse(Punch::NonEmptyString, name)).as(Billing::Invoices::BilledTo)
  end

  def self.customer(db : Punch::Writer, email = "ada@example.org", organization : Accounts::Organizations::ID? = nil) : Billing::Customers::Record
    organization ||= AccountsSpec.organization(db, AccountsSpec.user(db).id)
    Punch.cannot_violate(Billing::Customers::Table.insert(db, organization_id: organization, name: InvoicingSpec.parse(Punch::NonEmptyString, "Ada Lovelace"), email_encrypted: Punch::Secret.new(InvoicingSpec.parse(Punch::Email, email)), created_at: Time.utc))
  end
end
